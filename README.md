# venera_local_llm

Venera's small, owned FFI package for running GGUF translation models on
Android, iOS and Windows. It uses Dart Native Assets hooks as the package
integration boundary. Windows delegates the large fixed source set to Visual
Studio CMake; mobile targets use the configured Flutter toolchain.

The package does not download models, native libraries, or source code. The
caller supplies a verified GGUF path. Native code is built from a pinned
`llama.cpp` source checkout; a missing or unverified checkout is a build error.

## Security boundary

- No Dart wrapper package for llama.cpp is used.
- No precompiled upstream native archive is used.
- `third_party/llama.cpp.source.json` pins the repository and immutable commit.
- The bootstrap and verification tools fail closed on a dirty or unexpected
  source checkout.
- The build forces CPU-only options and disables KleidiAI FetchContent,
  ccache, GPU backends, examples, tools, servers and optional components.
- Windows builds clear inherited `CMAKE_*` variables before invoking the
  absolute Visual Studio CMake path.
- The app must verify the GGUF SHA-256 before calling `load`.

This package currently builds the CPU backend only. GPU backends can be added
after their toolchains and artifacts have an independent review.

## Native source

Run `tool/bootstrap_llama_cpp.ps1`, or place the same verified checkout at
`third_party/llama.cpp`. The build hook verifies the immutable commit and dirty
state before building. The source directory is never resolved from a floating
branch or downloaded by the hook or by CMake.

## Current verified artifact

On Windows x64, the release Native Assets build produces one self-contained
`venera_local_llm.dll` of about 3.35 MiB. The GGUF model is not bundled and is
downloaded separately by the application.
