# Changelog

## 0.2.0

* A language server. `.dartx` files now get real Dart type errors inline, go to
  definition, and hover — answered by Dart's own analysis server, which the
  extension proxies to rather than reimplementing. Go to definition on a
  component lands on the component, not on the generated Dart.
* Snippets updated to the current component API. `comp` used to emit
  `VNode Name(Props props)`, which the framework no longer uses; new
  `compmemo`, `compchildren` and `route`.
* `dartx.languageServer.enabled` turns the server off, falling back to the
  previous markup-only checking.

## 0.1.0

First release.

- `.dartx` language, with a TextMate grammar that embeds the Dart grammar for
  everything outside the markup.
- Live diagnostics from `dart run reactx:dartx --server`, one warm process per
  workspace folder.
- Closing-tag insertion on `>` and completion on `</`.
- Snippets for components, hooks, fragments, keyed lists and markup comments.
- Commands: build, watch, compile the current file, open the generated Dart.
