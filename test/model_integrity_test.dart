import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_local_llm/venera_local_llm.dart';

void main() {
  test('loads the pinned native runtime', () {
    expect(LocalLlmRuntime.isSupported, isTrue);
    expect(
      LocalLlmRuntime.version,
      'llama.cpp@08659901c43b51de735740f1cf61bb82fbe0c4e4',
    );
  });

  test('accepts the expected model digest and rejects tampering', () async {
    var directory = await Directory.systemTemp.createTemp('venera-llm-model-');
    try {
      var model = File('${directory.path}/model.gguf');
      await model.writeAsString('abc');
      const digest =
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

      expect(await ModelIntegrity.verifySha256(model.path, digest), isTrue);
      await model.writeAsString('tampered');
      expect(await ModelIntegrity.verifySha256(model.path, digest), isFalse);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('rejects malformed digests before hashing', () async {
    expect(await ModelIntegrity.verifySha256('missing.gguf', 'bad'), isFalse);
  });
}
