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

  test('snapshot canonicalizes CRLF to LF', () async {
    var lf = await Directory.systemTemp.createTemp('venera_source_lf_');
    var crlf = await Directory.systemTemp.createTemp('venera_source_crlf_');
    addTearDown(() async {
      await lf.delete(recursive: true);
      await crlf.delete(recursive: true);
    });
    await File(
      '${lf.path}/source.cpp',
    ).writeAsBytes(utf8.encode('first\nsecond\n'));
    await File(
      '${crlf.path}/source.cpp',
    ).writeAsBytes(utf8.encode('first\r\nsecond\r\n'));

    var lfSnapshot = await calculateSourceSnapshot(lf);
    var crlfSnapshot = await calculateSourceSnapshot(crlf);

    expect(crlfSnapshot.sha256Digest, lfSnapshot.sha256Digest);
  });

  test('snapshot still detects content changes', () async {
    var temp = await Directory.systemTemp.createTemp('venera_source_change_');
    addTearDown(() => temp.delete(recursive: true));
    var source = File('${temp.path}/source.cpp');
    await source.writeAsString('before\n');
    var before = await calculateSourceSnapshot(temp);

    await source.writeAsString('after\n');
    var after = await calculateSourceSnapshot(temp);

    expect(after.sha256Digest, isNot(before.sha256Digest));
  });

  test('unknown canonicalization fails closed', () async {
    var packageRoot = await Directory.systemTemp.createTemp(
      'venera_source_manifest_',
    );
    addTearDown(() => packageRoot.delete(recursive: true));
    var source = Directory('${packageRoot.path}/source');
    await Directory('${source.path}/include').create(recursive: true);
    await File('${source.path}/include/llama.h').writeAsString('header\n');
    var snapshot = await calculateSourceSnapshot(source);
    await Directory('${packageRoot.path}/third_party').create();
    await File(
      '${packageRoot.path}/third_party/llama.cpp.source.json',
    ).writeAsString(
      jsonEncode({
        'commit': reviewedLlamaCppCommit,
        'sourceMode': 'vendored',
        'canonicalization': 'unknown',
        'fileCount': snapshot.files.length,
        'snapshotSha256': snapshot.sha256Digest,
      }),
    );

    await expectLater(
      verifyVendoredSource(packageRoot.uri, source),
      throwsA(isA<StateError>()),
    );
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
