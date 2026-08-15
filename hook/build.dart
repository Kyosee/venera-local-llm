import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

import 'source_integrity.dart';

const nativeHiddenVisibilityFlags = ['-fvisibility=hidden'];
const veneraLocalLlmAbiSymbols = [
  'venera_llm_cancel',
  'venera_llm_complete_async',
  'venera_llm_create',
  'venera_llm_destroy',
  'venera_llm_free_string',
  'venera_llm_version',
];

void main(List<String> arguments) async {
  await build(arguments, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    if (input.config.code.targetOS != OS.android &&
        input.config.code.targetOS != OS.iOS &&
        input.config.code.targetOS != OS.windows) {
      return;
    }

    var packageRoot = input.packageRoot;
    var sourceDir = Directory.fromUri(
      packageRoot.resolve('third_party/llama.cpp/'),
    );
    var sourceDependencies = await verifyVendoredSource(packageRoot, sourceDir);
    var llamaSources = await _llamaCppSources(
      sourceDir,
      input.config.code.targetArchitecture,
    );
    if (input.config.code.targetOS == OS.windows) {
      await _buildWindowsWithCmake(input, output, sourceDir);
      output.dependencies.addAll(sourceDependencies);
      output.dependencies.addAll([
        packageRoot.resolve('CMakeLists.txt'),
        packageRoot.resolve('include/venera_local_llm.h'),
        packageRoot.resolve('src/venera_local_llm.cpp'),
        packageRoot.resolve('third_party/llama.cpp.source.json'),
      ]);
      return;
    }

    var cSources = llamaSources.where((path) => path.endsWith('.c')).toList();
    var cppSources = llamaSources
        .where((path) => path.endsWith('.cpp'))
        .toList();
    var includes = [
      'include',
      '${sourceDir.path}/include',
      '${sourceDir.path}/src',
      '${sourceDir.path}/ggml/include',
      '${sourceDir.path}/ggml/src',
      '${sourceDir.path}/ggml/src/ggml-cpu',
    ];
    var defines = {
      'VENERA_LOCAL_LLM_BUILD': null,
      'GGML_USE_CPU': null,
      'GGML_VERSION': '"0.19.0"',
      'GGML_COMMIT': '"0865990"',
      if (input.config.code.targetOS == OS.android) '_GNU_SOURCE': null,
      if (input.config.code.targetOS == OS.iOS) '_DARWIN_C_SOURCE': null,
    };

    await CBuilder.library(
      name: 'venera_llama_c',
      sources: cSources,
      includes: includes,
      defines: defines,
      flags: [
        ...nativeHiddenVisibilityFlags,
        if (input.config.code.targetOS == OS.android) '-pthread',
      ],
      linkModePreference: LinkModePreference.static,
    ).run(input: input, output: output);

    var responseFile = File.fromUri(
      input.outputDirectory.resolve('llama_cpp_sources.rsp'),
    );
    await responseFile.parent.create(recursive: true);
    await responseFile.writeAsString(
      cppSources
          .map((path) => '"${clangResponsePath(path)}"')
          .join(Platform.lineTerminator),
      flush: true,
    );
    var exportControlFile = await writeNativeExportControlFile(input);

    var builder = CBuilder.library(
      name: 'venera_local_llm',
      assetName: 'src/native_bindings.dart',
      sources: ['src/venera_local_llm.cpp', 'src/ggml_backend_dl_disabled.cpp'],
      includes: includes,
      defines: defines,
      libraries: ['venera_llama_c'],
      libraryDirectories: ['.'],
      language: Language.cpp,
      std: 'c++17',
      cppLinkStdLib: input.config.code.targetOS == OS.android
          ? 'c++_static'
          : null,
      flags: [
        '@${responseFile.path}',
        ...nativeHiddenVisibilityFlags,
        nativeExportControlFlag(
          input.config.code.targetOS,
          exportControlFile.path,
        ),
        if (input.config.code.targetOS == OS.android) '-pthread',
      ],
    );
    await builder.run(input: input, output: output);
    output.dependencies.addAll(sourceDependencies);
    output.dependencies.add(
      packageRoot.resolve('third_party/llama.cpp.source.json'),
    );
  });
}

