#pragma once

#include <stdint.h>

#if defined(_WIN32)
#  if defined(VENERA_LOCAL_LLM_BUILD)
#    define VENERA_LOCAL_LLM_API __declspec(dllexport)
#  else
#    define VENERA_LOCAL_LLM_API __declspec(dllimport)
#  endif
#else
#  define VENERA_LOCAL_LLM_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct venera_llm_engine venera_llm_engine;
typedef void (*venera_llm_complete_callback)(
    void * user_data,
    const char * result,
    int32_t error_code);

VENERA_LOCAL_LLM_API venera_llm_engine * venera_llm_create(
    const char * model_path,
    int32_t context_size,
    int32_t threads,
    char ** error_out);

VENERA_LOCAL_LLM_API int32_t venera_llm_complete_async(
    venera_llm_engine * engine,
    const char * system_prompt,
    const char * user_prompt,
    int32_t max_tokens,
    float temperature,
    uint32_t seed,
    venera_llm_complete_callback callback,
    void * user_data);

VENERA_LOCAL_LLM_API void venera_llm_cancel(venera_llm_engine * engine);
VENERA_LOCAL_LLM_API void venera_llm_destroy(venera_llm_engine * engine);
VENERA_LOCAL_LLM_API void venera_llm_free_string(char * value);
VENERA_LOCAL_LLM_API const char * venera_llm_version(void);

#ifdef __cplusplus
}
#endif
