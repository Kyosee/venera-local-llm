import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../hook/source_integrity.dart';

void main() {
  test('vendored llama.cpp matches the reviewed snapshot', () async {
    var manifest =
        jsonDecode(
              await File('third_party/llama.cpp.source.json').readAsString(),
            )
            as Map<String, dynamic>;
    var snapshot = await calculateSourceSnapshot(
      Directory('third_party/llama.cpp'),
    );

    expect(snapshot.files, hasLength(manifest['fileCount'] as int));
    expect(snapshot.sha256Digest, manifest['snapshotSha256']);
  });

  test('snapshot identity includes paths and every file', () async {
    var temp = await Directory.systemTemp.createTemp('venera_source_hash_');
    addTearDown(() => temp.delete(recursive: true));
    await File('${temp.path}/a.cpp').writeAsString('same content');
    var first = await calculateSourceSnapshot(temp);

    await File('${temp.path}/b.cpp').writeAsString('same content');
    var second = await calculateSourceSnapshot(temp);

    expect(second.files, hasLength(first.files.length + 1));
    expect(second.sha256Digest, isNot(first.sha256Digest));
  });

  test('nested Git metadata fails closed', () async {
    var temp = await Directory.systemTemp.createTemp('venera_source_git_');
    addTearDown(() => temp.delete(recursive: true));
    await Directory('${temp.path}/.git').create();

    await expectLater(
      calculateSourceSnapshot(temp),
      throwsA(isA<StateError>()),
    );
  });
}
