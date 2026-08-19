/// `dart run reactx:serve <app-dir>` — the development server.
///
/// ```
/// dart run reactx:serve example/todo_app
/// dart run reactx:serve example/todo_app --port 3000 -O2
/// ```
///
/// Watches the directory, compiles `.dartx` in process, recompiles only the
/// libraries that changed, and patches them into the running page — with a
/// status indicator on the page and build errors shown as an overlay instead
/// of scrolling past in the terminal.
///
/// This is a hot *reload*: the page is not reloaded and your state is still
/// there afterwards. It needs a DDC-compiled `dart_sdk.js`, which in practice
/// means a Flutter SDK on the machine; without one the server says so on
/// startup and falls back to the old hot restart.
///
/// Your `server.dart` needs to accept a `--port` argument; the dev server
/// chooses the port it runs on and proxies to it.
library;

import 'dart:async';
import 'dart:io';

import 'package:reactx/src/devserver/dev_server.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.write(_usage);
    return;
  }

  final positional = args.where((a) => !a.startsWith('-')).toList();
  final dir = Directory(positional.isEmpty ? '.' : positional.first);
  if (!dir.existsSync()) {
    stderr.writeln('reactx serve: no such directory: ${dir.path}');
    exitCode = 2;
    return;
  }

  final server = DevServer(
    appDir: dir,
    port: int.tryParse(_flag(args, '--port') ?? '') ?? 8080,
    entry: _flag(args, '--entry') ?? 'main.dart',
    serverScript: _flag(args, '--server') ?? 'server.dart',
    optimization: _optimization(args) ?? '1',
  );

  // A signal has to take the child server with it, or its port stays busy and
  // the next run cannot bind. SIGTERM as well as Ctrl-C: a supervisor, a test
  // harness or an IDE stopping the task all send that one, and the orphan it
  // used to leave behind outlived the terminal it was started from.
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  Future<void> shutdown() async {
    stdout.writeln('\nstopping…');
    await server.stop();
    for (final s in subscriptions) {
      await s.cancel();
    }
    exit(0);
  }

  subscriptions.add(ProcessSignal.sigint.watch().listen((_) => shutdown()));
  if (!Platform.isWindows) {
    subscriptions.add(ProcessSignal.sigterm.watch().listen((_) => shutdown()));
  }

  try {
    await server.start();
  } catch (error) {
    stderr.writeln('reactx serve: $error');
    await server.stop();
    exitCode = 1;
  }
}

String? _flag(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

/// Accepts `-O2` the way `dart compile js` does.
String? _optimization(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('-O') && arg.length == 3) return arg.substring(2);
  }
  return null;
}

const _usage = '''
reactx serve — development server with hot reload

usage: dart run reactx:serve [app-dir] [options]

  app-dir            directory holding main.dart and server.dart (default: .)
  --port <n>         port to serve on (default: 8080)
  --entry <file>     client entrypoint (default: main.dart)
  --server <file>    SSR server, must accept --port (default: server.dart)
  -O<level>          optimization level for the fallback dart2js build
  -h, --help         show this

On every save it transpiles .dartx, recompiles the libraries that changed, and
patches them into the running page. The page is not reloaded and your state is
still there. Build errors appear as an overlay on the page.

Hot reload needs a DDC-compiled dart_sdk.js — in practice a Flutter SDK, or
REACTX_DART_SDK_JS pointing at one. Without it the server says so and falls
back to a rebuild plus a page reload, where state is lost.
''';
