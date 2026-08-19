/// The dartx command line: compile `.dartx` files to Dart, or just check them.
///
/// ```
/// dart run reactx:dartx lib/ example/      # compile in place
/// dart run reactx:dartx --check lib/       # report problems only
/// dart run reactx:dartx --stdin --json --name app.dartx < buf   # editors
/// ```
///
/// `build_runner` does the same job for a whole package; this exists for
/// one-off runs, CI checks, and for editors that need diagnostics for an
/// unsaved buffer (which is what `--stdin --json` is for).
library;

import 'dart:convert';
import 'dart:io';

import 'package:reactx/dartx.dart';

const _usage = '''
Usage: dart run reactx:dartx [options] <file-or-directory>...

Compiles .dartx files to .dartx.dart next to the source.

Options:
  -c, --check        Report problems only; write nothing.
  -j, --json         Emit diagnostics as JSON (for editors).
  -o, --output PATH  Write the result to PATH (single input only).
      --stdout       Write the result to stdout instead of a file.
      --stdin        Read the source from stdin.
      --name NAME    Filename to report for --stdin input.
      --no-banner    Omit the generated-file banner.
      --server       Answer check requests on stdin, one JSON object per line
                     ({"uri":…,"source":…}), replying with one JSON object per
                     line. Keeps the VM warm for editors.
  -h, --help         Show this help.

Exit codes: 0 ok, 1 compile errors, 2 bad usage.
''';

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  if (options == null) {
    stderr.write(_usage);
    exitCode = 2;
    return;
  }
  if (options.help) {
    stdout.write(_usage);
    return;
  }
  if (options.server) {
    await _serve();
    return;
  }

  final errors = <DartxError>[];

  if (options.stdin) {
    final source = await systemEncoding.decodeStream(stdin);
    errors.addAll(_process(source, options.name ?? '-', options,
        forceStdout: options.output == null));
  } else {
    final inputs = _collectInputs(options.paths);
    if (inputs.isEmpty) {
      stderr.writeln('dartx: no .dartx files found in '
          '${options.paths.join(', ')}');
      exitCode = 2;
      return;
    }
    if (options.output != null && inputs.length > 1) {
      stderr.writeln('dartx: --output takes a single input file');
      exitCode = 2;
      return;
    }
    for (final file in inputs) {
      errors.addAll(_process(file.readAsStringSync(), file.path, options));
    }
  }

  if (options.json) {
    stdout.writeln(jsonEncode({
      'diagnostics': [for (final e in errors) e.toJson()],
    }));
  } else {
    for (final e in errors) {
      stderr.writeln('dartx: $e');
    }
  }
  exitCode = errors.isEmpty ? 0 : 1;
}

/// Long-lived check mode for editors.
///
/// Starting a Dart VM per keystroke costs about a second; this reads one
/// request per line and answers in microseconds, so an editor can re-check the
/// buffer as it is typed.
Future<void> _serve() async {
  final lines = stdin
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());

  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    Object? response;
    try {
      final request = jsonDecode(line) as Map<String, Object?>;
      final uri = request['uri'] as String? ?? '-';
      final result = transpileDartx(
        request['source'] as String? ?? '',
        uri: uri,
        banner: false,
      );
      response = {
        'uri': uri,
        'diagnostics': [for (final e in result.errors) e.toJson()],
      };
    } catch (e) {
      response = {'error': '$e'};
    }
    stdout.writeln(jsonEncode(response));
  }
}

List<DartxError> _process(
  String source,
  String uri,
  _Options options, {
  bool forceStdout = false,
}) {
  final result = transpileDartx(source, uri: uri, banner: options.banner);
  if (!result.ok) return result.errors;
  if (options.check) return const [];

  if (options.toStdout || forceStdout) {
    stdout.write(result.code);
  } else {
    final target = options.output ?? '$uri.dart';
    File(target).writeAsStringSync(result.code!);
    if (!options.json) stderr.writeln('dartx: wrote $target');
  }
  return const [];
}

List<File> _collectInputs(List<String> paths) {
  final files = <File>[];
  for (final path in paths) {
    final directory = Directory(path);
    if (directory.existsSync()) {
      files.addAll(directory
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dartx')));
    } else if (path.endsWith('.dartx')) {
      files.add(File(path));
    } else {
      stderr.writeln('dartx: skipping $path (not a .dartx file or directory)');
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

class _Options {
  final List<String> paths;
  final bool check;
  final bool json;
  final bool stdin;
  final bool server;
  final bool toStdout;
  final bool banner;
  final bool help;
  final String? output;
  final String? name;

  const _Options({
    required this.paths,
    required this.check,
    required this.json,
    required this.stdin,
    required this.server,
    required this.toStdout,
    required this.banner,
    required this.help,
    this.output,
    this.name,
  });

  /// Returns `null` on a usage error.
  static _Options? parse(List<String> args) {
    final paths = <String>[];
    var check = false, json = false, useStdin = false, toStdout = false;
    var server = false;
    var banner = true, help = false;
    String? output, name;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      String? next() => i + 1 < args.length ? args[++i] : null;
      switch (arg) {
        case '-c' || '--check':
          check = true;
        case '-j' || '--json':
          json = true;
        case '--stdin':
          useStdin = true;
        case '--server':
          server = true;
        case '--stdout':
          toStdout = true;
        case '--no-banner':
          banner = false;
        case '-h' || '--help':
          help = true;
        case '-o' || '--output':
          output = next();
          if (output == null) return null;
        case '--name':
          name = next();
          if (name == null) return null;
        default:
          if (arg.startsWith('-')) return null;
          paths.add(arg);
      }
    }

    if (!help && !useStdin && !server && paths.isEmpty) return null;
    return _Options(
      paths: paths,
      check: check,
      json: json,
      stdin: useStdin,
      server: server,
      toStdout: toStdout,
      banner: banner,
      help: help,
      output: output,
      name: name,
    );
  }
}
