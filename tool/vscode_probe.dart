/// Drives a real VS Code window over the Chrome DevTools Protocol.
///
/// VS Code is Electron, so its window is a Chromium page and can be attached
/// to like any other. That matters because the editor is where every recent
/// bug in the dartx extension has lived, and none of them were visible from
/// the language-server protocol: capability negotiation, definition-link
/// ranges, completion edit ranges. Each of those was correct on the wire and
/// discarded by the editor.
///
/// This drives the thing that does the discarding. It types, triggers the
/// suggest widget, and reads the DOM — including the token classes Monaco
/// puts on syntax-highlighted text, which is the only way to check a colour
/// without a person looking at it.
///
/// ```
/// code --user-data-dir=/tmp/vsprobe/data --extensions-dir=/tmp/vsprobe/ext \
///      --remote-debugging-port=9444 .
/// dart run tool/vscode_probe.dart <file> <line> <column>
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

late WebSocket socket;
var _id = 0;
final _pending = <int, Completer<Map<String, Object?>>>{};

Future<Map<String, Object?>> send(String method, [Map<String, Object?>? p]) {
  final id = ++_id;
  final completer = Completer<Map<String, Object?>>();
  _pending[id] = completer;
  socket.add(jsonEncode({'id': id, 'method': method, 'params': p ?? {}}));
  return completer.future.timeout(const Duration(seconds: 30));
}

Future<Object?> eval(String expression) async {
  final result = await send('Runtime.evaluate', {
    'expression': expression,
    'returnByValue': true,
    'awaitPromise': true,
  });
  final r = (result['result'] as Map)['result'] as Map;
  if (r['subtype'] == 'error') throw StateError('${r['description']}');
  return r['value'];
}

