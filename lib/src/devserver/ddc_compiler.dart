/// Drives `frontend_server` in DDC library-bundle mode, which is what makes
/// hot *reload* possible at all.
///
/// `dart compile js` produces one monolithic bundle with no notion of a
/// library boundary, so the only way to apply a change is to reload the page.
/// DDC's library-bundle format emits one `dartDevEmbedder.defineLibrary(...)`
/// per Dart library, and the module loader shipped with the SDK can swap
/// individual libraries into a *running* program. `frontend_server` keeps the
/// kernel in memory between calls, so a save recompiles only what changed —
/// milliseconds, and a few kilobytes of JS instead of a whole bundle.
///
/// This talks the frontend_server line protocol directly. One subtlety worth
/// knowing, because getting it wrong looks like a stale compile rather than an
/// error: a response is
///
/// ```
/// result <key>
/// <key>                       <- bare, opens the payload
/// +file:///…                  <- payload (dependencies, diagnostics)
/// <key> <output-dill> <n>     <- terminator, with the error count
/// ```
///
/// The bare `<key>` line is a boundary marker, *not* the terminator. Stopping
/// there means reading the output file before the compiler has written it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The JS for one compile, split the way the compiler emitted it.
class DdcBundle {
  DdcBundle(this.modules, this.libraries);

  /// One `dartDevEmbedder.defineLibrary(...)` block per Dart library, keyed by
  /// the compiler's module path and in emission order.
  ///
  /// Kept separate rather than concatenated because a page loaded *after* some
  /// saves needs a bundle where each library appears once: defining the same
  /// library twice outside a reload is an error the module loader throws on, so
  /// a delta has to replace its libraries in the bundle, not be appended to it.
  final Map<String, String> modules;

  /// The library names this bundle defines — exactly what
  /// `dartDevEmbedder.hotReload` wants as its second argument.
  final List<String> libraries;

  String get js => modules.values.join('\n');

  bool get isEmpty => libraries.isEmpty;
}

/// A compile that failed, with the compiler's own diagnostics.
class DdcError implements Exception {
  DdcError(this.message);
  final String message;
  @override
  String toString() => message;
}

class DdcCompiler {
  DdcCompiler({
    required this.appDir,
    required this.entry,
    required this.packageConfig,
    required this.sdkJs,
  });

  /// Doubles as the multi-root filesystem root, so library names are stable
  /// `org-dartlang-app:///…` URIs rather than absolute paths that would change
  /// between machines (and leak into the browser's sources panel).
  final Directory appDir;

  /// Entry file, relative to [appDir].
  final String entry;

  final File packageConfig;

  /// The DDC-compiled Dart SDK in library-bundle format.
  final File sdkJs;

  Process? _process;
  StreamIterator<String>? _lines;
  final StringBuffer _stderr = StringBuffer();
  var _generation = 0;

  /// Where the dill (and, next to it, the emitted JS) is written. Under
  /// `.dart_tool` so the file watcher ignores it.
  Directory get _work => Directory('${appDir.path}/.dart_tool/reactx_dev');

  String get entryLibrary => 'org-dartlang-app:///$entry';

  /// Resolves the Dart SDK the running `dart` belongs to.
  static Directory get sdkRoot =>
      File(Platform.resolvedExecutable).parent.parent;

  /// The module loader that defines `dartDevEmbedder` in the page.
  static File get moduleLoader =>
      File('${sdkRoot.path}/lib/dev_compiler/ddc/ddc_module_loader.js');

  /// Finds a DDC-compiled SDK in the library-bundle format.
  ///
  /// The plain Dart SDK ships only `ddc_platform.dill`, not the compiled JS, so
  /// in practice this comes from a Flutter checkout — its web SDK is a superset
  /// of the plain one (it merely also carries `dart:ui`), and links fine with
  /// an app compiled against `ddc_platform.dill`. `REACTX_DART_SDK_JS` overrides
  /// the search for anyone whose layout differs.
  static File? findSdkJs() {
    final override = Platform.environment['REACTX_DART_SDK_JS'];
    if (override != null && override.isNotEmpty) {
      final file = File(override);
      return file.existsSync() ? file : null;
    }
    // .../flutter/bin/cache/dart-sdk → .../flutter/bin/cache/flutter_web_sdk
    final candidates = [
      '${sdkRoot.parent.path}/flutter_web_sdk/kernel/'
          'ddcLibraryBundle-canvaskit/dart_sdk.js',
      '${sdkRoot.parent.path}/flutter_web_sdk/kernel/'
          'ddcLibraryBundle-html/dart_sdk.js',
    ];
    for (final path in candidates) {
      final file = File(path);
      if (file.existsSync()) return file;
    }
    return null;
  }

  /// Walks up from [start] for the `.dart_tool/package_config.json` that
  /// `dart pub get` wrote, which may live several directories above an example.
  static File? findPackageConfig(Directory start) {
    for (var dir = start.absolute;; dir = dir.parent) {
      final file = File('${dir.path}/.dart_tool/package_config.json');
      if (file.existsSync()) return file;
      if (dir.parent.path == dir.path) return null;
    }
  }

  /// Everything needed for hot reload, or a sentence explaining what is missing.
  static String? unavailableReason() {
    if (!moduleLoader.existsSync()) {
      return 'no ddc_module_loader.js in ${sdkRoot.path}';
    }
    if (findSdkJs() == null) {
      return 'no DDC-compiled dart_sdk.js found — set REACTX_DART_SDK_JS to one';
    }
    return null;
  }

