// @ts-check
'use strict';

/**
 * Proves the extension loads outside VS Code, by stubbing just enough of the
 * API surface it touches. It catches the two mistakes that are otherwise only
 * visible after installing: a typo in the activation path, and a command
 * declared in package.json but never registered.
 *
 * Run with: node --test (from editors/vscode)
 */

const test = require('node:test');
const assert = require('node:assert');
const Module = require('node:module');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');

/** @returns {{registered: Set<string>, restore: () => void}} */
function stubVscode() {
  const registered = new Set();
  const disposable = { dispose() {} };
  const noop = () => disposable;

  const vscode = {
    window: {
      createOutputChannel: () => ({
        appendLine() {}, append() {}, show() {}, dispose() {},
      }),
      showWarningMessage: () => Promise.resolve(undefined),
      createTerminal: () => ({ show() {}, sendText() {} }),
      activeTextEditor: undefined,
    },
    languages: {
      createDiagnosticCollection: () => ({ set() {}, delete() {}, dispose() {} }),
      registerCompletionItemProvider: noop,
    },
    workspace: {
      getConfiguration: () => ({ get: (_key, fallback) => fallback }),
      onDidOpenTextDocument: noop,
      onDidSaveTextDocument: noop,
      onDidCloseTextDocument: noop,
      onDidChangeTextDocument: noop,
      onDidChangeConfiguration: noop,
      getWorkspaceFolder: () => undefined,
      textDocuments: [],
      workspaceFolders: undefined,
    },
    commands: {
      registerCommand: (/** @type {string} */ id) => {
        registered.add(id);
        return disposable;
      },
    },
    Uri: { file: (/** @type {string} */ p) => ({ fsPath: p }) },
    Range: class {},
    Position: class {},
    Selection: class {},
    Diagnostic: class {},
    DiagnosticSeverity: { Error: 0 },
    CompletionItem: class {},
    CompletionItemKind: { Property: 0 },
    ViewColumn: { Beside: 2 },
  };

  const load = Module._load;
  Module._load = (request, ...rest) =>
    request === 'vscode' ? vscode : load(request, ...rest);

  return { registered, restore: () => { Module._load = load; } };
}

test('the extension activates and registers every declared command', () => {
  const { registered, restore } = stubVscode();
  try {
    const extension = require(path.join(ROOT, 'extension.js'));
    extension.activate({ subscriptions: [] });
    extension.deactivate();

    const declared = require(path.join(ROOT, 'package.json'))
      .contributes.commands.map((/** @type {{command: string}} */ c) => c.command);
    assert.ok(declared.length > 0, 'package.json declares no commands');
    for (const id of declared) {
      assert.ok(registered.has(id), `command not registered: ${id}`);
    }
  } finally {
    restore();
  }
});

test('the grammar, language config and snippets are well-formed JSON', () => {
  const grammar = require(path.join(ROOT, 'syntaxes/dartx.tmLanguage.json'));
  assert.equal(grammar.scopeName, 'source.dartx');

  const manifest = require(path.join(ROOT, 'package.json'));
  assert.equal(manifest.contributes.grammars[0].scopeName, grammar.scopeName);
  assert.deepEqual(manifest.contributes.languages[0].extensions, ['.dartx']);

  // Every pattern the grammar references must exist in the repository.
  const names = new Set(Object.keys(grammar.repository));
  /** @param {any} node */
  const walk = (node) => {
    if (Array.isArray(node)) return node.forEach(walk);
    if (!node || typeof node !== 'object') return;
    if (typeof node.include === 'string' && node.include.startsWith('#')) {
      assert.ok(names.has(node.include.slice(1)),
        `grammar references missing pattern ${node.include}`);
    }
    Object.values(node).forEach(walk);
  };
  walk(grammar);

  require(path.join(ROOT, 'language-configuration.json'));
  require(path.join(ROOT, 'snippets/dartx.json'));
});
