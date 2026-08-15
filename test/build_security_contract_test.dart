import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../hook/build.dart'
    show
        clangResponsePath,
        nativeExportControlContents,
        nativeExportControlFlag,
        nativeHiddenVisibilityFlags,
        veneraLocalLlmAbiSymbols;

void main() {
  test('native builds are disconnected and disable backend plugins', () {
    var cmake = File('CMakeLists.txt').readAsStringSync();
    var hook = File('hook/build.dart').readAsStringSync();
    var shim = File('src/ggml_backend_dl_disabled.cpp').readAsStringSync();

    expect(cmake, contains('FETCHCONTENT_FULLY_DISCONNECTED ON'));
    expect(cmake, contains('CMAKE_DISABLE_FIND_PACKAGE_Git ON'));
    expect(cmake, contains('CMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH OFF'));
    expect(cmake, contains('ggml_backend_dl_disabled.cpp'));
    expect(hook, contains("'src/ggml_backend_dl_disabled.cpp'"));
    expect(hook, isNot(contains("'ggml-backend-dl.cpp'")));
    expect(hook, contains('LinkModePreference.static'));
    expect(hook, contains("libraries: ['venera_llama_c']"));
    expect(hook, contains("? 'c++_static'"));
    expect(nativeHiddenVisibilityFlags, ['-fvisibility=hidden']);
    expect(
      RegExp(r'\.\.\.nativeHiddenVisibilityFlags').allMatches(hook),
      hasLength(2),
    );
    expect(hook, contains("utf8.encode(input.packageRoot.toString())"));
    expect(hook, contains("'cmake-windows-\$sourceKey/'"));
    expect(shim, isNot(contains('LoadLibrary')));
    expect(shim, isNot(contains('dlopen')));
  });

  test('clang response-file paths use forward slashes', () {
    expect(
      clangResponsePath(r'C:\Users\venera local\llama.cpp\src\llama.cpp'),
      'C:/Users/venera local/llama.cpp/src/llama.cpp',
    );
    expect(clangResponsePath('/tmp/llama.cpp'), '/tmp/llama.cpp');
  });

  test('mobile linkers export only the six owned ABI symbols', () {
    expect(veneraLocalLlmAbiSymbols, [
      'venera_llm_cancel',
      'venera_llm_complete_async',
      'venera_llm_create',
      'venera_llm_destroy',
      'venera_llm_free_string',
      'venera_llm_version',
    ]);
    var androidControl = nativeExportControlContents(OS.android);
    var iosControl = nativeExportControlContents(OS.iOS);
    for (var symbol in veneraLocalLlmAbiSymbols) {
      expect(androidControl, contains('$symbol;'));
      expect(iosControl, contains('_$symbol\n'));
    }
    expect(androidControl, contains('local:\n    *;'));
    expect(
      nativeExportControlFlag(OS.android, r'C:\build output\exports.map'),
      '-Wl,--version-script=C:/build output/exports.map',
    );
    expect(
      nativeExportControlFlag(OS.iOS, '/tmp/build output/exports.list'),
      '-Wl,-exported_symbols_list,/tmp/build output/exports.list',
    );
  });
}
