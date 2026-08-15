# Security policy

This package treats native code and build tooling as a supply-chain boundary.

## Accepted inputs

- `llama.cpp` must match the path-sensitive SHA-256 snapshot recorded in
  `third_party/llama.cpp.source.json`; additions, removals, changes and links
  fail the build.
- Venera pins the package repository to an immutable commit, so reviewed native
  source and build logic change together.
- GGUF files are caller-owned inputs and must pass SHA-256 verification before
  native loading.
- Pub dependencies use exact versions and the committed lockfile records their
  pub.dev content hashes.

## Build rules

- Build hooks never download source code, models or precompiled libraries.
- CMake runs with `FETCHCONTENT_FULLY_DISCONNECTED=ON` and Git package
  discovery disabled, so dormant upstream download branches fail closed.
- Vendored native source must not contain nested Git metadata.
- CPU-only builds disable GPU backends, remote backends, examples, tools,
  servers, ccache and KleidiAI FetchContent.
- Dynamic ggml backend loading always fails, so environment variables and
  executable/current-directory plugin discovery cannot load native code.
- Windows uses the compiler and absolute Visual Studio CMake path supplied by
  Flutter's toolchain configuration and removes inherited `CMAKE_*` variables.
- Generated binaries and model weights are never committed.

## Review and upgrades

Every `llama.cpp` or Dart dependency upgrade requires a separate review of:

1. immutable source identity and license;
2. build scripts and any new download or code-generation step;
3. native ABI changes and exported symbols;
4. platform build output and runtime dependencies;
5. model-load, generation, cancellation and disposal smoke tests.

Do not update the source commit, dependency versions and generated lockfile in
an unrelated feature change.
