#include "venera_local_llm.h"

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "llama.h"

struct venera_llm_engine {
    llama_model * model = nullptr;
    llama_context * context = nullptr;
    const llama_vocab * vocab = nullptr;
    std::mutex generation_mutex;
    std::mutex active_mutex;
    std::condition_variable active_cv;
    // Cancellation is generation-based rather than a shared boolean. Each
    // submitted request snapshots the current generation; cancel() advances it
    // so every already-submitted request observes cancellation, while a later
    // request can snapshot the new generation without reviving older work.
    std::atomic<uint64_t> cancel_generation = 0;
    int32_t context_size = 0;
    int active_jobs = 0;
};

namespace {

char * copy_error(const std::string & message) {
    auto * result = new char[message.size() + 1];
    std::memcpy(result, message.c_str(), message.size() + 1);
    return result;
}

std::string apply_chat_template(
    const llama_model * model,
    const char * system_prompt,
    const char * user_prompt) {
    llama_chat_message messages[2] = {
        {"system", system_prompt},
        {"user", user_prompt},
    };
    const char * tmpl = llama_model_chat_template(model, nullptr);
    if (tmpl == nullptr) {
        throw std::runtime_error("model does not provide a chat template");
    }
    int32_t size = llama_chat_apply_template(
        tmpl, messages, 2, true, nullptr, 0);
    if (size <= 0) {
        throw std::runtime_error("failed to apply model chat template");
    }
    std::string prompt(static_cast<size_t>(size), '\0');
    int32_t written = llama_chat_apply_template(
        tmpl, messages, 2, true, prompt.data(), size);
    if (written < 0 || written > size) {
        throw std::runtime_error("chat template output was invalid");
    }
    prompt.resize(static_cast<size_t>(written));
    return prompt;
}

std::vector<llama_token> tokenize(
    const llama_vocab * vocab,
    const std::string & prompt) {
    int32_t count = llama_tokenize(
        vocab, prompt.data(), static_cast<int32_t>(prompt.size()),
        nullptr, 0, true, false);
    if (count >= 0) {
        throw std::runtime_error("tokenizer did not report required size");
    }
    count = -count;
    std::vector<llama_token> tokens(static_cast<size_t>(count));
    int32_t written = llama_tokenize(
        vocab, prompt.data(), static_cast<int32_t>(prompt.size()),
        tokens.data(), count, true, false);
    if (written < 0) {
        throw std::runtime_error("failed to tokenize prompt");
    }
    tokens.resize(static_cast<size_t>(written));
    return tokens;
}

std::string generate(
    venera_llm_engine * engine,
    const char * system_prompt,
    const char * user_prompt,
    int32_t max_tokens,
    float temperature,
    uint32_t seed,
    uint64_t request_generation) {
    if (engine->cancel_generation.load() != request_generation) {
        throw std::runtime_error("cancelled");
    }
    llama_memory_clear(llama_get_memory(engine->context), true);
    auto prompt = apply_chat_template(engine->model, system_prompt, user_prompt);
    auto tokens = tokenize(engine->vocab, prompt);
    if (tokens.empty()) {
        throw std::runtime_error("prompt produced no tokens");
    }
    if (tokens.size() + static_cast<size_t>(max_tokens) >
        static_cast<size_t>(engine->context_size)) {
        throw std::runtime_error("prompt and output exceed the configured context");
    }
    for (size_t offset = 0; offset < tokens.size(); offset += 512) {
        if (engine->cancel_generation.load() != request_generation) {
            throw std::runtime_error("cancelled");
        }
        auto count = static_cast<int32_t>(
            std::min<size_t>(512, tokens.size() - offset));
        if (llama_decode(
                engine->context,
                llama_batch_get_one(tokens.data() + offset, count)) != 0) {
            throw std::runtime_error("llama.cpp rejected the prompt batch");
        }
    }

    auto sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (sampler == nullptr) {
        throw std::runtime_error("failed to create sampler");
    }
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(seed));

    std::string output;
    output.reserve(static_cast<size_t>(max_tokens) * 4);
    try {
        for (int32_t i = 0; i < max_tokens; i++) {
            if (engine->cancel_generation.load() != request_generation) {
                throw std::runtime_error("cancelled");
            }
            auto token = llama_sampler_sample(sampler, engine->context, -1);
            if (llama_vocab_is_eog(engine->vocab, token)) break;
            char piece[8192];
            int32_t size = llama_token_to_piece(
                engine->vocab, token, piece, sizeof(piece), 0, false);
            if (size < 0) {
                throw std::runtime_error("failed to decode token piece");
            }
            output.append(piece, static_cast<size_t>(size));
            llama_sampler_accept(sampler, token);
            auto next = llama_batch_get_one(&token, 1);
            if (llama_decode(engine->context, next) != 0) {
                throw std::runtime_error("llama.cpp rejected a generation step");
            }
        }
    } catch (...) {
        llama_sampler_free(sampler);
        throw;
    }
    llama_sampler_free(sampler);
    return output;
}