  Future<void> start() async {
    _work.createSync(recursive: true);
    final process = await Process.start(
      '${sdkRoot.path}/bin/dartaotruntime',
      [
        '${sdkRoot.path}/bin/snapshots/frontend_server_aot.dart.snapshot',
        '--sdk-root', sdkRoot.path,
        '--platform', '${sdkRoot.path}/lib/_internal/ddc_platform.dill',
        '--target', 'dartdevc',
        // The library-bundle format. Without --dartdevc-canary the compiler
        // emits the older `dart_library` modules, which only support hot
        // restart.
        '--dartdevc-module-format', 'ddc',
        '--dartdevc-canary',
        '--incremental',
        '--packages', packageConfig.path,
        '--filesystem-root', appDir.absolute.path,
        '--filesystem-scheme', 'org-dartlang-app',
        '--output-dill', '${_work.path}/app.dill',
      ],
    );
    _process = process;
    process.stderr
        .transform(utf8.decoder)
        .listen(_stderr.write, onError: (_) {});
    _lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()));
  }

  /// The first compile: the whole program, to be loaded as the app bundle.
  Future<DdcBundle> compile() async {
    _send(['compile $entryLibrary']);
    await _readResult();
    return _read(File('${_work.path}/app.dill.sources'));
  }

  /// Recompiles after [changed]. The result holds *only* the libraries that
  /// were rebuilt, which is what makes a save cost kilobytes instead of
  /// megabytes.
  Future<DdcBundle> recompile(Iterable<String> changed) async {
    final id = 'r${_generation++}';
    _send([
      'recompile $entryLibrary $id',
      for (final path in changed) _libraryUri(path),
      id,
    ]);
    await _readResult();
    return _read(File('${_work.path}/app.dill.incremental.dill.sources'));
  }

  /// Confirms the last [recompile], so the next one diffs against it. Rejecting
  /// instead would rewind, which is only useful if the client refuses an update.
  void accept() => _send(['accept']);

  static final _defineLibrary =
      RegExp(r'dartDevEmbedder\.defineLibrary\("([^"]+)"');

  /// Reads an emitted `.sources` file, split into one chunk per library using
  /// the sibling `.json` manifest of byte offsets.
  ///
  /// Sliced as bytes, not characters: the offsets the compiler records are byte
  /// offsets, and any non-ASCII character in a string literal would otherwise
  /// shift every chunk after it.
  DdcBundle _read(File file) {
    if (!file.existsSync()) return DdcBundle(const {}, const []);
    final bytes = file.readAsBytesSync();
    final manifest = File(
        '${file.path.substring(0, file.path.length - '.sources'.length)}.json');
    if (!manifest.existsSync()) return DdcBundle(const {}, const []);

    final offsets =
        jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
    final modules = <String, String>{};
    final libraries = <String>[];
    for (final entry in offsets.entries) {
      final code = (entry.value as Map<String, dynamic>)['code'] as List;
      final js = utf8.decode(bytes.sublist(code[0] as int, code[1] as int));
      modules[entry.key] = js;
      libraries.addAll(_defineLibrary.allMatches(js).map((m) => m.group(1)!));
    }
    return DdcBundle(modules, libraries);
  }

  /// Maps an absolute path inside [appDir] to the multi-root URI the compiler
  /// knows it by. Anything outside (a package source) keeps its `file:` URI.
  String _libraryUri(String path) {
    final root = appDir.absolute.path;
    if (!path.startsWith(root)) return Uri.file(path).toString();
    final relative = path.substring(root.length).replaceAll(r'\', '/');
    return 'org-dartlang-app://${relative.startsWith('/') ? '' : '/'}$relative';
  }

  /// Serializes writes to the compiler's stdin.
  ///
  /// Commands are sent from several places (`accept` right before the next
  /// `recompile`, say), and two flushes in flight at once make the sink throw.
  /// Chaining keeps both the ordering and the flushes single-file.
  Future<void> _writes = Future.value();

  void _send(List<String> commands) {
    final process = _process;
    if (process == null) throw StateError('DdcCompiler.start() first');
    _writes = _writes.then((_) {
      for (final command in commands) {
        process.stdin.writeln(command);
      }
      return process.stdin.flush();
    }).catchError((_) {
      // The compiler is gone; _readResult reports that with its diagnostics.
    });
  }

  /// Reads one response, throwing [DdcError] with the compiler's diagnostics if
  /// it reported errors.
  Future<void> _readResult() async {
    final lines = _lines!;
    String? key;
    final diagnostics = <String>[];

    while (await lines.moveNext()) {
      final line = lines.current;
      if (key == null) {
        if (line.startsWith('result ')) key = line.substring(7).trim();
        continue;
      }
      if (line == key) continue; // boundary, not the terminator
      if (line.startsWith('$key ')) {
        final errors = int.tryParse(line.split(' ').last) ?? 0;
        if (errors == 0) return;
        throw DdcError(diagnostics.isEmpty
            ? '$errors compile error(s)'
            : diagnostics.join('\n'));
      }
      // Dependencies are noise; anything else is a diagnostic worth showing.
      if (!line.startsWith('+') && !line.startsWith('-')) {
        diagnostics.add(line);
      }
    }
    throw DdcError(_stderr.isEmpty
        ? 'the Dart compiler exited unexpectedly'
        : _stderr.toString());
  }

  Future<void> stop() async {
    final process = _process;
    if (process == null) return;
    _send(['quit']);
    _process = null;
    try {
      await _writes;
    } catch (_) {
      // Already gone.
    }
    await process.exitCode
        .timeout(const Duration(seconds: 2), onTimeout: () => 0);
    process.kill();
  }
}
