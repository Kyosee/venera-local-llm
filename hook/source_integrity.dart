import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const reviewedLlamaCppCommit = '08659901c43b51de735740f1cf61bb82fbe0c4e4';

Future<List<Uri>> verifyVendoredSource(
  Uri packageRoot,
  Directory sourceDir,
) async {
  var manifestFile = File.fromUri(
    packageRoot.resolve('third_party/llama.cpp.source.json'),
  );
  if (!manifestFile.existsSync() ||
      !File('${sourceDir.path}/include/llama.h').existsSync()) {
    throw StateError('Pinned llama.cpp source is missing');
  }

  var manifest = jsonDecode(await manifestFile.readAsString());
  if (manifest is! Map ||
      manifest['commit'] != reviewedLlamaCppCommit ||
      manifest['sourceMode'] != 'vendored' ||
      manifest['fileCount'] is! int ||
      manifest['snapshotSha256'] is! String) {
    throw StateError('Invalid llama.cpp source manifest');
  }

  var snapshot = await calculateSourceSnapshot(sourceDir);
  if (snapshot.files.length != manifest['fileCount'] ||
      snapshot.sha256Digest != manifest['snapshotSha256']) {
    throw StateError(
      'llama.cpp source snapshot failed integrity verification: expected '
      '${manifest['fileCount']}/${manifest['snapshotSha256']}, got '
      '${snapshot.files.length}/${snapshot.sha256Digest}',
    );
  }
  return snapshot.files.map((file) => file.uri).toList(growable: false);
}

Future<SourceSnapshot> calculateSourceSnapshot(Directory sourceDir) async {
  var rootPath = sourceDir.absolute.path;
  while (rootPath.endsWith(Platform.pathSeparator)) {
    rootPath = rootPath.substring(0, rootPath.length - 1);
  }
  var prefix = '$rootPath${Platform.pathSeparator}';
  var comparisonPrefix = Platform.isWindows ? prefix.toLowerCase() : prefix;
  var entries = <({String path, File file})>[];
  await for (var entity in sourceDir.list(
    recursive: true,
    followLinks: false,
  )) {
    var absolutePath = entity.absolute.path;
    var gitSegment = '${Platform.pathSeparator}.git${Platform.pathSeparator}';
    if (absolutePath.endsWith('${Platform.pathSeparator}.git') ||
        absolutePath.contains(gitSegment)) {
      throw StateError('Vendored source contains nested Git metadata');
    }
    if (entity is Link) {
      throw StateError('Vendored source contains a symbolic link');
    }
    if (entity is! File) continue;
    var comparisonPath = Platform.isWindows
        ? absolutePath.toLowerCase()
        : absolutePath;
    if (!comparisonPath.startsWith(comparisonPrefix)) {
      throw StateError('Vendored source escaped its root directory');
    }
    entries.add((
      path: absolutePath
          .substring(prefix.length)
          .replaceAll(Platform.pathSeparator, '/'),
      file: entity,
    ));
  }
  entries.sort((a, b) => a.path.compareTo(b.path));

  var canonical = StringBuffer();
  for (var entry in entries) {
    var fileDigest = await sha256.bind(entry.file.openRead()).first;
    canonical.writeln('$fileDigest  ${entry.path}');
  }
  return SourceSnapshot(
    entries.map((entry) => entry.file).toList(growable: false),
    sha256.convert(utf8.encode(canonical.toString())).toString(),
  );
}

final class SourceSnapshot {
  const SourceSnapshot(this.files, this.sha256Digest);

  final List<File> files;
  final String sha256Digest;
}
