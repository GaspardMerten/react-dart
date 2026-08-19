/// A language server for `.dartx`, built as a proxy in front of Dart's own.
///
/// The Dart analysis server already knows everything worth knowing about a
/// reactx component — its parameters, their types, where it is declared, what
/// its generated props type is. What it does not know is `.dartx`. So rather
/// than reimplementing any of that, this sits between the editor and
/// `dart language-server` and translates:
///
/// ```
///   editor  ──  foo.dartx, line 12 col 20  ──▶  dartx lsp
///                                                  │  transpile + map
///                                                  ▼
///   dart language-server  ◀──  foo.dartx.dart, line 12 col 34
///                                                  │
///   editor  ◀──  a definition back in foo.dartx  ──┘
/// ```
///
/// The editor never learns that a generated file exists: requests go in against
/// the `.dartx`, and locations come back pointing at it. That is the whole
/// trick, and it is only possible because the transpiler preserves line
/// numbers — see [PositionMap] for what that buys and what it costs.
///
/// What is proxied today: document sync, go-to-definition, hover, and the
/// analyser's own diagnostics mapped back onto the `.dartx`. Everything else is
/// forwarded untranslated, which is right for requests that carry no position
/// and wrong for ones that do — those are simply not claimed yet.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../dartx/transpiler.dart';
import 'jsonrpc.dart';
import 'position_map.dart';

/// One open `.dartx` file: what the editor has, what the analyser was given,
/// and how to get between them.
final class _Document {
  _Document(this.source, this.generated, this.map);

  String source;
  String generated;
  PositionMap map;

  /// Bumped on every change, because the analysis server tracks versions and
  /// will ignore an edit that appears to go backwards.
  int version = 1;
}

/// Where the cursor is, when it is inside a tag rather than inside Dart.
final class _TagContext {
  const _TagContext({required this.name, required this.completingName});

  /// The tag being written, as far as it has been typed.
  final String name;

  /// Whether the cursor is still in the name itself (`<Sta`) rather than past
  /// it in the attribute list (`<StatCard `).
  final bool completingName;
}

/// `Component Name(` — a component's declaration, wherever it appears.
final _componentDeclaration = RegExp(r'\bComponent\s+([A-Za-z_$][\w$]*)\s*[(<]');

/// A question asked about a `.dartx`, kept until its answer comes back.
final class _Asked {
  const _Asked({required this.method, required this.uri, required this.spot});
  final String method;
  final String uri;
  final Spot spot;
}

/// Requests whose params carry a `textDocument/position` pair the analyser
/// answers in terms of the generated file, and whose results carry locations
/// that have to come back.
const _positionRequests = {
  'textDocument/definition',
  'textDocument/typeDefinition',
  'textDocument/implementation',
  'textDocument/hover',
  'textDocument/references',
  'textDocument/documentHighlight',
  'textDocument/prepareCallHierarchy',
  'textDocument/completion',
  'textDocument/signatureHelp',
};

class DartxLanguageServer {
  DartxLanguageServer({
    required this.input,
    required this.output,
    this.dartPath = 'dart',
    this.logSink,
  });

  final Stream<List<int>> input;
  final IOSink output;
  final String dartPath;
  final IOSink? logSink;

  /// Files the editor has open, kept in step with every keystroke.
  final Map<String, _Document> _documents = {};

  /// Files only referred to — a definition's destination, say. Transpiled once
  /// and kept, and dropped whenever the editor tells us one changed.
  final Map<String, _Document> _onDisk = {};
  Process? _analyser;
  final _analyserReady = Completer<void>();

  /// The id of the editor's `initialize`, so its answer can be corrected on the
  /// way back.
  Object? _initializeId;

  /// Changes not yet handed to the analyser, by URI. Typing produces one of
  /// these per keystroke, and each one costs a full re-analysis of the library
  /// — the generated Dart is produced by compiling the whole buffer, so there
  /// is no cheaper edit to send. Batching them is the difference between one
  /// re-analysis per pause and one per character.
  final Map<String, Timer> _pendingSync = {};
  final Map<String, Map<String, Object?>> _queuedSync = {};

  /// How long to wait for typing to stop.
  static const _syncDelay = Duration(milliseconds: 300);

  /// Requests translated on the way out, by id, so their answers can be
  /// translated on the way back. A hover's range has no URI beside it to say
  /// which file it belongs to — the question it answers is the only record.
  final Map<Object, _Asked> _inFlight = {};

  /// Questions this server asked the analyser on its own behalf.
  final Map<String, Completer<Map<String, Object?>>> _internal = {};
  int _nextInternalId = 0;

  void _log(String message) => logSink?.writeln('[dartx-lsp] $message');

  Future<void> start() async {
    await _startAnalyser();
    await for (final message in readMessages(input)) {
      try {
        _fromEditor(message);
      } catch (error, stack) {
        _log('handling ${message['method']} failed: $error\n$stack');
      }
    }
    _analyser?.kill();
  }

  Future<void> _startAnalyser() async {
    final process = await Process.start(
      dartPath,
      ['language-server', '--client-id=reactx.dartx'],
    );
    _analyser = process;
    _analyserReady.complete();

    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _log('analyser: $line'));