String clangResponsePath(String path) => path.replaceAll('\\', '/');

String nativeExportControlContents(OS targetOS) {
  return switch (targetOS) {
    OS.android =>
      '''
{
  global:
    ${veneraLocalLlmAbiSymbols.map((symbol) => '$symbol;').join('\n    ')}
  local:
    *;
};
''',
    OS.iOS =>
      '${veneraLocalLlmAbiSymbols.map((symbol) => '_$symbol').join('\n')}\n',
    _ => throw UnsupportedError('Export control is unsupported for $targetOS'),
  };
}

String nativeExportControlFlag(OS targetOS, String path) {
  var normalizedPath = clangResponsePath(path);
  return switch (targetOS) {
    OS.android => '-Wl,--version-script=$normalizedPath',
    OS.iOS => '-Wl,-exported_symbols_list,$normalizedPath',
    _ => throw UnsupportedError('Export control is unsupported for $targetOS'),
  };
}

Future<File> writeNativeExportControlFile(BuildInput input) async {
  var extension = input.config.code.targetOS == OS.android ? 'map' : 'list';
  var file = File.fromUri(
    input.outputDirectory.resolve('venera_local_llm.exports.$extension'),
  );
  await file.writeAsString(
    nativeExportControlContents(input.config.code.targetOS),
    flush: true,
  );
  return file;
}

Future<void> _buildWindowsWithCmake(
  BuildInput input,
  BuildOutputBuilder output,
  Directory sourceDir,
) async {
  var compiler = input.config.code.cCompiler;
  if (compiler == null) {
    throw StateError('Windows C compiler configuration is missing');
  }
  var compilerPath = compiler.compiler.toFilePath();
  var marker = '${Platform.pathSeparator}VC${Platform.pathSeparator}';
  var markerIndex = compilerPath.indexOf(marker);
  if (markerIndex < 0) {
    throw StateError('Unable to locate Visual Studio from $compilerPath');
  }
  var visualStudioRoot = compilerPath.substring(0, markerIndex);
  var cmake = File(
    '$visualStudioRoot${Platform.pathSeparator}Common7${Platform.pathSeparator}'
    'IDE${Platform.pathSeparator}CommonExtensions${Platform.pathSeparator}'
    'Microsoft${Platform.pathSeparator}CMake${Platform.pathSeparator}CMake'
    '${Platform.pathSeparator}bin${Platform.pathSeparator}cmake.exe',
  );
  if (!cmake.existsSync()) {
    throw StateError('Visual Studio CMake is required: ${cmake.path}');
  }

  var architecture = switch (input.config.code.targetArchitecture) {
    Architecture.x64 => 'x64',
    Architecture.ia32 => 'Win32',
    Architecture.arm64 => 'ARM64',
    _ => throw UnsupportedError(
      'Unsupported Windows architecture: '
      '${input.config.code.targetArchitecture}',
    ),
  };
  var sourceKey = sha256
      .convert(utf8.encode(input.packageRoot.toString()))
      .toString()
      .substring(0, 16);
  var buildDir = Directory.fromUri(
    input.outputDirectory.resolve('cmake-windows-$sourceKey/'),
  );
  await buildDir.create(recursive: true);
  var outputPath = input.outputDirectory.toFilePath();
  var environment = Map<String, String>.from(Platform.environment);
  for (var key in environment.keys.toList()) {
    if (key.toUpperCase().startsWith('CMAKE_')) environment.remove(key);
  }
  await _run(cmake.path, [
    '-S',
    input.packageRoot.toFilePath(),
    '-B',
    buildDir.path,
    '-G',
    'Visual Studio 17 2022',
    '-A',
    architecture,
    '-DVENERA_LLAMA_CPP_SOURCE_DIR=${sourceDir.path}',
    '-DCMAKE_RUNTIME_OUTPUT_DIRECTORY_RELEASE=$outputPath',
    '-DCMAKE_LIBRARY_OUTPUT_DIRECTORY_RELEASE=$outputPath',
    '-DGGML_ACCELERATE=OFF',
    '-DGGML_BACKEND_DL=OFF',
    '-DGGML_BLAS=OFF',
    '-DGGML_CPU_ALL_VARIANTS=OFF',
    '-DGGML_CPU_KLEIDIAI=OFF',
    '-DGGML_LLAMAFILE=OFF',
  ], environment: environment);
  await _run(cmake.path, [
    '--build',
    buildDir.path,
    '--config',
    'Release',
    '--target',
    'venera_local_llm',
    '--parallel',
  ], environment: environment);
  var library = File.fromUri(
    input.outputDirectory.resolve('venera_local_llm.dll'),
  );
  if (!library.existsSync()) {
    throw StateError('CMake did not produce ${library.path}');
  }
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'src/native_bindings.dart',
      file: library.uri,
      linkMode: DynamicLoadingBundled(),
    ),
  );
}

