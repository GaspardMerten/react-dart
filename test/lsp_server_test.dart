/// The `.dartx` language server, driven the way an editor drives it.
///
/// This talks real LSP over stdio to the real server, which spawns the real
/// `dart language-server`. Nothing is stubbed, because the whole claim being
/// tested is that Dart's own analyser can answer questions about a file it
/// cannot read — and a stub would answer them by construction.
///
/// It is slow (the analysis server takes seconds to warm up) and it needs a
/// Dart SDK on PATH, so it self-skips when that is missing.
@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// A workspace on disk, because the analysis server resolves imports and
/// packages the way it always does and there is no point pretending otherwise.
late Directory workspace;

Future<void> setUpWorkspace() async {
  workspace = await Directory.systemTemp.createTemp('reactx_lsp_');
  final root = Directory.current.path;

  File('${workspace.path}/pubspec.yaml').writeAsStringSync('''
name: dartx_lsp_probe
environment:
  sdk: ">=3.0.0 <4.0.0"
dependencies:
  reactx:
    path: $root
''');

  Directory('${workspace.path}/lib').createSync();
  File('${workspace.path}/lib/card.dartx').writeAsStringSync('''
import 'package:reactx/reactx.dart';

Component StatCard({required String label, required int value}) => <div class="card">
  <span>{label}</span>
  <b>{value}</b>
</div>;
''');

  final pubGet = await Process.run('dart', ['pub', 'get'],
      workingDirectory: workspace.path);
  if (pubGet.exitCode != 0) throw StateError('pub get: ${pubGet.stderr}');

  final build = await Process.run(
      'dart', ['run', 'build_runner', 'build', '--delete-conflicting-outputs'],
      workingDirectory: workspace.path);
  if (build.exitCode != 0) throw StateError('build_runner: ${build.stderr}');
}

/// A minimal LSP client: enough to open a document and ask about a position.
class Editor {
  Editor(this.process) {
    _listen();
  }

  final Process process;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  final List<Map<String, Object?>> notifications = [];
  int _id = 0;

  /// What the server said it can do, which is a contract in its own right.
  Map<String, Object?> capabilities = const {};

  static Future<Editor> start(String workspacePath,
      {Map<String, Object?> capabilities = const {}}) async {
    final process = await Process.start(
      'dart',
      ['run', 'reactx:dartx_lsp'],
      workingDirectory: workspacePath,
    );
    final editor = Editor(process);
    final initialized = await editor.request('initialize', {
      'processId': pid,
      'rootUri': Uri.file(workspacePath).toString(),
      'capabilities': capabilities,
    });
    editor.capabilities = Map<String, Object?>.from(
        (initialized['result'] as Map?)?['capabilities'] as Map? ?? const {});
    editor.notify('initialized', {});
    return editor;
  }

  void _send(Map<String, Object?> message) {
    final body = utf8.encode(jsonEncode(message));
    process.stdin
      ..add(utf8.encode('Content-Length: ${body.length}\r\n\r\n'))
      ..add(body);
  }

  Future<Map<String, Object?>> request(String method, Map<String, Object?> p) {
    final id = ++_id;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': p});
    return completer.future.timeout(const Duration(seconds: 90));
  }

  void notify(String method, Map<String, Object?> p) =>
      _send({'jsonrpc': '2.0', 'method': method, 'params': p});

  void open(String uri, String text) => notify('textDocument/didOpen', {
        'textDocument': {
          'uri': uri,
          'languageId': 'dartx',
          'version': 1,
          'text': text,
        }
      });

  void _listen() {
    final buffer = <int>[];
    process.stdout.listen((chunk) {
      buffer.addAll(chunk);
      while (true) {
        final text = utf8.decode(buffer, allowMalformed: true);
        final headerEnd = text.indexOf('\r\n\r\n');
        if (headerEnd < 0) return;
        final match =
            RegExp(r'Content-Length: (\d+)').firstMatch(text.substring(0, headerEnd));
        if (match == null) return;
        final length = int.parse(match.group(1)!);
        final headerBytes = utf8.encode(text.substring(0, headerEnd + 4)).length;
        if (buffer.length < headerBytes + length) return;

        final body =
            utf8.decode(buffer.sublist(headerBytes, headerBytes + length));
        buffer.removeRange(0, headerBytes + length);

        final message = jsonDecode(body) as Map<String, Object?>;
        final id = message['id'];
        if (id is int && _pending.containsKey(id)) {
          _pending.remove(id)!.complete(message);
        } else if (message['method'] != null) {
          notifications.add(message);
        }
      }
    });
  }

