import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/verify_llama_cpp_source.dart <source-directory>',
    );
    exitCode = 64;
    return;
  }

  var manifestFile = File('third_party/llama.cpp.source.json');
  if (!manifestFile.existsSync()) {
    stderr.writeln('Missing llama.cpp source manifest');
    exitCode = 2;
    return;
  }
  var manifest = jsonDecode(await manifestFile.readAsString());
  if (manifest is! Map || manifest['commit'] is! String) {
    stderr.writeln('Invalid llama.cpp source manifest');
    exitCode = 2;
    return;
  }

  var source = Directory(arguments.single).absolute;
  if (!File('${source.path}/include/llama.h').existsSync()) {
    stderr.writeln('llama.cpp source is missing or incomplete');
    exitCode = 2;
    return;
  }

  Future<ProcessResult> git(List<String> args) =>
      Process.run('git', ['-C', source.path, ...args], runInShell: false);

  var head = await git(['rev-parse', 'HEAD']);
  if (head.exitCode != 0 ||
      head.stdout.toString().trim() != manifest['commit']) {
    stderr.writeln('llama.cpp commit does not match the trusted manifest');
    exitCode = 2;
    return;
  }
  var status = await git(['status', '--porcelain', '--untracked-files=no']);
  if (status.exitCode != 0 || status.stdout.toString().trim().isNotEmpty) {
    stderr.writeln('llama.cpp tracked source files are modified');
    exitCode = 2;
    return;
  }

  stdout.writeln('Verified llama.cpp source: ${manifest['commit']}');
}
