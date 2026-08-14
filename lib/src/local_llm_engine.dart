import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'model_integrity.dart';
import 'native_bindings.dart';

final class LocalLlmException implements Exception {
  const LocalLlmException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => code == null
      ? 'LocalLlmException: $message'
      : 'LocalLlmException($code): $message';
}

abstract final class LocalLlmRuntime {
  static bool get isSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isWindows;

  static String get version {
    if (!isSupported) {
      throw const LocalLlmException('current platform is not supported');
    }
    return const NativeBindings().version().toDartString();
  }
}

final class LocalLlmEngine {
  LocalLlmEngine._(this._bindings, this._handle) {
    _callback = NativeCallable<CompletionNative>.listener(_onComplete);
  }

  final NativeBindings _bindings;
  final Pointer<Void> _handle;
  late final NativeCallable<CompletionNative> _callback;
  final Map<int, Completer<String>> _pending = {};
  int _nextRequestId = 1;
  bool _disposed = false;

  static Future<LocalLlmEngine> load({
    required String modelPath,
    required String expectedSha256,
    int contextSize = 4096,
    int threads = 4,
  }) async {
    if (!await ModelIntegrity.verifySha256(modelPath, expectedSha256)) {
      throw const LocalLlmException('model SHA-256 verification failed');
    }
    if (contextSize < 512 || threads < 1) {
      throw const LocalLlmException('invalid context size or thread count');
    }

    const bindings = NativeBindings();
    var nativePath = modelPath.toNativeUtf8();
    var errorOut = calloc<Pointer<Utf8>>();
    try {
      var handle = bindings.create(nativePath, contextSize, threads, errorOut);
      if (handle == nullptr) {
        var error = errorOut.value == nullptr
            ? 'native model load failed'
            : errorOut.value.toDartString();
        if (errorOut.value != nullptr) bindings.freeString(errorOut.value);
        throw LocalLlmException(error);
      }
      return LocalLlmEngine._(bindings, handle);
    } finally {
      calloc.free(nativePath);
      calloc.free(errorOut);
    }
  }

  String get runtimeVersion => _bindings.version().toDartString();

  Future<String> complete({
    required String systemPrompt,
    required String userPrompt,
    int maxTokens = 1024,
    double temperature = 0.2,
    int seed = 0,
  }) {
    if (_disposed) {
      throw const LocalLlmException('engine is disposed');
    }
    if (maxTokens < 1 || temperature <= 0) {
      throw const LocalLlmException('invalid generation options');
    }

    var requestId = _nextRequestId++;
    var completer = Completer<String>();
    _pending[requestId] = completer;
    var userData = calloc<Uint64>()..value = requestId;
    var nativeSystem = systemPrompt.toNativeUtf8();
    var nativeUser = userPrompt.toNativeUtf8();
    try {
      var result = _bindings.completeAsync(
        _handle,
        nativeSystem,
        nativeUser,
        maxTokens,
        temperature,
        seed,
        _callback.nativeFunction,
        userData.cast(),
      );
      if (result != 0) {
        _pending.remove(requestId);
        calloc.free(userData);
        throw LocalLlmException('native request was rejected', code: result);
      }
    } finally {
      calloc.free(nativeSystem);
      calloc.free(nativeUser);
    }
    return completer.future;
  }

  void cancel() {
    if (!_disposed) _bindings.cancel(_handle);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _bindings.cancel(_handle);
    var pending = _pending.values.map(
      (entry) => entry.future.then<void>((_) {}, onError: (_) {}),
    );
    await Future.wait(pending);
    _bindings.destroy(_handle);
    _callback.close();
  }

  void _onComplete(
    Pointer<Void> rawUserData,
    Pointer<Utf8> rawResult,
    int errorCode,
  ) {
    var userData = rawUserData.cast<Uint64>();
    var requestId = userData.value;
    calloc.free(userData);
    var completer = _pending.remove(requestId);
    var message = rawResult == nullptr ? '' : rawResult.toDartString();
    if (rawResult != nullptr) _bindings.freeString(rawResult);
    if (completer == null) return;
    if (errorCode == 0) {
      completer.complete(message);
    } else {
      completer.completeError(
        LocalLlmException(
          message.isEmpty ? 'native generation failed' : message,
          code: errorCode,
        ),
      );
    }
  }
}