  /// Diagnostics most recently published for [uri].
  List<Map<String, Object?>> diagnosticsFor(String uri) {
    final published = notifications.where((n) =>
        n['method'] == 'textDocument/publishDiagnostics' &&
        (n['params'] as Map)['uri'] == uri);
    if (published.isEmpty) return const [];
    return [
      for (final entry in published)
        for (final d in (entry['params'] as Map)['diagnostics'] as List)
          Map<String, Object?>.from(d as Map)
    ];
  }

  void stop() => process.kill();
}

/// Waits until [predicate] holds, or gives up. LSP is asynchronous and the
/// analysis server warms up slowly; polling beats a fixed sleep.
Future<bool> eventually(bool Function() predicate,
    {Duration limit = const Duration(seconds: 90)}) async {
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return predicate();
}

void main() {
  final dart = Process.runSync('dart', ['--version']);
  if (dart.exitCode != 0) {
    test('language server', () {}, skip: 'no Dart SDK on PATH');
    return;
  }

  late Editor editor;

  setUpAll(() async {
    await setUpWorkspace();
    editor = await Editor.start(workspace.path);
  });

  tearDownAll(() async {
    editor.stop();
    await workspace.delete(recursive: true);
  });

  group('what the server tells the editor it can do', () {
    test('it claims the requests it translates', () {
      // Without this the editor never asks. The analysis server advertises
      // neither definition nor hover up front — it registers them later,
      // scoped to `language: dart` — so a `.dartx` file went unserved and
      // Ctrl-click did nothing at all.
      for (final capability in const [
        'definitionProvider',
        'typeDefinitionProvider',
        'implementationProvider',
        'referencesProvider',
        'hoverProvider',
        'documentHighlightProvider',
      ]) {
        expect(editor.capabilities[capability], isTrue, reason: capability);
      }
      expect(editor.capabilities['completionProvider'], isNotNull);
    });

    test('it claims nothing that would act on the generated file', () {
      // `executeCommandProvider` is the one that broke the editor outright:
      // its command ids are the Dart extension's, and registering them twice
      // fails initialization. The rest would be quieter and worse — a code
      // action or a rename edits a `WorkspaceEdit` whose paths this proxy does
      // not rewrite, so accepting the fix would edit generated Dart that the
      // next build discards.
      for (final capability in const [
        'executeCommandProvider',
        'codeActionProvider',
        'renameProvider',
        'documentFormattingProvider',
        'documentRangeFormattingProvider',
        'documentSymbolProvider',
        'foldingRangeProvider',
        'semanticTokensProvider',
        'callHierarchyProvider',
      ]) {
        expect(editor.capabilities.containsKey(capability), isFalse,
            reason: '$capability would act on a file the person cannot see');
      }
    });

    test('it asks for whole documents, not ranged edits', () {
      // The generated Dart comes from compiling the entire buffer, so there is
      // nothing for a ranged edit to apply to — and reading the typed fragment
      // as the whole file would replace the document with one character.
      final sync = editor.capabilities['textDocumentSync'];
      expect(sync, isA<Map>());
      expect((sync as Map)['change'], 1);
    });
  });

  test('a Dart type error is reported against the .dartx that caused it',
      () async {
    const source = '''import 'package:reactx/reactx.dart';

import 'card.dartx.dart';

Component Page() => <section>
  <StatCard label="Done" value={'three'} />
  <StatCard lable="Nope" value={1} />
</section>;
''';
    final uri = Uri.file('${workspace.path}/lib/broken.dartx').toString();
    editor.open(uri, source);

    await eventually(() => editor.diagnosticsFor(uri).length >= 2);
    final reported = editor.diagnosticsFor(uri);
    final messages = reported.map((d) => '${d['message']}').toList();

    expect(
        messages,
        contains(allOf(contains("'String'"), contains("'int'"))),
        reason: 'the analyser sees the generated Dart; the person sees this '
            'file, and the error has to arrive here');
    expect(messages, contains(contains('lable')));

    int lineOf(bool Function(String) matching) => reported
        .firstWhere((d) => matching('${d['message']}'))
        .let((d) => ((d['range'] as Map)['start'] as Map)['line'] as int);

    expect(lineOf((m) => m.contains("'String'")), 5,
        reason: 'the wrong argument is on the line that wrote it');
    expect(lineOf((m) => m.contains('lable')), 6);
  });

  test('go to definition on a component opens the component, not the '
      'generated props type', () async {
    const source = '''import 'package:reactx/reactx.dart';

import 'card.dartx.dart';

Component Page({required int done}) => <section>
  <StatCard label="Done" value={done} />
</section>;
''';
    final uri = Uri.file('${workspace.path}/lib/page.dartx').toString();
    editor.open(uri, source);
    await eventually(() => true, limit: const Duration(seconds: 8));

    final line = source.split('\n')[5];
    final response = await editor.request('textDocument/definition', {
      'textDocument': {'uri': uri},
      'position': {'line': 5, 'character': line.indexOf('StatCard') + 2},
    });

    final locations = response['result'] as List?;
    expect(locations, isNotNull);
    expect(locations, isNotEmpty);

    final target = locations!.first as Map;
    expect(target['uri'], endsWith('card.dartx'),
        reason: 'a generated file is not somewhere a person should be sent');
    // `Component StatCard(` — the declaration, not the appended props class.
    expect(((target['range'] as Map)['start'] as Map)['line'], 2);
  });

  test('a definition link is usable when the editor asks for one', () async {
    // VS Code sends `linkSupport: true`, which changes the answer's shape from
    // a Location to a LocationLink — three ranges instead of one, two of which
    // this proxy used to leave in generated coordinates. The result was a link
    // whose target range fell outside the file it named, and an editor will
    // not follow one of those. Ctrl-click simply did nothing.
    final linkEditor = await Editor.start(workspace.path, capabilities: {
      'textDocument': {
        'definition': {'dynamicRegistration': true, 'linkSupport': true},
      }
    });
    addTearDown(linkEditor.stop);

    const source = '''import 'package:reactx/reactx.dart';

import 'card.dartx.dart';

Component Panel() => <section>
  <StatCard label="Done" value={1} />
</section>;
''';
    final uri = Uri.file('${workspace.path}/lib/panel.dartx').toString();
    linkEditor.open(uri, source);
    await eventually(() => true, limit: const Duration(seconds: 12));

    final line = source.split('\n')[5];
    final response = await linkEditor.request('textDocument/definition', {
      'textDocument': {'uri': uri},
      'position': {'line': 5, 'character': line.indexOf('StatCard') + 2},
    });

    final links = response['result'] as List?;
    expect(links, isNotEmpty);
    final link = links!.first as Map<String, Object?>;

    // What the editor makes clickable has to be the word under the cursor.
    final origin = link['originSelectionRange'] as Map?;
    expect(origin, isNotNull, reason: 'no clickable region, no Ctrl-click');
    expect((origin!['start'] as Map)['line'], 5);
    expect((origin['start'] as Map)['character'], line.indexOf('StatCard'));
    expect((origin['end'] as Map)['character'],
        line.indexOf('StatCard') + 'StatCard'.length);

    // Every range that names the target must be inside the target.
    final target = '${link['targetUri']}';
    expect(target, endsWith('card.dartx'));
    final targetLines =
        File(Uri.parse(target).toFilePath()).readAsStringSync().split('\n').length;
    for (final key in const ['targetRange', 'targetSelectionRange']) {
      final range = link[key] as Map?;
      expect(range, isNotNull, reason: key);
      expect((range!['start'] as Map)['line'], lessThan(targetLines),
          reason: '$key points past the end of the file it names');
    }
  });

  test('find references on a component reports where the markup uses it',
      () async {
    // The literal question — "references to the function `StatCard`" — has the
    // wrong answer: the markup compiles to `StatCardProps(…)`, so the only
    // caller of the function is one line of generated machinery, and not one
    // real call site would be listed. The request is retargeted onto the props
    // type, which is what the call sites actually name.
    const page = '''import 'package:reactx/reactx.dart';

import 'card.dartx.dart';

Component Board() => <section>
  <StatCard label="Done" value={1} />
  <StatCard label="Left" value={2} />
</section>;
''';
    final pageUri = Uri.file('${workspace.path}/lib/board.dartx').toString();
    editor.open(pageUri, page);

    final cardUri = Uri.file('${workspace.path}/lib/card.dartx').toString();
    final card = File('${workspace.path}/lib/card.dartx').readAsStringSync();
    editor.open(cardUri, card);
    await eventually(() => true, limit: const Duration(seconds: 10));

    final declarationLine =
        card.split('\n').indexWhere((l) => l.contains('Component StatCard'));
    final response = await editor.request('textDocument/references', {
      'textDocument': {'uri': cardUri},
      'position': {
        'line': declarationLine,
        'character': card.split('\n')[declarationLine].indexOf('StatCard'),
      },
      'context': {'includeDeclaration': false},
    });

    final locations =
        (response['result'] as List? ?? []).cast<Map<String, Object?>>().toList();
    expect(locations, isNotEmpty);

    // Nothing generated leaks out.
    expect(locations.map((l) => l['uri']),
        everyElement(isNot(endsWith('.dartx.dart'))),
        reason: 'a generated file is not a place a person can act on');

    final inBoard =
        locations.where((l) => '${l['uri']}'.endsWith('board.dartx')).toList();
    expect(inBoard.length, 2,
        reason: 'both `<StatCard …>` elements are uses of the component');
    expect(inBoard.map((l) => ((l['range'] as Map)['start'] as Map)['line']),
        containsAll(<int>[5, 6]));

    // The range covers `StatCard`, not the wider `StatCardProps` the analyser
    // was really answering about.
    for (final location in inBoard) {
      final range = location['range'] as Map;
      final start = (range['start'] as Map)['character'] as int;
      final end = (range['end'] as Map)['character'] as int;
      expect(end - start, 'StatCard'.length);
    }

    // And no line is reported twice because two generated references collapsed
    // onto it.
    final keys = locations.map(
        (l) => '${l['uri']}:${((l['range'] as Map)['start'] as Map)['line']}');
    expect(keys.toSet().length, keys.length, reason: 'duplicates: $keys');
  });

  test('clicking a declaration declines, so the editor offers the usages',
      () async {
    // Ctrl-clicking a component's own name is how people ask "where is this
    // used". The editor only falls back to showing references when definition
    // finds nothing — answer with the line the cursor is already on and it
    // considers the jump done and sits still.
    final cardUri = Uri.file('${workspace.path}/lib/card.dartx').toString();
    final card = File('${workspace.path}/lib/card.dartx').readAsStringSync();
    editor.open(cardUri, card);
    await eventually(() => true, limit: const Duration(seconds: 10));

    final lines = card.split('\n');
    final row = lines.indexWhere((l) => l.contains('Component StatCard'));
    final response = await editor.request('textDocument/definition', {
      'textDocument': {'uri': cardUri},
      'position': {'line': row, 'character': lines[row].indexOf('StatCard') + 2},
    });

    expect(response['result'], isNull,
        reason: 'a definition that points at the cursor is not a destination');
  });

  test('a definition somewhere else is still answered', () async {
    // The decline above must not swallow the useful case.
    const source = '''import 'package:reactx/reactx.dart';

import 'card.dartx.dart';

Component Elsewhere() => <section>
  <StatCard label="Done" value={1} />
</section>;
''';
    final uri = Uri.file('${workspace.path}/lib/elsewhere.dartx').toString();
    editor.open(uri, source);
    await eventually(() => true, limit: const Duration(seconds: 10));

    final line = source.split('\n')[5];
    final response = await editor.request('textDocument/definition', {
      'textDocument': {'uri': uri},
      'position': {'line': 5, 'character': line.indexOf('StatCard') + 2},
    });
    expect(response['result'], isNotEmpty);
  });

  test('hover on an argument reports the type the component declared',
      () async {
    const source = '''import 'package:reactx/reactx.dart';

import 'card.dartx.dart';

Component Page({required int done}) => <section>
  <StatCard label="Done" value={done} />
</section>;
''';
    final uri = Uri.file('${workspace.path}/lib/hover.dartx').toString();
    editor.open(uri, source);
    await eventually(() => true, limit: const Duration(seconds: 8));

    final line = source.split('\n')[5];
    final response = await editor.request('textDocument/hover', {
      'textDocument': {'uri': uri},
      'position': {'line': 5, 'character': line.indexOf('done')},
    });

    final contents = jsonEncode(response['result']);
    expect(contents, contains('int'));
    // The range comes back in .dartx coordinates, not the generated file's.
    final range = (response['result'] as Map)['range'];
    if (range != null) {
      expect(((range as Map)['start'] as Map)['line'], 5);
    }
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
