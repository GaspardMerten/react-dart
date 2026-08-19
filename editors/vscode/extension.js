// @ts-check
'use strict';

/**
 * dartx for VS Code.
 *
 * Four things, in order of how much you notice them:
 *
 *   1. A language server. `dart run reactx:dartx_lsp` proxies to Dart's own
 *      analysis server, so a `.dartx` file gets real type errors, hover and
 *      go-to-definition — the analyser's own answers, about the Dart the file
 *      compiles to, reported back against the file being edited.
 *   2. Tag editing. Finishing `<div>` writes `</div>`; typing `</` completes
 *      the innermost open tag.
 *   3. Commands for the build_runner round trip and for jumping to the
 *      generated Dart.
 *   4. HTML tag suggestions after `<`.
 *
 * Highlighting and snippets are declarative — see syntaxes/ and snippets/.
 *
 * The older stdin/stdout checker below is still here and takes over whenever
 * the language server cannot start — no Dart SDK on PATH, or a workspace where
 * reactx is not a dependency. It reports markup errors only, which is a real
 * step down from the analyser but better than a file with no feedback at all.
 */

const vscode = require('vscode');
const { spawn } = require('child_process');
const path = require('path');

const { tagToClose, innermostOpenTag } = require('./tags');

/** Suggested after `<`. Components come from the file, these do not. */
const { routeFor, routeLabel } = require('./routes');

const HTML_TAGS = [
  'a', 'abbr', 'article', 'aside', 'audio', 'b', 'blockquote', 'body', 'br',
  'button', 'canvas', 'caption', 'code', 'col', 'dd', 'details', 'dialog',
  'div', 'dl', 'dt', 'em', 'fieldset', 'figcaption', 'figure', 'footer',
  'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'head', 'header', 'hr', 'i',
  'iframe', 'img', 'input', 'label', 'legend', 'li', 'link', 'main', 'mark',
  'meta', 'nav', 'ol', 'option', 'p', 'picture', 'pre', 'progress', 'script',
  'section', 'select', 'small', 'span', 'strong', 'style', 'summary', 'sup',
  'svg', 'table', 'tbody', 'td', 'textarea', 'tfoot', 'th', 'thead', 'time',
  'title', 'tr', 'ul', 'video',
];

/** @type {vscode.DiagnosticCollection} */
let diagnostics;
/** @type {vscode.OutputChannel} */
let output;
/** @type {Map<string, DartxServer>} */
const servers = new Map();
/** @type {Map<string, NodeJS.Timeout>} */
const pendingChecks = new Map();

function config() {
  return vscode.workspace.getConfiguration('dartx');
}

// ---------------------------------------------------------------------------
// The transpiler process
// ---------------------------------------------------------------------------

/**
 * A long-lived `dartx --server` process for one workspace folder. Requests and
 * responses are one JSON object per line, answered in order.
 */
class DartxServer {
  /** @param {string} cwd */
  constructor(cwd) {
    this.cwd = cwd;
    /** @type {import('child_process').ChildProcessWithoutNullStreams | null} */
    this.proc = null;
    /** @type {Array<(value: any) => void>} */
    this.queue = [];
    this.buffer = '';
    this.failed = false;
    /** True once the process has answered at least one request. */
    this.answered = false;
    /** True when we killed it ourselves, so its exit is not a problem. */
    this.stopped = false;
  }

  start() {
    if (this.proc || this.failed) return;
    const dart = config().get('dartPath', 'dart');
    const args = [...config().get('transpilerArgs', ['run', 'reactx:dartx']), '--server'];
    output.appendLine(`[dartx] starting: ${dart} ${args.join(' ')} (cwd: ${this.cwd})`);

    let proc;
    try {
      proc = spawn(dart, args, { cwd: this.cwd });
    } catch (e) {
      this.fail(`could not start ${dart}: ${e}`);
      return;
    }
    this.proc = proc;

    proc.stdout.setEncoding('utf8');
    proc.stdout.on('data', (chunk) => this.onData(chunk));
    proc.stderr.setEncoding('utf8');
    proc.stderr.on('data', (chunk) => output.append(`[dartx] ${chunk}`));

    proc.on('error', (e) => this.fail(`transpiler failed to start: ${e.message}`));
    proc.on('exit', (code) => {
      // A non-zero exit before any successful answer means the package is not
      // reachable from this folder; do not respawn in a loop.
      const clean = code === 0;
      this.drain(null);
      this.proc = null;
      if (this.stopped) return; // we asked it to stop; nothing to report
      output.appendLine(`[dartx] server exited (code ${code})`);
      if (!clean && !this.answered) {
        this.fail(
          'the dartx transpiler could not be run. Add reactx to this ' +
          "package's dependencies, or set dartx.transpilerArgs.");
      }
    });
  }