void job_done(venera_llm_engine * engine) {
    std::lock_guard lock(engine->active_mutex);
    engine->active_jobs--;
    engine->active_cv.notify_all();
}

} // namespace

extern "C" VENERA_LOCAL_LLM_API venera_llm_engine * venera_llm_create(
    const char * model_path,
    int32_t context_size,
    int32_t threads,
    char ** error_out) {
    if (error_out != nullptr) *error_out = nullptr;
    venera_llm_engine * engine = nullptr;
    try {
        static std::once_flag backend_once;
        std::call_once(backend_once, [] { llama_backend_init(); });
        engine = new venera_llm_engine();
        auto params = llama_model_default_params();
        params.n_gpu_layers = 0;
        engine->model = llama_model_load_from_file(model_path, params);
        if (engine->model == nullptr) throw std::runtime_error("failed to load GGUF model");
        auto context_params = llama_context_default_params();
        context_params.n_ctx = static_cast<uint32_t>(context_size);
        context_params.n_batch = 512;
        context_params.n_ubatch = 512;
        context_params.n_seq_max = 1;
        context_params.n_threads = threads;
        context_params.n_threads_batch = threads;
        engine->context = llama_init_from_model(engine->model, context_params);
        if (engine->context == nullptr) throw std::runtime_error("failed to create llama context");
        engine->vocab = llama_model_get_vocab(engine->model);
        engine->context_size = context_size;
        return engine;
    } catch (const std::exception & error) {
        if (engine != nullptr) {
            if (engine->context != nullptr) llama_free(engine->context);
            if (engine->model != nullptr) llama_model_free(engine->model);
            delete engine;
        }
        if (error_out != nullptr) *error_out = copy_error(error.what());
        return nullptr;
    }
}

extern "C" VENERA_LOCAL_LLM_API int32_t venera_llm_complete_async(
    venera_llm_engine * engine,
    const char * system_prompt,
    const char * user_prompt,
    int32_t max_tokens,
    float temperature,
    uint32_t seed,
    venera_llm_complete_callback callback,
    void * user_data) {
    if (engine == nullptr || callback == nullptr || system_prompt == nullptr ||
        user_prompt == nullptr || max_tokens <= 0) return 1;
    try {
        std::string system_copy(system_prompt);
        std::string user_copy(user_prompt);
        uint64_t request_generation;
        {
            std::lock_guard lock(engine->active_mutex);
            engine->active_jobs++;
            request_generation = engine->cancel_generation.load();
        }
        try {
            std::thread([
                engine,
                system = std::move(system_copy),
                user = std::move(user_copy),
                max_tokens,
                temperature,
                seed,
                request_generation,
                callback,
                user_data
            ] {
                std::string result;
                int32_t error_code = 0;
                try {
                    std::lock_guard lock(engine->generation_mutex);
                    result = generate(
                        engine,
                        system.c_str(),
                        user.c_str(),
                        max_tokens,
                        temperature,
                        seed,
                        request_generation);
                } catch (const std::exception & error) {
                    error_code =
                        engine->cancel_generation.load() != request_generation
                            ? 2
                            : 3;
                    result = error.what();
                } catch (...) {
                    error_code = 3;
                    result = "unknown native generation error";
                }
                try {
                    callback(user_data, copy_error(result), error_code);
                } catch (...) {
                    // C callbacks must never unwind through the worker thread.
                }
                job_done(engine);
            }).detach();
        } catch (...) {
            job_done(engine);
            throw;
        }
        return 0;
    } catch (...) {
        return 4;
    }
}

extern "C" VENERA_LOCAL_LLM_API void venera_llm_cancel(venera_llm_engine * engine) {
    if (engine != nullptr) engine->cancel_generation.fetch_add(1);
}

extern "C" VENERA_LOCAL_LLM_API void venera_llm_destroy(venera_llm_engine * engine) {
    if (engine == nullptr) return;
    {
        std::unique_lock lock(engine->active_mutex);
        engine->active_cv.wait(lock, [engine] { return engine->active_jobs == 0; });
    }
    if (engine->context != nullptr) llama_free(engine->context);
    if (engine->model != nullptr) llama_model_free(engine->model);
    delete engine;
}

extern "C" VENERA_LOCAL_LLM_API void venera_llm_free_string(char * value) {
    delete[] value;
}

extern "C" VENERA_LOCAL_LLM_API const char * venera_llm_version(void) {
    return "llama.cpp@08659901c43b51de735740f1cf61bb82fbe0c4e4";
}
