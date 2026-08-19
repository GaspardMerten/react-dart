/// The `.dartx` language server.
///
/// ```
/// dart run reactx:dartx_lsp        # speaks LSP on stdin/stdout
/// ```
///
/// You do not normally run this by hand — the VS Code extension launches it.
/// It proxies to `dart language-server`, so the Dart SDK on PATH is what
/// answers the questions; see `lib/src/lsp/server.dart` for how a position in
/// a `.dartx` becomes a position the analyser can act on.
library;

import 'dart:io';

import 'package:reactx/src/lsp/server.dart';

Future<void> main(List<String> args) async {
  final dart = _option(args, '--dart') ?? 'dart';
  // Logs go to a file rather than stderr: some editors surface a language
  // server's stderr as an error popup, and progress chatter is not an error.
  final logPath = _option(args, '--log');
  final log = logPath == null ? null : File(logPath).openWrite(mode: FileMode.append);

  final server = DartxLanguageServer(
    input: stdin,
    output: stdout,
    dartPath: dart,
    logSink: log,
  );

  await server.start();
  await log?.flush();
}

String? _option(List<String> args, String name) {
  for (final arg in args) {
    if (arg.startsWith('$name=')) return arg.substring(name.length + 1);
  }
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}
