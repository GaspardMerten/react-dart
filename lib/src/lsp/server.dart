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

    switch (method) {
      case 'textDocument/didOpen':
      case 'textDocument/didChange':
      case 'textDocument/didClose':
        _syncDocument(method!, message);
        return;
    }

    if (method != null && _positionRequests.contains(method)) {
      final translated = _translateRequest(message);
      // A position that does not survive compilation has no answer; say so
      // rather than sending the analyser a question about the wrong place.
      if (translated == null) {
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

    _toAnalyser({
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

    _publishDartxDiagnostics(uri, compiled);
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

    final at = document.map.toGenerated(
        Spot(position['line'] as int? ?? 0, position['character'] as int? ?? 0));
    if (at == null) return null;

    params['textDocument'] = {'uri': _generatedUri(uri)};
    params['position'] = {'line': at.line, 'character': at.column};
    return {...message, 'params': params};
  }

  // -- analyser -> editor ----------------------------------------------------

  void _fromAnalyser(Map<String, Object?> message) {
    if (message['method'] == 'textDocument/publishDiagnostics') {
      _toEditor(_translateDiagnostics(message));
      return;
    }
    _toEditor(_mapLocationsBack(message));
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

  Map<String, Object?>? _mapRangeBack(_Document document, Object? range) {
    if (range is! Map) return null;
    final start = _mapSpotBack(document, range['start']);
    if (start != null) {
      final end = _mapSpotBack(document, range['end']);
      return {'start': start, 'end': end ?? start};
    }
    return _declarationBehind(document, range);
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
