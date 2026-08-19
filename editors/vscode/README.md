# dartx for VS Code

Editor support for `.dartx` files — Dart with JSX-style markup, from the
[reactx](https://github.com/gaspardmerten/react-dart) package.

```dart
VNode Counter(Props props) {
  final (count, setCount) = useState(0);

  return (
    <section class="counter">
      <h2>Counter</h2>
      <p>Value: <strong>{count}</strong></p>
      <button onClick={() => setCount((c) => c + 1)}>+</button>
    </section>
  );
}
```

## What you get

| | |
|---|---|
| **Highlighting** | Tags, attributes, entities and embedded Dart, with the Dart grammar handling everything outside the markup. |
| **Live diagnostics** | Markup errors underlined as you type, with the same messages the build produces. |
| **Tag editing** | `>` closes the tag you just opened; `</` completes the innermost open one. |
| **Snippets** | `comp`, `compstate`, `ust`, `uef`, `frag`, `map`, … |
| **Commands** | Run `build_runner` build/watch, compile the current file, open the generated Dart beside it. |

## Requirements

* The [Dart extension](https://marketplace.visualstudio.com/items?itemName=Dart-Code.dart-code)
  — its grammar is embedded for the Dart parts of a `.dartx` file.
* A package that depends on `reactx`, so `dart run reactx:dartx` resolves.
  Diagnostics come from that transpiler; if it cannot be run, the extension
  says so once and stays quiet.

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `dartx.dartPath` | `dart` | The `dart` executable to use. |
| `dartx.transpilerArgs` | `["run", "reactx:dartx"]` | How to invoke the transpiler. Point this elsewhere if you vendored it. |
| `dartx.diagnostics.enabled` | `true` | Report markup errors. |
| `dartx.diagnostics.runOn` | `type` | `type` or `save`. |
| `dartx.diagnostics.debounce` | `250` | Milliseconds of idle before re-checking. |
| `dartx.autoCloseTags` | `true` | Insert and complete closing tags. |
| `dartx.suggestTags` | `true` | Suggest HTML element names after `<`. |

## How diagnostics stay fast

The extension starts one `dart run reactx:dartx --server` process per workspace
folder and talks to it in JSON lines over stdin/stdout. Starting a VM per
keystroke would cost about a second; a warm process answers in well under a
millisecond, so checking on every keystroke is affordable.

## Installing

From this directory:

```bash
npx @vscode/vsce package     # produces dartx-0.1.0.vsix
code --install-extension dartx-0.1.0.vsix
```

There is no build step — the extension is plain JavaScript.

To hack on it, open `editors/vscode` in VS Code and press <kbd>F5</kbd>.

## Known limitation

Highlighting is regex-based, so it cannot always tell a Dart type argument from
a tag: a bare `<Foo>{...}` set literal in expression position may be coloured as
an element. Compilation is unaffected — the transpiler makes that distinction
properly. (`List<String>`, `Map<K, V>` and `<String>[]` are all handled.)

## License

MIT.
