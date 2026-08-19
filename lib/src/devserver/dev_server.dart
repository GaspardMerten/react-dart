/// The `reactx serve` development server: hot **reload** on save.
///
/// It sits in front of your app's own SSR server and turns "save a file" into
/// "see the change, without losing where you were":
///
/// ```
///   browser ──► dev server ──► your server.dart
///                  │  proxies HTML, injects the dev client
///                  └─ watches the directory, transpiles .dartx,
///                     recompiles only what changed, and pushes the
///                     new libraries into the running page over SSE
/// ```
///
/// Reload, not restart, in the Flutter sense: the changed libraries are patched
/// into a program that keeps running, and state survives. That takes a compiler
/// that emits real module boundaries, so this drives DDC through
/// [DdcCompiler] rather than `dart compile js` — a save costs milliseconds and
/// a few kilobytes instead of a full bundle.
///
/// When no DDC-compiled SDK can be found the server falls back to the previous
/// behaviour — `dart compile js` plus a page reload — and says so on startup,
/// because silently degrading to "your state is gone" would be worse than the
/// missing feature.
///
/// Build errors are pushed to the page as an overlay instead of scrolling past
/// in a terminal.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../dartx/transpiler.dart';
import '../routes/generate_io.dart';
import 'client.dart';
import 'ddc_compiler.dart';
import 'vm_service.dart';

/// Watches [appDir], rebuilds it, and serves it with live reload.
class DevServer {
  DevServer({
    required this.appDir,
    this.port = 8080,
    this.entry = 'main.dart',
    this.serverScript = 'server.dart',
    this.optimization = '1',
  });

  /// The app directory: the one holding [entry] and [serverScript].
  final Directory appDir;

  /// The port the browser talks to.
  final int port;

  /// The client entrypoint compiled to `<entry>.js`.
  final String entry;

  /// The SSR server. It must accept `--port`, because the dev server picks the
  /// port it runs on.
  final String serverScript;

  /// `-O` level passed to `dart compile js`. Low by default: dev builds are
  /// about turnaround, not output size.
  final String optimization;

  final List<HttpResponse> _clients = [];
  final HttpClient _http = HttpClient();

  final Map<String, StreamSubscription<FileSystemEvent>> _watchers = {};

  Process? _app;

  /// The current app process's output subscriptions, cancelled before it is
  /// replaced so a long dev session does not accumulate one pair per restart.
  StreamSubscription<String> _appOutput = const Stream<String>.empty().listen(null);
  StreamSubscription<String> _appErrors = const Stream<String>.empty().listen(null);

  /// The running app server's VM service, once it has announced itself.
  VmService? _appService;

  int _appPort = 0;
  Timer? _debounce;
  bool _busy = false;
  bool _again = false;

  /// Null when hot reload is unavailable, in which case the server falls back
  /// to `dart compile js` and a page reload.
  DdcCompiler? _ddc;

  /// The app bundle, held in memory and served from there — writing megabytes
  /// of JS to disk on every save would wake the watcher and cost more than the
  /// compile.
  String _bundleJs = '';

  /// Deltas by generation. Each is served once under its own URL so the browser
  /// cannot serve a stale one from cache.
  final Map<int, String> _deltas = {};
  var _deltaGeneration = 0;

  /// The changed files owed to the next incremental compile.
  final Set<String> _pending = {};

  /// How long the first, full build took — the number a save is measured
  /// against.
  int _initialBuildMs = 0;

  bool get hotReload => _ddc != null;

  String get _bundleName => '$entry.js';

  File get _entryFile => File('${appDir.path}/$entry');

  /// The generated entrypoint: it turns hot reload on, then calls your `main()`.
  /// Dotted so editors and `dart run` leave it alone.
  File get _devEntryFile => File('${appDir.path}/$_devEntryName');

  static const _devEntryName = '.reactx_dev_entry.dart';