    unawaited(readMessages(process.stdout).forEach(_fromAnalyser));
  }

  // -- editor -> analyser ----------------------------------------------------

  void _fromEditor(Map<String, Object?> message) {
    final method = message['method'] as String?;
    if (method != null) {
      final uri = ((message['params'] as Map?)?['textDocument']
          as Map?)?['uri'] as String?;
      _log('<- editor $method${message['id'] == null ? '' : ' #${message['id']}'}'
          '${uri == null ? '' : ' ${uri.split('/').last}'}');
    }

    if (method == 'initialize') _initializeId = message['id'];

    switch (method) {
      case 'textDocument/didOpen':
      case 'textDocument/didChange':
      case 'textDocument/didClose':
        _syncDocument(method!, message);
        return;
    }

    if (method == 'textDocument/completion') {
      unawaited(_complete(message));
      return;
    }
    if (method == 'textDocument/codeLens') {
      _lensesFor(message);
      return;
    }
    if (method == 'codeLens/resolve') {
      unawaited(_resolveLens(message));
      return;
    }

    if (method != null && _positionRequests.contains(method)) {
      final id = message['id'];
      final uri = ((message['params'] as Map?)?['textDocument']
          as Map?)?['uri'] as String?;
      final position = (message['params'] as Map?)?['position'] as Map?;
      if (id != null && uri != null && uri.endsWith('.dartx')) {
        _inFlight[id] = _Asked(
          method: method,
          uri: uri,
          spot: Spot(position?['line'] as int? ?? 0,
              position?['character'] as int? ?? 0),
        );
      }
      // A question has to be answered about what is on screen now, so anything
      // still waiting goes first.
      if (uri != null) _flushSync(uri);
      final translated = _translateRequest(message);
      // A position that does not survive compilation has no answer; say so
      // rather than sending the analyser a question about the wrong place.
      if (translated == null) {
        _inFlight.remove(message['id']);
        _toEditor({'jsonrpc': '2.0', 'id': message['id'], 'result': null});
        return;
      }
      _toAnalyser(translated);
      return;
    }

    _toAnalyser(message);
  }

  /// Keeps the analyser's copy of the *generated* file in step with the
  /// editor's copy of the `.dartx`.
  void _syncDocument(String method, Map<String, Object?> message) {
    final params = message['params'] as Map<String, Object?>? ?? const {};
    final doc = params['textDocument'] as Map<String, Object?>? ?? const {};
    final uri = doc['uri'] as String?;
    if (uri == null) return;

    if (!uri.endsWith('.dartx')) {
      _toAnalyser(message); // an ordinary .dart file: nothing to translate
      return;
    }

    if (method == 'textDocument/didClose') {
      _documents.remove(uri);
      _pendingSync.remove(uri)?.cancel();
      _queuedSync.remove(uri);
      _toAnalyser({
        'jsonrpc': '2.0',
        'method': 'textDocument/didClose',
        'params': {
          'textDocument': {'uri': _generatedUri(uri)}
        },
      });
      return;
    }

    final source = method == 'textDocument/didOpen'
        ? doc['text'] as String? ?? ''
        : _fullText(params);
    if (source.isEmpty && method == 'textDocument/didChange') return;

    _onDisk.remove(uri); // the editor's copy wins from here on
    final existing = _documents[uri];
    final compiled = transpileDartx(source, uri: uri);
    // A file that does not compile keeps its last good generated text, so the
    // analyser answers about the last version that made sense instead of
    // going silent mid-keystroke. The dartx diagnostics still report the error.
    final generated = compiled.ok ? compiled.code! : existing?.generated ?? '';

    final document = existing ?? _Document(source, generated, PositionMap(source: source, generated: generated));
    document.source = source;
    document.generated = generated;
    document.map = PositionMap(source: source, generated: generated);
    if (existing != null) document.version++;
    _documents[uri] = document;

    _queueForAnalyser(uri, {
      'jsonrpc': '2.0',
      'method': existing == null
          ? 'textDocument/didOpen'
          : 'textDocument/didChange',
      'params': existing == null
          ? {
              'textDocument': {
                'uri': _generatedUri(uri),
                'languageId': 'dart',
                'version': document.version,
                'text': generated,
              }
            }
          : {
              'textDocument': {
                'uri': _generatedUri(uri),
                'version': document.version,
              },
              'contentChanges': [
                {'text': generated}
              ],
            },
    });

    // The transpiler's own errors are local and instant, so they are published
    // straight away rather than waiting for the analyser.
    _publishDartxDiagnostics(uri, compiled);
  }

  /// Holds [message] until typing stops, replacing any earlier one for [uri].
  ///
  /// An opening is sent immediately: nothing can be asked about a document the
  /// analyser has not been told exists.
  void _queueForAnalyser(String uri, Map<String, Object?> message) {
    if (message['method'] == 'textDocument/didOpen') {
      _toAnalyser(message);
      return;
    }
    _queuedSync[uri] = message;
    _pendingSync[uri]?.cancel();
    _pendingSync[uri] = Timer(_syncDelay, () => _flushSync(uri));
  }

  /// Hands the analyser whatever is waiting for [uri].
  void _flushSync(String uri) {
    _pendingSync.remove(uri)?.cancel();
    final queued = _queuedSync.remove(uri);
    if (queued != null) _toAnalyser(queued);
  }

  /// The transpiler's own errors, which the analyser can never produce because
  /// it never sees the markup.
  void _publishDartxDiagnostics(String uri, DartxResult result) {
    _toEditor({
      'jsonrpc': '2.0',
      'method': 'textDocument/publishDiagnostics',
      'params': {
        'uri': uri,
        'diagnostics': [
          for (final error in result.errors)
            {
              'range': _pointRange(error.line - 1, error.column - 1),
              'severity': 1,
              'source': 'dartx',
              'message': error.message,
            }
        ],
      },
    });
  }

  Map<String, Object?>? _translateRequest(Map<String, Object?> message) {
    final params = Map<String, Object?>.from(
        message['params'] as Map<String, Object?>? ?? const {});
    final doc = params['textDocument'] as Map<String, Object?>?;
    final uri = doc?['uri'] as String?;
    if (uri == null || !uri.endsWith('.dartx')) return message;

    final document = _documents[uri];
    final position = params['position'] as Map<String, Object?>?;
    if (document == null || position == null) return message;

    final spot =
        Spot(position['line'] as int? ?? 0, position['character'] as int? ?? 0);

    final at = _retarget(message['method'] as String?, document, spot) ??
        document.map.toGenerated(spot);
    if (at == null) return null;

    params['textDocument'] = {'uri': _generatedUri(uri)};
    params['position'] = {'line': at.line, 'character': at.column};
    return {...message, 'params': params};
  }

  /// Where a question about a component should really be asked.
  ///
  /// "Find all references to `StatCard`" means, to the person asking, "where is
  /// `<StatCard>` used". But the markup does not compile to a call to
  /// `StatCard` — it compiles to `StatCardProps(…)`, and the only thing that
  /// *does* call the function is the one line of generated machinery inside
  /// `StatCardProps.build()`. Asking the analyser the literal question returns
  /// exactly that one line and none of the call sites, which is the opposite of
  /// what was wanted.
  ///
  /// So a references request standing on a component's name is asked about its
  /// props type instead. Definition and hover are left alone: there the literal
  /// question is the right one.
  Spot? _retarget(String? method, _Document document, Spot spot) {
    if (method != 'textDocument/references') return null;

    final name = document.map.sourceIdentifierAt(spot);
    if (name == null || name.isEmpty) return null;

    // Only for a name this file actually declares as a component; a `<Foo>`
    // written here resolves through its own file's declaration anyway.
    if (!RegExp('\\bComponent\\s+$name\\s*[(<]').hasMatch(document.source)) {
      return null;
    }
    return _classDeclaration(document.generated, '${name}Props');
  }

  /// The position of `class <name>` in [generated], or null.
  static Spot? _classDeclaration(String generated, String name) {
    final pattern = RegExp('\\bclass\\s+$name\\b');
    final lines = generated.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final match = pattern.firstMatch(lines[i]);
      if (match == null) continue;
      return Spot(i, lines[i].indexOf(name, match.start));
    }
    return null;
  }

  // -- analyser -> editor ----------------------------------------------------

  void _fromAnalyser(Map<String, Object?> message) {
    final internal = _internal.remove(message['id']);
    if (internal != null) {
      internal.complete(message);
      return;
    }
    if (_initializeId != null && message['id'] == _initializeId) {
      _initializeId = null;
      _toEditor(_claimDartx(message));
      return;
    }
    if (message['method'] == 'client/registerCapability') {
      _toEditor(_widenRegistrations(message));
      return;
    }
    if (message['method'] == 'textDocument/publishDiagnostics') {
      _toEditor(_translateDiagnostics(message));
      return;
    }

    // A response to something translated on the way out carries ranges in
    // generated coordinates, and a hover's range has no URI beside it to give
    // that away. The request it answers is what identifies the file.
    final asked = _inFlight.remove(message['id']);
    final document = asked == null ? null : _documents[asked.uri];

    var answer = _mapLocationsBack(message);
    if (document != null) answer = _mapBareRanges(document, answer);
    answer = _dedupeLocations(answer);

    // Going to the definition of a definition has nowhere to go. Saying so —
    // rather than answering with the line the cursor is already on — is what
    // lets the editor fall back to its alternative, which by default is
    // "show me where this is used". That is the whole interaction behind
    // Ctrl-clicking a component's name.
    if (asked != null && asked.method == 'textDocument/definition') {
      answer = _nullIfSelf(asked, answer);
    }

    if (asked != null) {
      final result = (answer as Map<String, Object?>)['result'];
      final size = result is List ? '${result.length} item(s)' : '$result';
      _log('-> editor #${message['id']} for ${asked.uri.split('/').last}: '
          '${size.length > 120 ? '${size.substring(0, 120)}…' : size}');
    }
    _toEditor(answer);
  }

  /// Collapses locations that became identical on the way back.
  ///
  /// Several references in the generated file — the props class and its
  /// constructor, say — map onto the one line of `.dartx` that produced them.
  /// Reporting that line three times would be counting machinery, not uses.
  Object? _dedupeLocations(Object? message) {
    if (message is! Map<String, Object?>) return message;
    final result = message['result'];
    if (result is! List || result.isEmpty) return message;

    final seen = <String>{};
    final unique = <Object?>[];
    for (final entry in result) {
      if (entry is! Map || (entry['uri'] == null && entry['targetUri'] == null)) {
        return message; // not a location list; leave it alone
      }
      if (seen.add(jsonEncode(entry))) unique.add(entry);
    }
    return {...message, 'result': unique};
  }

  /// Replaces the analyser's advertised capabilities with the ones this proxy
  /// can honestly stand behind.
  ///
  /// Forwarding them wholesale is wrong twice over.
  ///
  /// It **breaks the editor outright**. The analysis server advertises
  /// `executeCommandProvider` with ids like `dart.edit.codeAction.apply`, and
  /// the Dart extension has already registered those with VS Code. Registering
  /// them a second time throws, initialization fails, and the language client
  /// reports "couldn't create connection to server" — which reads like a
  /// startup problem and is really a name collision.
  ///
  /// It also **promises things that would be wrong if they worked**. A code
  /// action or a rename comes back as a `WorkspaceEdit`, whose file paths are
  /// keys rather than values, so nothing here rewrites them: accepting the fix
  /// would edit the generated file, and the next build would throw the edit
  /// away. Formatting would reformat compiled markup back into the source.
  /// Document symbols and folding ranges arrive in generated coordinates with
  /// no URI beside them to notice.
  ///
  /// So the list below is exactly what [_positionRequests] translates, and
  /// everything else is dropped until it is genuinely handled. A missing
  /// feature is a gap; a feature that silently edits the wrong file is a bug.
  Map<String, Object?> _claimDartx(Map<String, Object?> message) {
    final result = message['result'];
    if (result is! Map<String, Object?>) return message;

    return {
      ...message,
      'result': {
        ...result,
        'capabilities': <String, Object?>{
          // Full-document sync, deliberately. The generated Dart is produced by
          // compiling the whole buffer, so a ranged edit has nothing to be
          // applied to — and `_fullText` would read the typed fragment as the
          // entire file.
          'textDocumentSync': {'openClose': true, 'change': 1},
          'definitionProvider': true,
          'typeDefinitionProvider': true,
          'implementationProvider': true,
          'referencesProvider': true,
          'hoverProvider': true,
          'documentHighlightProvider': true,
          // Answered here rather than forwarded: the analyser's lenses are
          // about the generated Dart, and the useful one for a component is a
          // count of the markup that uses it.
          'codeLensProvider': const {'resolveProvider': true},
          'completionProvider': const {
            // Enough to be useful inside an element. An unclosed tag has
            // nothing to compile, so completion there stays empty.
            'triggerCharacters': ['.', '=', '(', r'$'],
          },
        },
      },
    };
  }

  /// Extends a dynamic registration to cover `.dartx`, for the methods this
  /// proxy translates — and drops the rest.
  ///
  /// The analyser registers `textDocument/definition` and friends *after*
  /// initialization, scoped to `language: dart`. A `.dartx` file is not that
  /// language, so without this the editor never asks and Ctrl-click does
  /// nothing at all. Registrations for methods not in [_positionRequests] are
  /// dropped for the same reason they are not advertised: answering them would
  /// mean acting on the wrong file.
  Map<String, Object?> _widenRegistrations(Map<String, Object?> message) {
    final params = message['params'];
    if (params is! Map<String, Object?>) return message;

    final registrations = params['registrations'];
    if (registrations is! List) return message;

    final widened = <Object?>[];
    for (final raw in registrations) {
      if (raw is! Map) {
        widened.add(raw);
        continue;
      }
      if (!_positionRequests.contains(raw['method'])) continue;
      final registration = Map<String, Object?>.from(raw);
      final options = registration['registerOptions'];
      if (options is Map<String, Object?>) {
        final selectors = options['documentSelector'];
        if (selectors is List &&
            selectors.any((s) => s is Map && s['language'] == 'dart')) {
          registration['registerOptions'] = {
            ...options,
            'documentSelector': [
              ...selectors,
              {'language': 'dartx', 'scheme': 'file'},
            ],
          };
        }
      }
      widened.add(registration);
    }

    return {
      ...message,
      'params': {...params, 'registrations': widened},
    };
  }

  /// Diagnostics the analyser raised against a generated file, moved onto the
  /// `.dartx` the person is looking at.
  Map<String, Object?> _translateDiagnostics(Map<String, Object?> message) {
    final params = Map<String, Object?>.from(
        message['params'] as Map<String, Object?>? ?? const {});
    final uri = params['uri'] as String?;
    if (uri == null || !uri.endsWith('.dartx.dart')) return message;

    final sourceUri = _sourceUri(uri);
    final document = _documentFor(sourceUri);
    if (document == null) return message;

    final sourceLines = document.source.split('\n').length;
    final translated = <Object?>[];
    for (final raw in params['diagnostics'] as List? ?? const []) {
      final diagnostic = Map<String, Object?>.from(raw as Map);
      final range = _mapRangeBack(document, diagnostic['range']);
      // Past the end of the `.dartx` is the generated props types, which have
      // no line to point at. Dropping beats pointing somewhere arbitrary.
      if (range == null) continue;
      if ((range['start'] as Map)['line'] as int >= sourceLines) continue;
      diagnostic['range'] = range;
      translated.add(diagnostic);
    }

    params['uri'] = sourceUri;
    params['diagnostics'] = translated;
    return {...message, 'params': params};
  }

  /// Rewrites every `{uri, range}` pair anywhere in [node] that points into a
  /// generated file, so the editor opens the `.dartx` instead.
  Object? _mapLocationsBack(Object? node) {
    if (node is List) return [for (final item in node) _mapLocationsBack(item)];
    if (node is! Map) return node;

    final result = <String, Object?>{};
    node.forEach((key, value) {
      result[key as String] = _mapLocationsBack(value);
    });

    for (final key in const ['uri', 'targetUri']) {
      final uri = result[key];
      if (uri is! String || !uri.endsWith('.dartx.dart')) continue;
      final sourceUri = _sourceUri(uri);
      final document = _documentFor(sourceUri);
      if (document == null) continue;

      // Map the ranges first: if none of them can be brought back, the
      // location is somewhere the `.dartx` does not have — leave it pointing
      // at the generated file rather than at a line that does not exist.
      final mapped = <String, Map<String, Object?>>{};
      for (final rangeKey in const [
        'range',
        'targetRange',
        'targetSelectionRange',
      ]) {
        final range = _mapRangeBack(document, result[rangeKey]);
        if (range != null) mapped[rangeKey] = range;
      }
      if (mapped.isEmpty) continue;

      // A `targetRange` is the whole declaration — usually the generated class,
      // which has no counterpart in the source. Leaving it behind while
      // rewriting the URI hands the editor a range outside the file it now
      // names, and a link an editor cannot validate is a link it will not
      // follow. The selection range is a real position in the real file.
      if (result.containsKey('targetRange') && !mapped.containsKey('targetRange')) {
        final fallback = mapped['targetSelectionRange'];
        if (fallback == null) continue;
        mapped['targetRange'] = fallback;
      }

      result[key] = sourceUri;
      mapped.forEach((rangeKey, range) => result[rangeKey] = range);
    }
    return result;
  }

  /// The document for [sourceUri], loading it from disk when the editor has
  /// not opened it.
  ///
  /// Go-to-definition mostly *leaves* the file you are in, so the interesting
  /// destination is usually one the editor has never mentioned. Without this
  /// the answer would come back pointing at generated Dart, which is exactly
  /// the file this server exists to keep out of sight.
  _Document? _documentFor(String sourceUri) {
    final open = _documents[sourceUri];
    if (open != null) return open;

    final cached = _onDisk[sourceUri];
    if (cached != null) return cached;

    final String source;
    try {
      source = File(Uri.parse(sourceUri).toFilePath()).readAsStringSync();
    } catch (_) {
      return null; // not a file we can read; leave the location alone
    }

    final compiled = transpileDartx(source, uri: sourceUri);
    if (!compiled.ok) return null;

    final document = _Document(source, compiled.code!,
        PositionMap(source: source, generated: compiled.code!));
    _onDisk[sourceUri] = document;
    return document;
  }

  /// Replaces an answer that only points back at the question.
  Object? _nullIfSelf(_Asked asked, Object? answer) {
    if (answer is! Map<String, Object?>) return answer;
    final result = answer['result'];
    if (result is! List || result.isEmpty) return answer;

    for (final entry in result) {
      if (entry is! Map) return answer;
      if (entry['uri'] != asked.uri && entry['targetUri'] != asked.uri) {
        return answer; // somewhere else: a real destination
      }
      final range = (entry['targetSelectionRange'] ?? entry['range']) as Map?;
      final start = range?['start'] as Map?;
      final end = range?['end'] as Map?;
      if (start == null || end == null) return answer;
      if (start['line'] != asked.spot.line) return answer;
      // The cursor has to be inside the range it was handed back.
      final from = start['character'] as int? ?? 0;
      final to = end['character'] as int? ?? 0;
      if (asked.spot.column < from || asked.spot.column > to) return answer;
    }

    return {...answer, 'result': null};
  }

  /// Maps `range` entries that are not part of a location.
  ///
  /// A [Location] says which file it is in, so [_mapLocationsBack] can find the
  /// right document. A hover result is just `{contents, range}` — the range
  /// belongs to the file the question was asked about, and nothing in the
  /// message says so.
  Object? _mapBareRanges(_Document document, Object? node) {
    if (node is List) {
      return [for (final item in node) _mapBareRanges(document, item)];
    }
    if (node is! Map) return node;

    final result = <String, Object?>{};
    node.forEach((key, value) {
      result[key as String] = _mapBareRanges(document, value);
    });

    // `originSelectionRange` is the odd one out: it belongs to the document the
    // question was asked about, not to the one the answer points at. It is what
    // the editor makes clickable, so leaving it in generated coordinates puts
    // the link somewhere other than the word under the cursor.
    final origin = _mapRangeBack(document, result['originSelectionRange']);
    if (origin != null) result['originSelectionRange'] = origin;

    // Everything else beside a URI was already mapped against the file that URI
    // names; mapping it again here would be mapping it twice.
    if (result['uri'] != null || result['targetUri'] != null) return result;

    for (final key in const ['range', 'selectionRange']) {
      final mapped = _mapRangeBack(document, result[key]);
      if (mapped != null) result[key] = mapped;
    }
    return result;
  }

  Map<String, Object?>? _mapRangeBack(_Document document, Object? range) {
    if (range is! Map) return null;
    final start = _mapSpotBack(document, range['start']);
    if (start == null) return _declarationBehind(document, range);

    // An answer about `StatCardProps` is thirteen characters wide; the
    // `StatCard` it lands on is eight. Sizing the range from the identifier
    // actually under it is what stops the editor highlighting into whatever
    // follows the tag name.
    final startSpot = Spot(start['line'] as int, start['character'] as int);
    final identifier = document.map.sourceIdentifierAt(startSpot);
    if (identifier != null) {
      return {
        'start': start,
        'end': {
          'line': startSpot.line,
          'character': startSpot.column + identifier.length,
        },
      };
    }

    final end = _mapSpotBack(document, range['end']);
    return {'start': start, 'end': end ?? start};
  }

  /// The component declaration behind a generated props type.
  ///
  /// Going to the definition of `<StatCard />` lands the analyser on
  /// `StatCardProps`, which lives past the end of the `.dartx` — it is appended
  /// after the source, so there is no line to come back to. But the thing a
  /// person meant by that click is `StatCard` itself, which *is* in the file.
  Map<String, Object?>? _declarationBehind(_Document document, Map range) {
    final start = range['start'];
    if (start is! Map) return null;
    final line = start['line'] as int? ?? 0;
    final column = start['character'] as int? ?? 0;

    final generatedLines = document.generated.split('\n');
    if (line < 0 || line >= generatedLines.length) return null;

    final name = _identifierAt(generatedLines[line], column);
    if (name == null || !name.endsWith('Props')) return null;
    final component = name.substring(0, name.length - 'Props'.length);
    if (component.isEmpty) return null;

    final sourceLines = document.source.split('\n');
    final declaration = RegExp('\\bComponent\\s+$component\\s*[(<]');
    for (var i = 0; i < sourceLines.length; i++) {
      final match = declaration.firstMatch(sourceLines[i]);
      if (match == null) continue;
      final at = sourceLines[i].indexOf(component, match.start);
      return {
        'start': {'line': i, 'character': at},
        'end': {'line': i, 'character': at + component.length},
      };
    }
    return null;
  }

  static String? _identifierAt(String line, int column) {
    if (column < 0 || column >= line.length) return null;
    bool word(int c) =>
        (c >= 0x41 && c <= 0x5a) ||
        (c >= 0x61 && c <= 0x7a) ||
        (c >= 0x30 && c <= 0x39) ||
        c == 0x5f ||
        c == 0x24;
    if (!word(line.codeUnitAt(column))) return null;
    var start = column;
    while (start > 0 && word(line.codeUnitAt(start - 1))) {
      start--;
    }
    var end = column;
    while (end + 1 < line.length && word(line.codeUnitAt(end + 1))) {
      end++;
    }
    return line.substring(start, end + 1);
  }

  Map<String, Object?>? _mapSpotBack(_Document document, Object? spot) {
    if (spot is! Map) return null;
    final at = document.map.toSource(
        Spot(spot['line'] as int? ?? 0, spot['character'] as int? ?? 0));
    return at == null ? null : {'line': at.line, 'character': at.column};
  }

  // -- plumbing --------------------------------------------------------------

  void _toEditor(Object? message) {
    if (message is! Map<String, Object?>) return;
    output.add(frame(message));
  }

  // -- Completion -----------------------------------------------------------

  /// Answers a completion request, repairing the markup first when the cursor
  /// is somewhere that does not compile.
  ///
  /// Inside `{…}` the file is ordinary Dart and the analyser needs no help.
  /// Inside a tag it is not: `<StatCard ` is not valid markup until it is
  /// closed, so there is nothing to compile and nothing to ask about — which is
  /// exactly the moment someone wants to be told what the attributes are.
  ///
  /// So for that one case the buffer is repaired for the length of a single
  /// question: `/>` is inserted at the cursor, the result is compiled, and the
  /// analyser is asked about the argument list of the props type. The document
  /// the editor holds is untouched.
  Future<void> _complete(Map<String, Object?> message) async {
    final params = message['params'] as Map<String, Object?>? ?? const {};
    final uri = (params['textDocument'] as Map?)?['uri'] as String?;
    final position = params['position'] as Map?;
    final document = uri == null ? null : _documents[uri];

    if (document == null || position == null) {
      _toEditor(_translateRequest(message) == null
          ? {'jsonrpc': '2.0', 'id': message['id'], 'result': null}
          : message);
      return;
    }

    final spot = Spot(position['line'] as int? ?? 0,
        position['character'] as int? ?? 0);
    final tag = _tagAround(document.source, spot);

    if (tag == null) {
      // Ordinary Dart, or text: the usual translation is right.
      final translated = _translateRequest(message);
      if (translated == null) {
        _toEditor({'jsonrpc': '2.0', 'id': message['id'], 'result': null});
        return;
      }
      _inFlight[message['id']!] = _Asked(
          method: 'textDocument/completion', uri: uri!, spot: spot);
      _toAnalyser(translated);
      return;
    }

    final repaired = _repair(document.source, spot);
    final compiled = transpileDartx(repaired, uri: uri);
    if (!compiled.ok) {
      _toEditor({'jsonrpc': '2.0', 'id': message['id'], 'result': null});
      return;
    }

    // The repaired document has to be what the analyser is looking at, and
    // then put back — a question must not leave the editor's copy behind.
    _toAnalyser({
      'jsonrpc': '2.0',
      'method': 'textDocument/didChange',
      'params': {
        'textDocument': {'uri': _generatedUri(uri!), 'version': ++document.version},
        'contentChanges': [
          {'text': compiled.code}
        ],
      },
    });

    final at = tag.completingName
        ? _componentNameSpot(compiled.code!, spot, tag.name)
        : _argumentListSpot(compiled.code!, spot, tag.name);

    Map<String, Object?> answer = const {'result': null};
    if (at != null) {
      answer = await _ask('textDocument/completion', {
        'textDocument': {'uri': _generatedUri(uri)},
        'position': {'line': at.line, 'character': at.column},
      });
    }

    // Put the real document back before anything else asks about it.
    _toAnalyser({
      'jsonrpc': '2.0',
      'method': 'textDocument/didChange',
      'params': {
        'textDocument': {'uri': _generatedUri(uri), 'version': ++document.version},
        'contentChanges': [
          {'text': document.generated}
        ],
      },
    });

    _toEditor({
      'jsonrpc': '2.0',
      'id': message['id'],
      'result': tag.completingName
          ? _asComponents(answer['result'])
          : answer['result'],
    });
  }

  /// Closes the tag the cursor is inside, so the file compiles.
  static String _repair(String source, Spot spot) {
    final lines = source.split('\n');
    final line = lines[spot.line];
    final column = spot.column.clamp(0, line.length);
    lines[spot.line] =
        '${line.substring(0, column)}/>${line.substring(column)}';
    return lines.join('\n');
  }

  /// The generated position just inside `NameProps(`, where the analyser will
  /// offer the component's named arguments.
  static Spot? _argumentListSpot(String generated, Spot spot, String name) {
    final lines = generated.split('\n');
    if (spot.line >= lines.length) return null;
    final at = lines[spot.line].indexOf('${name}Props(');
    if (at < 0) return null;
    return Spot(spot.line, at + '${name}Props('.length);
  }

  /// The generated position of the partially-typed props type name.
  static Spot? _componentNameSpot(String generated, Spot spot, String name) {
    final lines = generated.split('\n');
    if (spot.line >= lines.length) return null;
    final at = lines[spot.line].indexOf('${name}Props');
    if (at < 0) return null;
    return Spot(spot.line, at + name.length);
  }

  /// Turns props types back into the components they stand for.
  ///
  /// The analyser is answering about Dart, so it offers `StatCardProps`. In
  /// markup the thing being typed is `<StatCard`, and inserting the generated
  /// name would be inserting something that does not belong in the file.
  Object? _asComponents(Object? result) {
    final items = result is Map ? result['items'] : result;
    if (items is! List) return result;

    final components = <Object?>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final label = '${raw['label']}';
      if (!label.endsWith('Props')) continue;
      final name = label.substring(0, label.length - 'Props'.length);
      if (name.isEmpty) continue;

      final item = Map<String, Object?>.from(raw);
      item['label'] = name;
      item['filterText'] = name;
      item['insertText'] = name;
      item['detail'] = 'component';
      // A text edit would carry the generated file's range; the label is what
      // should be inserted, so anything precomputed is dropped.
      item.remove('textEdit');
      item.remove('textEditText');
      components.add(item);
    }

    return result is Map
        ? {...result, 'items': components, 'isIncomplete': false}
        : components;
  }

  // -- Code lenses ----------------------------------------------------------

  /// One lens per component in the file, above its declaration.
  ///
  /// The count is left for [_resolveLens]: working it out means asking the
  /// analyser once per component, and a file with a dozen of them should not
  /// pay for twelve round trips before anything appears on screen.
  void _lensesFor(Map<String, Object?> message) {
    final uri = ((message['params'] as Map?)?['textDocument']
        as Map?)?['uri'] as String?;
    final document = uri == null ? null : _documents[uri];
    if (document == null) {
      _toEditor({'jsonrpc': '2.0', 'id': message['id'], 'result': const []});
      return;
    }

    final lenses = <Object?>[];
    final lines = document.source.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final match = _componentDeclaration.firstMatch(lines[i]);
      if (match == null) continue;
      final name = match.group(1)!;
      final column = lines[i].indexOf(name, match.start);
      lenses.add({
        'range': {
          'start': {'line': i, 'character': column},
          'end': {'line': i, 'character': column + name.length},
        },
        // Carried through resolve, so the second half does not have to find
        // the declaration again.
        'data': {'uri': uri, 'name': name, 'line': i, 'character': column},
      });
    }

    _toEditor({'jsonrpc': '2.0', 'id': message['id'], 'result': lenses});
  }

  /// Fills in a lens with the number of places the markup uses the component,
  /// and the command that shows them.
  Future<void> _resolveLens(Map<String, Object?> message) async {
    final lens = Map<String, Object?>.from(
        message['params'] as Map<String, Object?>? ?? const {});
    final data = lens['data'] as Map<String, Object?>?;
    final uri = data?['uri'] as String?;
    final name = data?['name'] as String?;
    final document = uri == null ? null : _documents[uri];

    if (document == null || name == null || uri == null) {
      _toEditor({'jsonrpc': '2.0', 'id': message['id'], 'result': lens});
      return;
    }

    // The same redirection find-references uses: the markup names the props
    // type, not the function, so that is what the call sites refer to.
    final target = _classDeclaration(document.generated, '${name}Props');
    if (target == null) {
      _toEditor({'jsonrpc': '2.0', 'id': message['id'], 'result': lens});
      return;
    }

    final answer = await _ask('textDocument/references', {
      'textDocument': {'uri': _generatedUri(uri)},
      'position': {'line': target.line, 'character': target.column},
      'context': {'includeDeclaration': false},
    });

    final mapped = _mapLocationsBack(answer);
    final found = ((mapped as Map<String, Object?>?)?['result'] as List?) ?? const [];

    // A reference in the file that declares the component is the generated
    // machinery standing behind it, not a use of it.
    final uses = [
      for (final entry in found)
        if (entry is Map && entry['uri'] != uri) entry
    ];

    final position = {
      'line': data!['line'] as int? ?? 0,
      'character': data['character'] as int? ?? 0,
    };

    lens['command'] = {
      'title': uses.isEmpty
          ? 'no usages'
          : '${uses.length} usage${uses.length == 1 ? '' : 's'}',
      // Not `editor.action.showReferences`: its arguments have to be real
      // `Uri`, `Position` and `Location` objects, and what travels over LSP is
      // plain JSON. The extension owns the command that rebuilds them.
      'command': 'dartx.showReferences',
      'arguments': [uri, position, uses],
    };

    _toEditor({'jsonrpc': '2.0', 'id': message['id'], 'result': lens});
  }

  /// The tag the cursor sits inside, or null when it sits in Dart or in text.
  ///
  /// Scans back from the cursor for a `<` with no `>` after it. Only component
  /// tags are reported: a host element's attributes are the HTML spec's, and
  /// the analyser has nothing to say about a map with string keys.
  static _TagContext? _tagAround(String source, Spot spot) {
    final lines = source.split('\n');
    if (spot.line >= lines.length) return null;
    final line = lines[spot.line];
    final column = spot.column.clamp(0, line.length);
    final before = line.substring(0, column);

    final open = before.lastIndexOf('<');
    if (open < 0) return null;
    if (before.indexOf('>', open) >= 0) return null; // the tag already closed
    if (before.startsWith('</', open)) return null;

    final after = before.substring(open + 1);
    final name = RegExp(r'^[A-Za-z_\$][\w\$.]*').stringMatch(after) ?? '';
    if (name.isEmpty) return null;
    // Lowercase is a host element; its attributes are HTML's, not Dart's.
    if (name[0].toLowerCase() == name[0] && !name.startsWith('_')) return null;

    return _TagContext(
      name: name,
      completingName: after.length == name.length,
    );
  }

  /// Puts a question of our own to the analyser and waits for the answer.
  ///
  /// The id is a string, so it can never collide with the editor's integers —
  /// the two conversations share one pipe.
  Future<Map<String, Object?>> _ask(
      String method, Map<String, Object?> params) {
    final id = 'dartx-${_nextInternalId++}';
    final completer = Completer<Map<String, Object?>>();
    _internal[id] = completer;
    _toAnalyser({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return completer.future
        .timeout(const Duration(seconds: 20), onTimeout: () => const {});
  }

  void _toAnalyser(Map<String, Object?> message) {
    final process = _analyser;
    if (process == null) return;
    process.stdin.add(frame(message));
  }

  static String _generatedUri(String dartxUri) => '$dartxUri.dart';

  static String _sourceUri(String generatedUri) =>
      generatedUri.substring(0, generatedUri.length - '.dart'.length);

  static Map<String, Object?> _pointRange(int line, int column) => {
        'start': {'line': line, 'character': column},
        'end': {'line': line, 'character': column + 1},
      };

  /// A full-document change, which is the only sync kind this server asks for.
  static String _fullText(Map<String, Object?> params) {
    final changes = params['contentChanges'] as List? ?? const [];
    if (changes.isEmpty) return '';
    final last = changes.last;
    return last is Map ? last['text'] as String? ?? '' : '';
  }
}