Future<void> settle([int ms = 400]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// Sends one key the way a keyboard would, which is what Monaco listens for.
Future<void> key(String key, {int? code, String? text, List<String> modifiers = const []}) async {
  var mask = 0;
  for (final m in modifiers) {
    mask |= switch (m) {
      'alt' => 1,
      'ctrl' => 2,
      'meta' => 4,
      'shift' => 8,
      _ => 0,
    };
  }
  final base = {
    'modifiers': mask,
    'key': key,
    if (code != null) 'windowsVirtualKeyCode': code,
    if (code != null) 'nativeVirtualKeyCode': code,
  };
  await send('Input.dispatchKeyEvent', {
    ...base,
    'type': text != null ? 'keyDown' : 'rawKeyDown',
    if (text != null) 'text': text,
  });
  await send('Input.dispatchKeyEvent', {...base, 'type': 'keyUp'});
}

Future<void> type(String text) async {
  for (final ch in text.split('')) {
    await send('Input.dispatchKeyEvent',
        {'type': 'keyDown', 'text': ch, 'key': ch});
    await send('Input.dispatchKeyEvent', {'type': 'keyUp', 'key': ch});
    await settle(12);
  }
}

Future<String?> attach(int port) async {
  final client = HttpClient();
  try {
    final response =
        await (await client.getUrl(Uri.parse('http://localhost:$port/json/list')))
            .close();
    for (final tab in jsonDecode(await response.transform(utf8.decoder).join())
        as List) {
      if ((tab as Map)['type'] == 'page') {
        return tab['webSocketDebuggerUrl'] as String;
      }
    }
  } catch (_) {}
  return null;
}

/// Closes anything modal covering the workbench.
///
/// A fresh profile opens a multi-step welcome wizard, and a modal swallows
/// every keystroke after it — which looks exactly like the editor ignoring
/// you. Worth clearing before deciding anything else is broken.
Future<void> dismissDialogs() async {
  for (var attempt = 0; attempt < 8; attempt++) {
    final closed = await eval(r'''
      (() => {
        const labels = ['Continue without Signing In', 'Continue',
                        'Yes, I trust the authors', 'Got it', 'Skip', 'Later'];
        const visible = (e) => e.offsetParent !== null;
        const close = document.querySelector(
          '.monaco-dialog-box .codicon-dialog-close, .dialog-close');
        for (const label of labels) {
          const hit = [...document.querySelectorAll('a, button, .monaco-button')]
            .find((e) => e.textContent.trim() === label && visible(e));
          if (hit) { hit.click(); return 'clicked ' + label; }
        }
        if (close && visible(close)) { close.click(); return 'closed'; }
        return document.querySelector('.monaco-dialog-modal-block') ? 'blocked' : '';
      })()
    ''');
    if ('$closed'.isEmpty) return;
    await settle(700);
  }
}

/// Opens [path] through the quick-open box, as a person would.
Future<void> open(String path) async {
  await key('p', code: 80, modifiers: ['ctrl']);
  await settle(600);
  await type(path);
  await settle(1200);
  await key('Enter', code: 13);
  await settle(1800);
}

/// Clicks into the code area, because a keystroke goes to whatever has focus
/// and opening a file does not necessarily give it to the editor.
Future<void> focusEditor() async {
  final box = await eval(r'''
    (() => {
      const lines = document.querySelector('.monaco-editor .view-lines');
      if (!lines) return '';
      const r = lines.getBoundingClientRect();
      return JSON.stringify({x: r.left + 40, y: r.top + 12});
    })()
  ''');
  if ('$box'.isEmpty) return;
  final at = jsonDecode('$box') as Map<String, Object?>;
  for (final type in ['mousePressed', 'mouseReleased']) {
    await send('Input.dispatchMouseEvent', {
      'type': type,
      'x': at['x'],
      'y': at['y'],
      'button': 'left',
      'clickCount': 1,
    });
  }
  await settle(400);
}

/// Clicks inside the rendered line containing [marker], [after] characters
/// past where the marker starts.
///
/// More reliable than the go-to-line box, and closer to what a person does.
/// The editor is monospaced, so a character offset is a pixel offset.
Future<bool> clickInLine(String marker, int after) async {
  final box = await eval('''
    (() => {
      // Monaco renders runs of spaces as non-breaking ones, so a plain space
      // in the marker would never match what is on screen.
      const flat = (s) => s.replace(/\u00a0/g, ' ');
      const lines = [...document.querySelectorAll('.monaco-editor .view-line')];
      const line = lines.find((l) => flat(l.textContent).includes(${jsonEncode(marker)}));
      if (!line) return '';
      const r = line.getBoundingClientRect();
      const text = flat(line.textContent);
      // A `.view-line` is as wide as the viewport, not as wide as its text, so
      // its own box says nothing about character width. A span inside it does.
      const span = [...line.querySelectorAll('span span')]
          .find((s) => s.textContent.length > 2) || line.firstElementChild;
      const sr = span.getBoundingClientRect();
      const width = sr.width / Math.max(flat(span.textContent).length, 1);
      const start = text.indexOf(${jsonEncode(marker)});
      return JSON.stringify({
        x: r.left + width * (start + $after) + width / 2,
        y: r.top + r.height / 2,
      });
    })()
  ''');
  if ('$box'.isEmpty) return false;
  final at = jsonDecode('$box') as Map<String, Object?>;
  for (final type in ['mousePressed', 'mouseReleased']) {
    await send('Input.dispatchMouseEvent', {
      'type': type,
      'x': at['x'],
      'y': at['y'],
      'button': 'left',
      'clickCount': 1,
    });
  }
  await settle(400);
  return true;
}

/// Puts the cursor at a one-based line and column via the go-to-line box.
Future<void> goTo(int line, int column) async {
  await key('g', code: 71, modifiers: ['ctrl']);
  await settle(500);
  await type('$line:$column');
  await settle(500);
  await key('Enter', code: 13);
  await settle(700);
}

/// The suggest widget's entries, or an empty list when it is not showing.
Future<List<String>> suggestions() async {
  final raw = await eval(r'''
    (() => {
      const widget = document.querySelector('.suggest-widget');
      if (!widget || widget.classList.contains('hidden')) return '[]';
      const rows = widget.querySelectorAll('.monaco-list-row .label-name');
      return JSON.stringify([...rows].map((r) => r.textContent.trim()));
    })()
  ''');
  return (jsonDecode('$raw') as List).cast<String>();
}

/// Every token on the focused line, as `text` paired with the Monaco class
/// that carries its colour. Two tokens sharing a class share a colour.
Future<List<List<String>>> tokensOnCursorLine() async {
  final raw = await eval(r'''
    (() => {
      const line = document.querySelector('.view-line .cursor')
        ? document.querySelector('.view-line .cursor').closest('.view-line')
        : null;
      const target = line || document.querySelector('.view-lines .view-line');
      if (!target) return '[]';
      return JSON.stringify([...target.querySelectorAll('span span')]
        .map((s) => [s.textContent, s.className]));
    })()
  ''');
  return [
    for (final pair in jsonDecode('$raw') as List)
      (pair as List).cast<String>()
  ];
}

Future<void> main(List<String> args) async {
  final port = int.tryParse(_option(args, '--port') ?? '') ?? 9444;
  final url = await attach(port);
  if (url == null) {
    stderr.writeln('No VS Code listening on $port. Start one with:\n'
        '  code --user-data-dir=/tmp/vsprobe/data '
        '--extensions-dir=/tmp/vsprobe/ext --remote-debugging-port=$port .');
    exitCode = 1;
    return;
  }

  socket = await WebSocket.connect(url);
  socket.listen((raw) {
    final message = jsonDecode(raw as String) as Map<String, Object?>;
    final id = message['id'];
    if (id is int) _pending.remove(id)?.complete(message);
  });
  await send('Runtime.enable');
  await send('Page.enable');

  // A first run puts a sign-in dialog over everything, and a modal swallows
  // every keystroke that follows — which looks exactly like the editor
  // ignoring you. Clear it before doing anything else.
  await dismissDialogs();

  final file = args.isNotEmpty && !args.first.startsWith('--') ? args.first : null;
  if (file != null) await open(file);

  await focusEditor();

  final marker = _option(args, '--at');
  if (marker != null) {
    final offset = int.tryParse(_option(args, '--after') ?? '') ?? marker.length;
    if (!await clickInLine(marker, offset)) {
      stderr.writeln('no line containing ${jsonEncode(marker)}');
    }
  }

  final line = int.tryParse(_option(args, '--line') ?? '');
  final column = int.tryParse(_option(args, '--column') ?? '');
  if (line != null && column != null) await goTo(line, column);

  if (args.contains('--tokens')) {
    stdout.writeln('tokens on the cursor line:');
    for (final token in await tokensOnCursorLine()) {
      stdout.writeln('  ${token[1].padRight(8)}  ${jsonEncode(token[0])}');
    }
  }

  // Typing is what actually opens the suggest widget, and it is what a person
  // does. Dispatching Ctrl+Space through CDP does not reach VS Code's
  // keybinding layer — a control run in a plain `.dart` file showed the widget
  // staying shut there too, which is how that was told apart from the
  // extension having nothing to offer.
  final typed = _option(args, '--type');
  if (typed != null) {
    await type(typed);
    await settle(2500);
  }

  if (args.contains('--suggest')) {
    if (typed == null) {
      await key(' ', code: 32, modifiers: ['ctrl']);
      await settle(2500);
    }
    final items = await suggestions();
    stdout.writeln('suggest widget: ${items.isEmpty ? 'not showing' : items.length}');
    for (final item in items.take(12)) {
      stdout.writeln('  $item');
    }
  }

  final shot = _option(args, '--screenshot');
  if (shot != null) {
    final result = await send('Page.captureScreenshot', {'format': 'png'});
    File(shot).writeAsBytesSync(
        base64Decode((result['result'] as Map)['data'] as String));
    stdout.writeln('screenshot -> $shot');
  }

  await socket.close();
}

String? _option(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}