  Future<void> start() async {
    if (!_entryFile.existsSync()) {
      throw StateError('reactx serve: no $entry in ${appDir.path}');
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    unawaited(_serve(server));

    stdout.writeln('reactx serve → http://localhost:$port');
    stdout.writeln('watching ${appDir.path}');
    await _startDdc();

    await _rebuild(initial: true);
    _watch();
  }

  /// Brings up the DDC pipeline, or explains why the server is falling back.
  Future<void> _startDdc() async {
    final reason = DdcCompiler.unavailableReason();
    final packageConfig = DdcCompiler.findPackageConfig(appDir);
    if (reason != null || packageConfig == null) {
      stdout.writeln('  hot reload off: '
          '${reason ?? 'no .dart_tool/package_config.json — run dart pub get'}');
      stdout.writeln('  falling back to hot restart (state will not survive)');
      return;
    }

    _writeDevEntry();
    final compiler = DdcCompiler(
      appDir: appDir,
      entry: _devEntryName,
      packageConfig: packageConfig,
      sdkJs: DdcCompiler.findSdkJs()!,
    );
    await compiler.start();
    _ddc = compiler;
    stdout.writeln('  hot reload on (DDC)');
  }

  /// Writes the entrypoint the browser actually runs.
  ///
  /// `reactxHotReload` re-runs the mounted tree against the code that was just
  /// swapped in — it does *not* call your `main()` again, so whatever else your
  /// entrypoint does happens once, at startup, however many times you save.
  /// This library is never itself reloaded, so the hook stays reachable.
  void _writeDevEntry() {
    final code = '''
// GENERATED by `reactx serve`. Delete freely; it is rewritten on startup.
import 'package:reactx/dom.dart' as reactx_dom;
import 'package:reactx/hot_reload.dart' as reactx_dev;
import '$entry' as app;

void main() {
  reactx_dev.enableHotReload();
  app.main();
}

/// Called by the dev client once new libraries are live. Returns the number of
/// mounted roots it re-ran, so the client can restart when there are none.
int reactxHotReload() => reactx_dom.reassembleApps();
''';
    if (!_devEntryFile.existsSync() ||
        _devEntryFile.readAsStringSync() != code) {
      _devEntryFile.writeAsStringSync(code);
    }
  }

  // -- HTTP ------------------------------------------------------------------

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      if (request.uri.path == '/__reactx') {
        _attachClient(request);
        continue;
      }
      if (hotReload && _serveDdcAsset(request)) continue;
      unawaited(_proxy(request));
    }
  }

  /// Holds an event-stream response open and keeps it in [_clients].
  void _attachClient(HttpRequest request) {
    final response = request.response;
    response.headers
      ..contentType = ContentType('text', 'event-stream')
      ..set('cache-control', 'no-cache')
      ..set('connection', 'keep-alive');
    response.bufferOutput = false;
    _clients.add(response);
    response.done.whenComplete(() => _clients.remove(response));
    // Tell the page what kind of server it is talking to before anything else,
    // so the indicator can say "hot reload" or "hot restart" from the start
    // rather than guessing from the first event it happens to see.
    _send(response, 'info', _infoJson);
    _send(response, 'ready', '');
  }

  /// What the dev client shows in its panel about this session.
  String get _infoJson => jsonEncode({
        'hotReload': hotReload,
        'mode': hotReload ? 'hot reload' : 'hot restart',
        'compiler': hotReload ? 'DDC' : 'dart2js',
        'app': appDir.path,
        'entry': entry,
        'initialBuildMs': _initialBuildMs,
      });

  void _send(HttpResponse response, String event, String data) {
    // SSE is line-based, so every line terminator has to be escaped — `\r`
    // included. A compiler diagnostic on Windows arrives as `\r\n`, and a bare
    // CR left in the payload truncates the field, or worse, lets build output
    // forge an `event:` line of its own.
    final payload = data
        .replaceAll('\\', r'\\')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r');
    try {
      response.write('event: $event\ndata: $payload\n\n');
    } catch (_) {
      _clients.remove(response);
    }
  }

  void _broadcast(String event, [String data = '']) {
    for (final client in List.of(_clients)) {
      _send(client, event, data);
    }
  }

  /// Answers the requests that belong to the DDC pipeline, and reports whether
  /// it did — so everything else still reaches the app's own server.
  ///
  /// The app's bundle URL is intercepted rather than rewritten in the HTML:
  /// your `server.dart` goes on emitting one `<script src="main.dart.js">` and
  /// never learns which compiler is behind it.
  bool _serveDdcAsset(HttpRequest request) {
    final path = request.uri.path;
    if (path == '/$_bundleName') {
      _write(request, _bootstrapJs, 'application/javascript');
      return true;
    }
    if (path == '/__reactx/loader.js') {
      _write(request, DdcCompiler.moduleLoader.readAsStringSync(),
          'application/javascript');
      return true;
    }
    if (path == '/__reactx/dart_sdk.js') {
      _write(request, _ddc!.sdkJs.readAsStringSync(), 'application/javascript');
      return true;
    }
    if (path == '/__reactx/app.js') {
      _write(request, _bundleJs, 'application/javascript');
      return true;
    }
    if (path.startsWith('/__reactx/delta-')) {
      final generation =
          int.tryParse(path.substring('/__reactx/delta-'.length).split('.').first);
      _write(request, _deltas[generation] ?? '', 'application/javascript');
      return true;
    }
    return false;
  }

  void _write(HttpRequest request, String body, String mime) {
    final response = request.response
      ..headers.contentType = ContentType.parse('$mime; charset=utf-8')
      ..headers.set('cache-control', 'no-store')
      ..write(body);
    unawaited(response.close().catchError((_) {}));
  }

  /// Loads the module loader, the SDK and the app in order, then starts Dart.
  ///
  /// Deliberately a plain script that injects the others: it stands in for a
  /// dart2js bundle at the same URL, so it cannot assume module support or
  /// change the page's loading semantics.
  String get _bootstrapJs => '''
(function () {
  function load(src) {
    return new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = src;
      s.onload = resolve;
      s.onerror = function () { reject(new Error('failed to load ' + src)); };
      document.head.appendChild(s);
    });
  }
  window.__reactxEntry = ${jsonEncode(_ddc!.entryLibrary)};
  window.__reactxReady = load('/__reactx/loader.js')
    .then(function () { return load('/__reactx/dart_sdk.js'); })
    .then(function () { return load('/__reactx/app.js'); })
    .then(function () { dartDevEmbedder.runMain(window.__reactxEntry, {}); })
    .catch(function (e) {
      console.error('reactx: could not start the app', e);
    });
})();
''';

  /// Forwards a request to the app server, injecting the dev client into HTML.
  Future<void> _proxy(HttpRequest request) async {
    if (_appPort == 0) {
      request.response
        ..statusCode = HttpStatus.serviceUnavailable
        ..headers.contentType = ContentType.html
        ..write('<!doctype html><title>starting…</title>'
            '<body style="font:14px system-ui;padding:2rem">'
            'The app server is starting.$devClient');
      await request.response.close();
      return;
    }

    try {
      final target = Uri.parse('http://127.0.0.1:$_appPort')
          .replace(path: request.uri.path, query: request.uri.query);
      final forward = await _http.openUrl(request.method, target);
      request.headers.forEach((name, values) {
        if (name == 'host' || name == 'accept-encoding') return;
        forward.headers.set(name, values.join(','));
      });
      await forward.addStream(request);
      final upstream = await forward.close();

      final isHtml =
          upstream.headers.contentType?.mimeType == ContentType.html.mimeType;

      request.response.statusCode = upstream.statusCode;
      upstream.headers.forEach((name, values) {
        if (name == 'content-length' || name == 'transfer-encoding') return;
        request.response.headers.set(name, values.join(','));
      });

      if (isHtml) {
        final body = await utf8.decoder.bind(upstream).join();
        request.response.write(_inject(body));
      } else {
        await request.response.addStream(upstream);
      }
      await request.response.close();
    } catch (error) {
      request.response
        ..statusCode = HttpStatus.badGateway
        ..headers.contentType = ContentType.html
        ..write('<!doctype html><title>no app server</title>'
            '<body style="font:14px system-ui;padding:2rem">'
            '<b>The app server is not answering.</b><pre>$error</pre>'
            '$devClient');
      await request.response.close();
    }
  }

  String _inject(String html) => html.contains('</body>')
      ? html.replaceFirst('</body>', '$devClient\n</body>')
      : '$html$devClient';

  // -- Build -----------------------------------------------------------------

  /// Watches every directory in the tree, one flat watcher each.
  ///
  /// Not `watch(recursive: true)`: on Linux that is documented as supported but
  /// delivers nothing on some SDK builds, and a dev server that silently stops
  /// noticing saves is worse than no dev server. A flat watcher per directory
  /// uses the same inotify path that does work, and there are only a handful of
  /// directories in an app.
  void _watch() {
    _armWatchers();
  }

  void _armWatchers() {
    // Directories that went away take their watcher with them; without this the
    // map only ever grows, and a long session in a repo with generated folders
    // keeps a handle on every one that ever existed.
    _watchers.removeWhere((path, subscription) {
      if (Directory(path).existsSync()) return false;
      unawaited(subscription.cancel());
      return true;
    });

    final dirs = <Directory>[
      appDir,
      ...appDir.listSync(recursive: true).whereType<Directory>(),
    ];
    for (final dir in dirs) {
      if (dir.path.contains('.dart_tool')) continue;
      if (_watchers.containsKey(dir.path)) continue;
      _watchers[dir.path] = dir.watch().listen(
        _onFileEvent,
        // Swallowing this is how a dev server silently stops noticing saves —
        // the one failure the watcher exists to prevent. Say so, and drop the
        // dead watcher so the next directory event re-arms it.
        onError: (Object error) {
          stderr.writeln('  watch failed for ${dir.path}: $error');
          unawaited(_watchers.remove(dir.path)?.cancel());
        },
      );
    }
  }

  void _onFileEvent(FileSystemEvent event) {
    // A new folder needs its own watcher before anything inside it can be seen.
    if (event is FileSystemCreateEvent && event.isDirectory) _armWatchers();
    // Both ends of a rename matter, and the destination is usually the only
    // one that counts: an editor that saves atomically — vim, VS Code, `sed
    // -i` — writes a temp file and renames it over yours, so the path that
    // *changed* is junk like `sedA1b2C` while the file you actually edited is
    // the destination. Testing only `event.path` there means never noticing
    // the save at all.
    final touched = <String>[
      if (_isInteresting(event.path)) event.path,
      if (event is FileSystemMoveEvent &&
          event.destination != null &&
          _isInteresting(event.destination!))
        event.destination!,
    ];
    if (touched.isEmpty) return;
    // Remember what to invalidate; a burst of saves recompiles all of them at
    // once.
    _pending.addAll(touched.map((path) => File(path).absolute.path));
    // Editors write in bursts; collapse them into one build.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), _rebuild);
  }

  /// Generated output and build junk must not trigger the build that wrote it.
  bool _isInteresting(String path) {
    if (path.endsWith('.dartx.dart')) return false;
    if (path.endsWith(_devEntryName)) return false;
    if (path.contains('.dart_tool')) return false;
    if (path.endsWith('.js') || path.endsWith('.js.map') ||
        path.endsWith('.js.deps')) {
      return false;
    }
    return path.endsWith('.dart') ||
        path.endsWith('.dartx') ||
        path.endsWith('.html') ||
        path.endsWith('.css');
  }

  Future<void> _rebuild({bool initial = false}) async {
    // Saves arrive in bursts (editor writes, formatters). Never build twice at
    // once; remember that another one is owed and run it after.
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    final started = DateTime.now();
    final changed = Set.of(_pending);
    _pending.clear();

    try {
      _broadcast('building', hotReload && !initial
          ? 'compiling for hot reload'
          : 'compiling for hot restart');
      final dartxError = _transpileAll();
      _generateRoutes();
      if (dartxError != null) {
        _fail('dartx', dartxError);
        return;
      }

      if (hotReload && !initial) {
        await _hotReload(started, changed);
        return;
      }

      _broadcast('building', 'compiling the bundle');
      final compileError = await _compileBundle();
      if (compileError != null) {
        _fail(hotReload ? 'compile' : 'dart compile js', compileError);
        return;
      }

      _broadcast('building', 'refreshing the server');
      await _refreshApp();

      final ms = DateTime.now().difference(started).inMilliseconds;
      stdout.writeln('  rebuilt in ${ms}ms');
      if (initial) {
        _initialBuildMs = ms;
        _broadcast('ready');
      } else {
        _broadcast('reload', jsonEncode({'ms': ms}));
      }
    } finally {
      _busy = false;
      if (_again) {
        _again = false;
        unawaited(_rebuild());
      }
    }
  }

  void _fail(String stage, String message) {
    stderr.writeln('  $stage failed:\n$message');
    _broadcast('error-report', message);
  }

  /// Compiles every `.dartx` under the app directory, in process — much faster
  /// than starting build_runner for a one-file change.
  String? _transpileAll() {
    final problems = StringBuffer();
    for (final entity in appDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dartx')) continue;

      final result = transpileDartx(
        entity.readAsStringSync(),
        uri: entity.uri.toString(),
      );
      if (!result.ok) {
        for (final error in result.errors) {
          problems.writeln('${entity.path}:${error.line}:${error.column}: '
              '${error.message}');
        }
        continue;
      }

      final code = result.code!;
      final out = File('${entity.path}.dart');
      // Writing an identical file would wake the watcher for nothing.
      if (!out.existsSync() || out.readAsStringSync() != code) {
        out.writeAsStringSync(code);
      }
    }
    return problems.isEmpty ? null : problems.toString().trimRight();
  }

  /// Rewrites the generated route table for every `routes/` directory found.
  ///
  /// `build_runner` normally does this, but the dev server deliberately does
  /// not run it — and adding `routes/about/page.dartx` only to get nothing
  /// until you remember to run a build is exactly the papercut file-system
  /// routing exists to remove. Same generator, same output.
  void _generateRoutes() => generateRoutesUnder(appDir);

  /// Recompiles only what changed and pushes it into the live page.
  ///
  /// The app's SSR server is restarted in the background rather than awaited:
  /// nothing on screen is waiting for it — it only matters to the *next* full
  /// page load — and making the user wait a second for it would give back most
  /// of what hot reload just bought.
  Future<void> _hotReload(DateTime started, Set<String> changed) async {
    _broadcast('building', 'compiling for hot reload');
    final DdcBundle delta;
    try {
      delta = await _ddc!.recompile(changed.map(_compiledPath));
      _ddc!.accept();
    } on DdcError catch (error) {
      _fail('compile', error.message);
      return;
    }

    if (delta.isEmpty) {
      _broadcast('ready');
      return;
    }

    // Keep the bundle a page load would get in step with the running page.
    _bundleJs = (_modules..addAll(delta.modules)).values.join('\n');

    final generation = ++_deltaGeneration;
    _deltas[generation] = delta.js;
    _deltas.remove(generation - 3); // a couple of generations is plenty

    unawaited(_refreshApp().catchError((_) {}));

    final ms = DateTime.now().difference(started).inMilliseconds;
    stdout.writeln('  hot reloaded in ${ms}ms '
        '(${delta.libraries.length} librar'
        '${delta.libraries.length == 1 ? 'y' : 'ies'})');
    _broadcast(
      'hot-reload',
      jsonEncode({
        'file': '/__reactx/delta-$generation.js',
        'libraries': delta.libraries,
        'entry': _ddc!.entryLibrary,
        'ms': ms,
        'bytes': delta.js.length,
      }),
    );
  }

  /// Per-library JS for the current program, so a delta can replace a library
  /// rather than redefine it.
  final Map<String, String> _modules = {};

  /// A `.dartx` file is not what the compiler sees — its generated `.dartx.dart`
  /// is, and that is the file that has to be invalidated.
  String _compiledPath(String path) =>
      path.endsWith('.dartx') ? '$path.dart' : path;

  /// Builds the whole program: DDC when hot reload is on, `dart compile js`
  /// otherwise.
  Future<String?> _compileBundle() async {
    final ddc = _ddc;
    if (ddc != null) {
      try {
        final bundle = await ddc.compile();
        ddc.accept();
        _modules
          ..clear()
          ..addAll(bundle.modules);
        _bundleJs = bundle.js;
        return null;
      } on DdcError catch (error) {
        return error.message;
      }
    }

    final result = await Process.run('dart', [
      'compile',
      'js',
      '-O$optimization',
      _entryFile.path,
      '-o',
      '${appDir.path}/$_bundleName',
    ]);
    if (result.exitCode == 0) return null;
    final out = '${result.stdout}\n${result.stderr}'.trim();
    return out.isEmpty ? 'dart compile js exited ${result.exitCode}' : out;
  }

  // -- The app server --------------------------------------------------------

  /// Reloads the SSR server in place, and says whether that worked.
  ///
  /// The VM updates function bodies without restarting the isolate, so the
  /// `HttpServer` keeps its socket and the handler registered at startup simply
  /// starts running the new code. When the VM declines — a changed class
  /// hierarchy, say — the caller falls back to a restart, which is always
  /// correct, just slower.
  /// Brings the SSR server up to date: in place when the VM allows it, by
  /// restarting the process when it does not.
  ///
  /// Chained rather than concurrent. Two saves close together used to start two
  /// restarts, each of which killed whatever `_app` held and then overwrote it
  /// — leaving one process alive, holding its port, owned by nobody and
  /// surviving shutdown.
  Future<void> _refreshApp() {
    return _refreshing = _refreshing.then((_) async {
      if (await _reloadApp()) return;
      await _restartApp();
    }).catchError((Object error) {
      stderr.writeln('  server refresh failed: $error');
    });
  }

  /// The tail of the refresh chain. Never completes with an error, so one
  /// failure does not poison every later save.
  Future<void> _refreshing = Future.value();

  Future<bool> _reloadApp() async {
    final service = _appService;
    if (service == null || _app == null) return false;
    final started = DateTime.now();
    final result = await service.reload();
    final ms = DateTime.now().difference(started).inMilliseconds;
    if (!result.success) {
      stdout.writeln('  server reload declined (${result.message}) — restarting');
      return false;
    }
    stdout.writeln('  server reloaded in place in ${ms}ms');
    return true;
  }

  Future<void> _restartApp() async {
    await _appService?.close();
    _appService = null;

    final previous = _app;
    _app = null;
    if (previous != null) {
      // Cancel first: a killed process still delivers what it had buffered, and
      // those subscriptions would otherwise accumulate one pair per restart.
      await _appOutput.cancel();
      await _appErrors.cancel();
      previous.kill();
      // Wait for it to actually go, so the new one cannot race it for a port.
      await previous.exitCode;
    }

    _appPort = await _freePort();
    final servicePort = await _freePort();
    final process = await Process.start('dart', [
      'run',
      // Opens the door for `reloadSources`. Auth codes off keeps the URI
      // predictable; it is bound to the loopback interface either way.
      '--enable-vm-service=$servicePort',
      '--disable-service-auth-codes',
      '${appDir.path}/$serverScript',
      '--port',
      '$_appPort',
    ]);
    _app = process;

    // The app's own logs belong in the same terminal, indented so it is obvious
    // which process they came from — except the VM's service banner, which is
    // noise to the developer but is how this server finds the reload endpoint.
    _appOutput = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final service = VmService.parseAnnouncement(line);
      if (service != null) {
        _appService = VmService(service);
        return;
      }
      stdout.writeln('  │ $line');
    });
    _appErrors = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stderr.writeln('  │ $line'));

    await _waitForPort(_appPort);
  }

  Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Future<void> _waitForPort(int port) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(milliseconds: 200),
        );
        socket.destroy();
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    }
    throw StateError('reactx serve: $serverScript never listened on $port');
  }

  /// Stops the child process and closes every open event stream.
  Future<void> stop() async {
    _debounce?.cancel();
    for (final watcher in _watchers.values) {
      await watcher.cancel();
    }
    _watchers.clear();
    await _appOutput.cancel();
    await _appErrors.cancel();
    _app?.kill();
    _app = null;
    await _appService?.close();
    _appService = null;
    await _ddc?.stop();
    _ddc = null;
    // Leaving a generated entrypoint behind in someone's source tree would be
    // rude, and it is meaningless without the server that wrote it.
    if (_devEntryFile.existsSync()) _devEntryFile.deleteSync();
    for (final client in List.of(_clients)) {
      await client.close();
    }
    _http.close(force: true);
  }
}