  /** @param {string} message */
  fail(message) {
    this.failed = true;
    this.drain(null);
    output.appendLine(`[dartx] ${message}`);
    vscode.window.showWarningMessage(`dartx: ${message}`, 'Show log').then((choice) => {
      if (choice === 'Show log') output.show(true);
    });
  }

  /** @param {string} chunk */
  onData(chunk) {
    this.buffer += chunk;
    let index;
    while ((index = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, index);
      this.buffer = this.buffer.slice(index + 1);
      if (!line.trim()) continue;
      this.answered = true;
      const resolve = this.queue.shift();
      if (!resolve) continue;
      try {
        resolve(JSON.parse(line));
      } catch (e) {
        output.appendLine(`[dartx] bad response: ${line}`);
        resolve(null);
      }
    }
  }

  /** @param {any} value */
  drain(value) {
    for (const resolve of this.queue.splice(0)) resolve(value);
  }

  /**
   * Checks `source` and resolves to the parsed response, or null if the
   * transpiler is unavailable.
   * @param {string} uri
   * @param {string} source
   * @returns {Promise<any>}
   */
  check(uri, source) {
    this.start();
    if (!this.proc) return Promise.resolve(null);
    return new Promise((resolve) => {
      this.queue.push(resolve);
      this.proc.stdin.write(JSON.stringify({ uri, source }) + '\n');
    });
  }

  dispose() {
    this.stopped = true;
    if (this.proc) this.proc.kill();
    this.proc = null;
    this.drain(null);
  }
}

/** @param {vscode.TextDocument} doc */
function serverFor(doc) {
  const folder = vscode.workspace.getWorkspaceFolder(doc.uri);
  const cwd = folder ? folder.uri.fsPath : path.dirname(doc.uri.fsPath);
  let server = servers.get(cwd);
  if (!server) {
    server = new DartxServer(cwd);
    servers.set(cwd, server);
  }
  return server;
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

/** @param {vscode.TextDocument} doc */
async function check(doc) {
  if (doc.languageId !== 'dartx') return;
  if (!config().get('diagnostics.enabled', true)) {
    diagnostics.delete(doc.uri);
    return;
  }

  const response = await serverFor(doc).check(doc.uri.fsPath, doc.getText());
  if (!response || !Array.isArray(response.diagnostics)) {
    diagnostics.delete(doc.uri);
    return;
  }

  diagnostics.set(doc.uri, response.diagnostics.map((d) => {
    // The transpiler reports a point; widen it to the word under it so the
    // squiggle is visible.
    const start = doc.positionAt(typeof d.offset === 'number'
      ? d.offset
      : doc.offsetAt(new vscode.Position((d.line || 1) - 1, (d.column || 1) - 1)));
    const range = doc.getWordRangeAtPosition(start) ||
      new vscode.Range(start, start.translate(0, 1));
    const diagnostic = new vscode.Diagnostic(
      range, d.message, vscode.DiagnosticSeverity.Error);
    diagnostic.source = 'dartx';
    return diagnostic;
  }));
}

/** @param {vscode.TextDocument} doc */
function scheduleCheck(doc) {
  const key = doc.uri.toString();
  clearTimeout(pendingChecks.get(key));
  pendingChecks.set(key, setTimeout(() => {
    pendingChecks.delete(key);
    check(doc);
  }, config().get('diagnostics.debounce', 250)));
}

// ---------------------------------------------------------------------------
// Tag editing
// ---------------------------------------------------------------------------

/**
 * Inserts `</name>` when an opening tag is finished with `>`.
 * @param {vscode.TextDocumentChangeEvent} event
 */
function autoCloseTag(event) {
  const doc = event.document;
  if (doc.languageId !== 'dartx') return;
  if (!config().get('autoCloseTags', true)) return;

  const change = event.contentChanges[event.contentChanges.length - 1];
  if (!change || change.text !== '>') return;

  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document !== doc) return;

  const end = doc.offsetAt(change.range.start) + 1;
  const name = tagToClose(textUpTo(doc, end));
  if (!name) return;

  const position = doc.positionAt(end);
  editor
    .edit((builder) => builder.insert(position, `</${name}>`), {
      undoStopBefore: false,
      undoStopAfter: false,
    })
    .then(() => {
      editor.selection = new vscode.Selection(position, position);
    });
}