Future<void> _run(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) async {
  var result = await Process.run(
    executable,
    arguments,
    environment: environment,
    includeParentEnvironment: environment == null,
    runInShell: false,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
}

Future<List<String>> _llamaCppSources(
  Directory sourceDir,
  Architecture architecture,
) async {
  var files = <String>[
    ...await _sourceFiles(Directory('${sourceDir.path}/src'), '.cpp'),
    ...await _sourceFiles(Directory('${sourceDir.path}/src/models'), '.cpp'),
    for (var path in _ggmlSources) '${sourceDir.path}/ggml/src/$path',
  ];
  switch (architecture) {
    case Architecture.arm || Architecture.arm64:
      files.addAll([
        '${sourceDir.path}/ggml/src/ggml-cpu/arch/arm/quants.c',
        '${sourceDir.path}/ggml/src/ggml-cpu/arch/arm/repack.cpp',
      ]);
    case Architecture.ia32 || Architecture.x64:
      files.addAll([
        '${sourceDir.path}/ggml/src/ggml-cpu/arch/x86/quants.c',
        '${sourceDir.path}/ggml/src/ggml-cpu/arch/x86/repack.cpp',
      ]);
    default:
      throw UnsupportedError(
        'Unsupported local LLM architecture: $architecture',
      );
  }
  for (var path in files) {
    if (!File(path).existsSync()) {
      throw StateError('Pinned llama.cpp source is incomplete: $path');
    }
  }
  files.sort();
  return files;
}

Future<List<String>> _sourceFiles(Directory directory, String extension) async {
  if (!directory.existsSync()) return const [];
  var files = await directory
      .list(recursive: false)
      .where((entity) => entity is File && entity.path.endsWith(extension))
      .map((entity) => entity.path)
      .toList();
  files.sort();
  return files;
}

const _ggmlSources = [
  'ggml.c',
  'ggml.cpp',
  'ggml-alloc.c',
  'ggml-backend.cpp',
  'ggml-backend-meta.cpp',
  'ggml-backend-reg.cpp',
  'ggml-opt.cpp',
  'ggml-threading.cpp',
  'ggml-quants.c',
  'gguf.cpp',
  'ggml-cpu/ggml-cpu.c',
  'ggml-cpu/ggml-cpu.cpp',
  'ggml-cpu/repack.cpp',
  'ggml-cpu/hbm.cpp',
  'ggml-cpu/quants.c',
  'ggml-cpu/traits.cpp',
  'ggml-cpu/amx/amx.cpp',
  'ggml-cpu/amx/mmq.cpp',
  'ggml-cpu/binary-ops.cpp',
  'ggml-cpu/unary-ops.cpp',
  'ggml-cpu/vec.cpp',
  'ggml-cpu/ops.cpp',
];
