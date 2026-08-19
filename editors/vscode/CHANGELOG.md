# Changelog

## 0.2.6

* Ctrl-clicking a component's own name now offers its usages. It used to answer
  "the definition is the line you are on", which the editor takes as a
  successful jump — so it sat still instead of falling back to references.
* The server writes a log to `.dart_tool/dartx-lsp.log`, which is how the above
  was found.

## 0.2.4

* Fixed: Ctrl-click still did nothing. VS Code asks for definitions as *links*,
  which carry three ranges rather than one — and two of them were left in the
  generated file's coordinates. The clickable region landed beside the word,
  and the target range fell outside the file it named, which is a link no
  editor will follow.

## 0.2.3

* Changes are batched before they reach the analysis server. Each one costs a
  full re-analysis — the generated Dart comes from compiling the whole buffer,
  so there is no smaller edit to send — and one per keystroke was one
  re-analysis per keystroke. Markup errors are still instant.
* `dartx.languageServer.enabled` now says what it costs: a second Dart analysis
  server, alongside the one the Dart extension runs.

## 0.2.2

* Fixed: "couldn't create connection to server" / "Server initialization
  failed". The proxy forwarded the analysis server's capabilities wholesale,
  including `executeCommandProvider` — whose command ids the Dart extension has
  already registered. Registering them twice throws and takes initialization
  with it. The server now advertises only what it actually translates.
* Fixed: full-document sync is now requested explicitly. The analyser asks for
  incremental edits, and this proxy compiles the whole buffer — so the first
  keystroke would have been read as the entire file.
* Fixed: a hover's highlight was placed using the generated file's columns.

## 0.2.1

* Fixed: Ctrl-click and hover did nothing. The Dart analysis server does not
  advertise `definitionProvider` or `hoverProvider` up front — it registers
  them later, scoped to `language: dart` — so an editor obeying the negotiation
  never asked about a `.dartx` file at all. The server now claims what it
  answers, and widens the analyser's registrations to cover `.dartx`.
* Generated `.dartx.dart` files are nested under the `.dartx` they came from,
  rather than taking a row each in the explorer. `dartx.hideGeneratedFiles`
  chooses `nest` (default), `hide` or `show`.

## 0.2.0

* A language server. `.dartx` files now get real Dart type errors inline, go to
  definition, hover, and find all references — answered by Dart's own analysis
  server, which the extension proxies to rather than reimplementing. Go to
  definition on a component lands on the component, and find references lists
  the markup that uses it, not the generated Dart behind it.
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