/**
 * Completes `</` with the innermost tag that is still open.
 * @param {vscode.TextDocumentChangeEvent} event
 */
function autoCompleteClosingTag(event) {
  const doc = event.document;
  if (doc.languageId !== 'dartx') return;
  if (!config().get('autoCloseTags', true)) return;

  const change = event.contentChanges[event.contentChanges.length - 1];
  if (!change || change.text !== '/') return;

  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document !== doc) return;

  const end = doc.offsetAt(change.range.start) + 1;
  const before = textUpTo(doc, end);
  if (!before.endsWith('</')) return;

  const name = innermostOpenTag(before.slice(0, -2));
  if (!name) return;

  const position = doc.positionAt(end);
  editor
    .edit((builder) => builder.insert(position, `${name}>`), {
      undoStopBefore: false,
      undoStopAfter: false,
    })
    .then(() => {
      const after = position.translate(0, name.length + 1);
      editor.selection = new vscode.Selection(after, after);
    });
}

/**
 * The document text from the start up to `offset`.
 * @param {vscode.TextDocument} doc
 * @param {number} offset
 */
function textUpTo(doc, offset) {
  return doc.getText(
    new vscode.Range(new vscode.Position(0, 0), doc.positionAt(offset)));
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

/**
 * Opens the peek view on a component's usages.
 *
 * The built-in `editor.action.showReferences` wants real `Uri`, `Position` and
 * `Location` objects, and what arrives over LSP is plain JSON — a code lens
 * command's arguments are passed through untouched. So the server names this
 * command instead, and it rebuilds what the editor needs.
 *
 * @param {string} uri
 * @param {{line: number, character: number}} position
 * @param {Array<{uri: string, range: {start: any, end: any}}>} locations
 */
function showReferences(uri, position, locations) {
  const at = (/** @type {any} */ p) => new vscode.Position(p.line, p.character);
  return vscode.commands.executeCommand(
    'editor.action.showReferences',
    vscode.Uri.parse(uri),
    at(position),
    (locations || []).map((l) => new vscode.Location(
      vscode.Uri.parse(l.uri),
      new vscode.Range(at(l.range.start), at(l.range.end)))));
}

/** @param {string} command */
function runInTerminal(command) {
  const folder = vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders[0];
  const terminal = vscode.window.createTerminal({
    name: 'dartx',
    cwd: folder && folder.uri.fsPath,
  });
  terminal.show();
  terminal.sendText(command);
}

async function openGenerated() {
  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document.languageId !== 'dartx') return;

  const generated = vscode.Uri.file(`${editor.document.uri.fsPath}.dart`);
  try {
    const doc = await vscode.workspace.openTextDocument(generated);
    await vscode.window.showTextDocument(doc, vscode.ViewColumn.Beside);
  } catch (e) {
    const choice = await vscode.window.showWarningMessage(
      `dartx: ${path.basename(generated.fsPath)} does not exist yet.`,
      'Run build_runner');
    if (choice === 'Run build_runner') runInTerminal('dart run build_runner build');
  }
}

async function compileFile() {
  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document.languageId !== 'dartx') return;
  await editor.document.save();
  runInTerminal(
    `${config().get('dartPath', 'dart')} ` +
    `${config().get('transpilerArgs', ['run', 'reactx:dartx']).join(' ')} ` +
    `"${editor.document.uri.fsPath}"`);
}

// ---------------------------------------------------------------------------
// Generated files
// ---------------------------------------------------------------------------

/**
 * Keeps `*.dartx.dart` out of the way without pretending it does not exist.
 *
 * These files are committed on purpose — that is what lets a package build
 * without running `build_runner` first — but they are not files anyone edits,
 * and one per component doubles the length of every folder.
 *
 * Nesting is the default rather than hiding, because hidden files also vanish
 * from quick-open and from search results, and a generated file is exactly
 * what you want to look at when you are trying to understand what the markup
 * compiled to. `hide` is there for people who disagree.
 */
