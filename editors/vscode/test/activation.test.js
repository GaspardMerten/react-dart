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
const { spawnSync } = require('node:child_process');

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

/**
 * Strips VS Code snippet placeholders down to the text they insert:
 * `${1:Name}` -> `Name`, `$0` -> ``.
 */
function expand(body) {
  return (Array.isArray(body) ? body.join('\n') : body)
    .replace(/\$\{\d+:([^}]*)\}/g, '$1')
    .replace(/\$\{\d+\}/g, '')
    .replace(/\$\d+/g, '');
}

test('the component snippets teach the current way to declare one', () => {
  // A compile check cannot catch this: `VNode Name(Props props)` still works,
  // it is simply not how you write a component any more. Snippets are the
  // first thing a newcomer copies, so the form they teach is load-bearing.
  const snippets = require(path.join(ROOT, 'snippets/dartx.json'));
  for (const [name, snippet] of Object.entries(snippets)) {
    if (!snippet.prefix.startsWith('comp')) continue;
    const source = expand(snippet.body);
    assert.match(source, /^(@\w+\n)?Component \w+\(/,
      `${name} should declare a component with the Component return type`);
    assert.doesNotMatch(source, /\(Props props\)/,
      `${name} still teaches the untyped props map`);
  }
});

test('every component snippet compiles against the current dartx', (t) => {
  // The point of this test is staleness, not syntax: snippets are the first
  // thing a newcomer sees, and they used to teach `VNode Name(Props props)`
  // for a full release after the framework had moved to `Component Name({…})`.
  // Well-formed JSON cannot catch that; the compiler can.
  const dart = spawnSync('dart', ['--version'], { encoding: 'utf8' });
  if (dart.error) return t.skip('dart is not on PATH');

  // Selected by prefix, deliberately. Selecting by what the body *looks* like
  // would let a stale snippet drop silently out of the check — which is the
  // one failure this test exists to catch.
  const snippets = require(path.join(ROOT, 'snippets/dartx.json'));
  const declarations = Object.entries(snippets)
    .filter(([, s]) => s.prefix.startsWith('comp'));

  assert.ok(declarations.length >= 4,
    `expected the component snippets, found ${declarations.length}`);

  const requests = declarations
    .map(([name, s]) => JSON.stringify({ uri: `${name}.dartx`, source: expand(s.body) }))
    .join('\n');

  const result = spawnSync(
    'dart', ['run', 'reactx:dartx', '--server'],
    { cwd: path.join(ROOT, '../..'), input: requests + '\n', encoding: 'utf8' });

  const answers = result.stdout.trim().split('\n').filter(Boolean).map(JSON.parse);
  assert.equal(answers.length, declarations.length, result.stderr);
  for (const answer of answers) {
    assert.deepEqual(answer.diagnostics, [],
      `${answer.uri} does not compile: ${JSON.stringify(answer.diagnostics)}`);
  }
});
