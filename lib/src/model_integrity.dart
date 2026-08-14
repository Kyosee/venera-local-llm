import 'dart:io';

import 'package:crypto/crypto.dart';

abstract final class ModelIntegrity {
  static Future<bool> verifySha256(
    String filePath,
    String expectedSha256,
  ) async {
    var expected = expectedSha256.trim().toLowerCase();
    var file = File(filePath);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expected) ||
        !file.existsSync() ||
        file.lengthSync() == 0) {
      return false;
    }
    var digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == expected;
  }
}
