import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> arguments) async {
  await build(arguments, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    var packageRoot = input.packageRoot;
    var sourceDir = Directory.fromUri(
      packageRoot.resolve('third_party/llama.cpp/'),
    );
    await _verifySource(packageRoot, sourceDir);
    var llamaSources = await _llamaCppSources(
      sourceDir,
      input.config.code.targetArchitecture,
    );
    if (input.config.code.targetOS == OS.windows) {
      await _buildWindowsWithCmake(input, output, sourceDir);
      output.dependencies.addAll(await _nativeDependencies(sourceDir));
      output.dependencies.addAll([
        packageRoot.resolve('CMakeLists.txt'),
        packageRoot.resolve('include/venera_local_llm.h'),
        packageRoot.resolve('src/venera_local_llm.cpp'),
        packageRoot.resolve('third_party/llama.cpp.source.json'),
      ]);
      return;
    }

    var responseFile = File.fromUri(
      input.outputDirectory.resolve('llama_cpp_sources.rsp'),
    );
    await responseFile.parent.create(recursive: true);
    await responseFile.writeAsString(
      llamaSources.map((path) => '"$path"').join(Platform.lineTerminator),
      flush: true,
    );

    var builder = CBuilder.library(
      name: 'venera_local_llm',
      assetName: 'src/native_bindings.dart',
      sources: ['src/venera_local_llm.cpp'],
      includes: [
        'include',
        '${sourceDir.path}/include',
        '${sourceDir.path}/src',
        '${sourceDir.path}/ggml/include',
        '${sourceDir.path}/ggml/src',
        '${sourceDir.path}/ggml/src/ggml-cpu',
      ],
      defines: {
        'VENERA_LOCAL_LLM_BUILD': null,
        'GGML_USE_CPU': null,
        'GGML_VERSION': '"0.19.0"',
        'GGML_COMMIT': '"0865990"',
        if (input.config.code.targetOS == OS.android) '_GNU_SOURCE': null,
        if (input.config.code.targetOS == OS.iOS) '_DARWIN_C_SOURCE': null,
        if (input.config.code.targetOS == OS.windows)
          '_CRT_SECURE_NO_WARNINGS': null,
      },
      language: Language.cpp,
      std: 'c++17',
      flags: [
        '@${responseFile.path}',
        if (input.config.code.targetOS == OS.windows)
          '/EHsc'
        else
          '-fvisibility=hidden',
        if (input.config.code.targetOS == OS.android) '-pthread',
      ],
    );
    await builder.run(input: input, output: output);
    output.dependencies.addAll(llamaSources.map(Uri.file));
  });
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
  var buildDir = Directory.fromUri(
    input.outputDirectory.resolve('cmake-windows/'),
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

Future<List<Uri>> _nativeDependencies(Directory sourceDir) async {
  var dependencies = <Uri>[];
  await for (var entity in sourceDir.list(recursive: true)) {
    if (entity is! File ||
        entity.path.contains('${Platform.pathSeparator}.git')) {
      continue;
    }
    if (_nativeDependencyExtensions.any(entity.path.endsWith) ||
        entity.path.endsWith('CMakeLists.txt')) {
      dependencies.add(entity.uri);
    }
  }
  dependencies.sort((a, b) => a.toString().compareTo(b.toString()));
  return dependencies;
}

Future<void> _verifySource(Uri packageRoot, Directory sourceDir) async {
  var manifestFile = File.fromUri(
    packageRoot.resolve('third_party/llama.cpp.source.json'),
  );
  if (!manifestFile.existsSync() ||
      !File('${sourceDir.path}/include/llama.h').existsSync()) {
    throw StateError(
      'Pinned llama.cpp source is missing. Run the reviewed bootstrap process '
      'before building.',
    );
  }
  var manifest = jsonDecode(await manifestFile.readAsString());
  if (manifest is! Map || manifest['commit'] is! String) {
    throw StateError('Invalid llama.cpp source manifest');
  }
  Future<ProcessResult> git(List<String> args) =>
      Process.run('git', ['-C', sourceDir.path, ...args], runInShell: false);
  var head = await git(['rev-parse', 'HEAD']);
  if (head.exitCode != 0 ||
      head.stdout.toString().trim() != manifest['commit']) {
    throw StateError('llama.cpp commit does not match the trusted manifest');
  }
  var status = await git(['status', '--porcelain', '--untracked-files=no']);
  if (status.exitCode != 0 || status.stdout.toString().trim().isNotEmpty) {
    throw StateError('llama.cpp tracked source files are modified');
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
  'ggml-backend-dl.cpp',
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

const _nativeDependencyExtensions = [
  '.c',
  '.cc',
  '.cpp',
  '.h',
  '.hpp',
  '.cmake',
];