async function applyGeneratedFileVisibility() {
  // Workspace settings need a workspace. Opening a lone `.dartx` file is a
  // perfectly ordinary thing to do, and writing configuration is not worth
  // failing activation over.
  const folders = vscode.workspace.workspaceFolders;
  if (!folders || folders.length === 0) return;
  const target = vscode.ConfigurationTarget && vscode.ConfigurationTarget.Workspace;
  if (target === undefined) return;

  const mode = config().get('hideGeneratedFiles', 'nest');
  const files = vscode.workspace.getConfiguration('files');
  const explorer = vscode.workspace.getConfiguration('explorer');

  const exclude = { ...(files.get('exclude') || {}) };
  const hiding = exclude['**/*.dartx.dart'] === true;

  if (mode === 'hide' && !hiding) {
    exclude['**/*.dartx.dart'] = true;
    await files.update('exclude', exclude, target);
  } else if (mode !== 'hide' && hiding) {
    // Only undo what this setting put there.
    delete exclude['**/*.dartx.dart'];
    await files.update('exclude', exclude, target);
  }

  if (mode === 'nest') {
    const patterns = { ...(explorer.get('fileNesting.patterns') || {}) };
    let changed = false;
    if (patterns['*.dartx'] !== '${capture}.dartx.dart') {
      patterns['*.dartx'] = '${capture}.dartx.dart';
      changed = true;
    }
    // `routes.g.dart` belongs under `routes.dart` for the same reason. Only
    // added when there is no `*.dart` rule already: someone who wrote their own
    // meant it, and overwriting it would be rude.
    if (patterns['*.dart'] === undefined) {
      patterns['*.dart'] = '${capture}.g.dart';
      changed = true;
    }
    if (changed) await explorer.update('fileNesting.patterns', patterns, target);
  }
}

// ---------------------------------------------------------------------------
// The language server
// ---------------------------------------------------------------------------

/** @type {any} */
let client = null;

/**
 * Starts `dartx_lsp`, which proxies to the Dart analysis server.
 *
 * Returns true when it came up. On failure the caller falls back to the
 * markup-only checker rather than leaving the editor with nothing.
 * @param {vscode.ExtensionContext} context
 * @returns {Promise<boolean>}
 */
async function startLanguageServer(context) {
  if (!config().get('languageServer.enabled', true)) return false;

  let LanguageClient, TransportKind;
  try {
    ({ LanguageClient, TransportKind } = require('vscode-languageclient/node'));
  } catch (e) {
    output.appendLine(`[dartx] language client unavailable: ${e}`);
    return false;
  }

  const folder = vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders[0];
  // A log on disk, because the interesting failures are in traffic nobody is
  // watching at the moment they happen.
  const logFile = folder
    ? path.join(folder.uri.fsPath, '.dart_tool', 'dartx-lsp.log')
    : null;
  const server = {
    command: config().get('dartPath', 'dart'),
    args: ['run', 'reactx:dartx_lsp', ...(logFile ? ['--log', logFile] : [])],
    transport: TransportKind.stdio,
    options: { cwd: folder && folder.uri.fsPath },
  };

  try {
    client = new LanguageClient(
      'dartx',
      'dartx language server',
      { run: server, debug: server },
      {
        documentSelector: [{ scheme: 'file', language: 'dartx' }],
        outputChannel: output,
        // The server publishes against the `.dartx` itself, having already
        // mapped the analyser's answers back.
        diagnosticCollectionName: 'dartx',
      });
    await client.start();
    output.appendLine('[dartx] language server ready');
    context.subscriptions.push({ dispose: () => client && client.stop() });
    return true;
  } catch (e) {
    output.appendLine(`[dartx] language server failed to start: ${e}`);
    client = null;
    return false;
  }
}


// ---------------------------------------------------------------------------
// The route a file serves
// ---------------------------------------------------------------------------

/**
 * Shows a page's own URL above its component.
 *
 * Under file-system routing the URL is in the folder names, which is the point
 * — but it is spread over four of them, and `[id]` is not what the router calls
 * it. This says `/todo/:id` in the one place you are already looking. It is
 * pure path arithmetic, so it is right before the first build and stays right
 * while you rename things.
 *
 * @type {vscode.CodeLensProvider}
 */
