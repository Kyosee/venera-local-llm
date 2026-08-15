# venera_local_llm

Venera's small, owned FFI package for running GGUF translation models on
Android, iOS and Windows. It uses Dart Native Assets hooks as the package
integration boundary. Windows delegates the large fixed source set to Visual
Studio CMake; mobile targets use the configured Flutter toolchain.

The package does not download models, native libraries, or source code. The
caller supplies a verified GGUF path. Native code is built from the pinned
`llama.cpp` source snapshot vendored in this repository; a missing or
unexpected snapshot is a build error.

## Security boundary

- No Dart wrapper package for llama.cpp is used.
- No precompiled upstream native archive is used.
- `third_party/llama.cpp.source.json` pins the repository and immutable commit.
- The build recomputes a path-sensitive SHA-256 snapshot and rejects changed,
  missing, extra, linked, or nested-repository source entries.
- The source snapshot is part of the package commit that Venera pins exactly;
  build hooks neither clone nor initialize nested repositories.
- CMake is forced into fully disconnected mode and cannot use Git discovery.
- Dynamic ggml backend loading is replaced with a fail-closed local shim.
- The build forces CPU-only options and disables KleidiAI FetchContent,
  ccache, GPU backends, examples, tools, servers and optional components.
- Windows builds clear inherited `CMAKE_*` variables before invoking the
  absolute Visual Studio CMake path.
- The app must verify the GGUF SHA-256 before calling `load`.

This package currently builds the CPU backend only. GPU backends can be added
after their toolchains and artifacts have an independent review.

## Native source

`third_party/llama.cpp` is a source snapshot of the exact commit recorded in
`third_party/llama.cpp.source.json`. Updates are reviewed and committed as
ordinary package files. The source directory is never resolved from a floating
branch or downloaded by Dart Pub, the build hook, or CMake.

## Current verified artifact

On Windows x64, the release Native Assets build produces one self-contained
`venera_local_llm.dll` of about 3.35 MiB. The GGUF model is not bundled and is
downloaded separately by the application.
