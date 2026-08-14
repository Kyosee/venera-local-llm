import 'dart:ffi';

import 'package:ffi/ffi.dart';

const _assetId = 'package:venera_local_llm/src/native_bindings.dart';

typedef CompletionNative = Void Function(Pointer<Void>, Pointer<Utf8>, Int32);

typedef _CreateNative =
    Pointer<Void> Function(Pointer<Utf8>, Int32, Int32, Pointer<Pointer<Utf8>>);
typedef _CompleteNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Int32,
      Float,
      Uint32,
      Pointer<NativeFunction<CompletionNative>>,
      Pointer<Void>,
    );
typedef _EngineVoidNative = Void Function(Pointer<Void>);
typedef _FreeStringNative = Void Function(Pointer<Utf8>);
typedef _VersionNative = Pointer<Utf8> Function();

@Native<_CreateNative>(symbol: 'venera_llm_create', assetId: _assetId)
external Pointer<Void> _create(
  Pointer<Utf8> modelPath,
  int contextSize,
  int threads,
  Pointer<Pointer<Utf8>> errorOut,
);

@Native<_CompleteNative>(symbol: 'venera_llm_complete_async', assetId: _assetId)
external int _completeAsync(
  Pointer<Void> engine,
  Pointer<Utf8> systemPrompt,
  Pointer<Utf8> userPrompt,
  int maxTokens,
  double temperature,
  int seed,
  Pointer<NativeFunction<CompletionNative>> callback,
  Pointer<Void> userData,
);

@Native<_EngineVoidNative>(symbol: 'venera_llm_cancel', assetId: _assetId)
external void _cancel(Pointer<Void> engine);

@Native<_EngineVoidNative>(symbol: 'venera_llm_destroy', assetId: _assetId)
external void _destroy(Pointer<Void> engine);

@Native<_FreeStringNative>(symbol: 'venera_llm_free_string', assetId: _assetId)
external void _freeString(Pointer<Utf8> value);

@Native<_VersionNative>(symbol: 'venera_llm_version', assetId: _assetId)
external Pointer<Utf8> _version();

final class NativeBindings {
  const NativeBindings();

  Pointer<Void> create(
    Pointer<Utf8> modelPath,
    int contextSize,
    int threads,
    Pointer<Pointer<Utf8>> errorOut,
  ) => _create(modelPath, contextSize, threads, errorOut);

  int completeAsync(
    Pointer<Void> engine,
    Pointer<Utf8> systemPrompt,
    Pointer<Utf8> userPrompt,
    int maxTokens,
    double temperature,
    int seed,
    Pointer<NativeFunction<CompletionNative>> callback,
    Pointer<Void> userData,
  ) => _completeAsync(
    engine,
    systemPrompt,
    userPrompt,
    maxTokens,
    temperature,
    seed,
    callback,
    userData,
  );

  void cancel(Pointer<Void> engine) => _cancel(engine);
  void destroy(Pointer<Void> engine) => _destroy(engine);
  void freeString(Pointer<Utf8> value) => _freeString(value);
  Pointer<Utf8> version() => _version();
}