const routeLens = {
  provideCodeLenses(doc) {
    if (!config().get('showRoutePath', true)) return [];
    const route = routeFor(doc.uri.path);
    if (!route) return [];

    // Above the component if there is one, so the lens sits with the thing it
    // describes rather than on the license header.
    const text = doc.getText();
    const declaration = /^\s*Component\s+[A-Za-z_$][\w$]*\s*\(/m.exec(text);
    const line = declaration
      ? doc.positionAt(declaration.index).line
      : 0;

    return [new vscode.CodeLens(new vscode.Range(line, 0, line, 0), {
      title: routeLabel(route),
      tooltip: `Generated from ${vscode.workspace.asRelativePath(doc.uri)}. `
        + 'Click to copy the path.',
      command: 'dartx.copyRoutePath',
      arguments: [route.url],
    })];
  },
};

// ---------------------------------------------------------------------------
// Activation
// ---------------------------------------------------------------------------

/** @param {vscode.ExtensionContext} context */
function activate(context) {
  output = vscode.window.createOutputChannel('dartx');
  diagnostics = vscode.languages.createDiagnosticCollection('dartx');
  context.subscriptions.push(output, diagnostics);

  const runOnType = () => config().get('diagnostics.runOn', 'type') === 'type';

  applyGeneratedFileVisibility().catch((e) =>
      output.appendLine(`[dartx] could not apply file visibility: ${e}`));

  // The language server owns diagnostics when it is running. Running both would
  // double every squiggle, and the markup errors are a strict subset.
  //
  // Nothing falls back until the server has *decided*. Starting it takes a
  // moment, and a file opened in that moment used to spawn the old checker,
  // which was then killed the instant the server came up — reported to the
  // person as "the dartx transpiler could not be run", which is alarming and
  // untrue.
  let usingLanguageServer = false;
  const languageServerSettled = startLanguageServer(context).then((started) => {
    usingLanguageServer = started;
    if (!started) return false;
    diagnostics.clear();
    for (const server of servers.values()) server.dispose();
    servers.clear();
    return true;
  });

  /** @param {vscode.TextDocument} doc */
  const checkIfFallback = async (doc) => {
    await languageServerSettled;
    if (!usingLanguageServer) check(doc);
  };

  languageServerSettled.then((started) => {
    if (!started) vscode.workspace.textDocuments.forEach(check);
  });

  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument(checkIfFallback),
    vscode.workspace.onDidSaveTextDocument(checkIfFallback),
    vscode.workspace.onDidCloseTextDocument((doc) => diagnostics.delete(doc.uri)),
    vscode.workspace.onDidChangeTextDocument((event) => {
      autoCloseTag(event);
      autoCompleteClosingTag(event);
      if (!usingLanguageServer && runOnType()) scheduleCheck(event.document);
    }),
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (!event.affectsConfiguration('dartx')) return;
      if (event.affectsConfiguration('dartx.hideGeneratedFiles')) {
        applyGeneratedFileVisibility().catch((e) =>
      output.appendLine(`[dartx] could not apply file visibility: ${e}`));
      }
      for (const server of servers.values()) server.dispose();
      servers.clear();
      if (!usingLanguageServer) vscode.workspace.textDocuments.forEach(check);
    }),
    vscode.commands.registerCommand('dartx.build', () =>
      runInTerminal('dart run build_runner build --delete-conflicting-outputs')),
    vscode.commands.registerCommand('dartx.watch', () =>
      runInTerminal('dart run build_runner watch --delete-conflicting-outputs')),
    vscode.commands.registerCommand('dartx.compileFile', compileFile),
    vscode.commands.registerCommand('dartx.showReferences', showReferences),
    vscode.commands.registerCommand('dartx.copyRoutePath', async (path) => {
      await vscode.env.clipboard.writeText(path);
      vscode.window.setStatusBarMessage(`dartx: copied ${path}`, 2000);
    }),
    vscode.languages.registerCodeLensProvider(
      [{ language: 'dartx' }, { language: 'dart', pattern: '**/routes/**' }],
      routeLens),
    vscode.commands.registerCommand('dartx.openGenerated', openGenerated),
    vscode.commands.registerCommand('dartx.restartServer', async () => {
      for (const server of servers.values()) server.dispose();
      servers.clear();
      if (client) {
        await client.stop();
        client = null;
      }
      usingLanguageServer = await startLanguageServer(context);
      if (!usingLanguageServer) vscode.workspace.textDocuments.forEach(check);
    }),
    vscode.languages.registerCompletionItemProvider('dartx', {
      provideCompletionItems(doc, position) {
        if (!config().get('suggestTags', true)) return undefined;
        const line = doc.lineAt(position).text.slice(0, position.character);
        if (!/<[A-Za-z]*$/.test(line)) return undefined;
        return HTML_TAGS.map((tag) => {
          const item = new vscode.CompletionItem(tag, vscode.CompletionItemKind.Property);
          item.detail = 'html element';
          return item;
        });
      },
    }, '<'),
  );

}

async function deactivate() {
  for (const server of servers.values()) server.dispose();
  servers.clear();
  if (client) await client.stop();
}

module.exports = { activate, deactivate };
