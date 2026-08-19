# dartx for VS Code

Editor support for `.dartx` files — Dart with JSX-style markup, from the
[reactx](https://github.com/gaspardmerten/react-dart) package.

```dart
Component Counter({int start = 0}) {
  final (count, setCount) = useState(start);

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
| **Type errors, inline** | `<StatCard value={'three'} />` is underlined in the `.dartx`, on the line that wrote it — the Dart analyser's own message, not an approximation of one. |
| **Go to definition** | On `<StatCard>`, jumps to `Component StatCard(…)` in the `.dartx` that declares it. |
| **Hover** | The declared type of an argument, from the analyser. |
| **Find all references** | On a component, lists the `<StatCard …>` elements that use it — not the generated code that stands behind them. Ctrl-click the declaration, press Shift+F12, or click the lens. |
| **Usage counts** | A **"3 usages"** lens above each component declaration. |
| **Highlighting** | Tags, attributes, entities and embedded Dart. An element owns everything between its tags, so text children are text — not Dart that happens to look like an identifier. |
| **Route paths** | A file under a `routes/` directory shows the URL it serves — `Route  /todo/:id` — above its component. |
| **Markup diagnostics** | The transpiler's own errors — a mismatched closing tag, a spread on a component — which the analyser cannot produce because it never sees the markup. |
| **Tag editing** | `>` closes the tag you just opened; `</` completes the innermost open one. |
| **Snippets** | `comp`, `compstate`, `compmemo`, `compchildren`, `route`, `ust`, `uef`, `frag`, `map`, … |
| **Commands** | Run `build_runner` build/watch, compile the current file, open the generated Dart beside it. |

## How the language features work

There is no second analyser. `dart run reactx:dartx_lsp` sits between the editor
and **Dart's own analysis server** and translates:

```
  editor  ──  Page.dartx, line 5  ──▶  dartx lsp
                                          │  transpile, map the position
                                          ▼
  dart language-server  ◀──  Page.dartx.dart, line 5
                                          │
  editor  ◀──  an error on Page.dartx line 5  ──┘
```

The translation rests on the transpiler preserving line numbers exactly, so
only the column has to be recovered — which it does by identifier, since the
order of identifiers on a line survives compilation.

One honest limit: **completion while you are mid-tag does not work yet.**
`<StatCard ` is not valid markup until it is closed, so there is nothing to
compile and nothing to ask the analyser about. Completion inside a complete
element does work.

Turn the whole thing off with `dartx.languageServer.enabled` and the extension
falls back to markup-only checking.

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
