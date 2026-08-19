// @ts-check
'use strict';

/**
 * Tokenises real `.dartx` snippets with the same engine VS Code uses.
 *
 * The bug this exists to prevent: text between two tags is *not* Dart, and for
 * a long time the grammar let it fall through to the Dart grammar — so the
 * first word of `<h1>Stats</h1>` was coloured like a type. `source.dart` is
 * stubbed here with a grammar that marks every word `stub.dart`, which turns
 * "did this fall through to Dart?" into an assertion.
 */

const assert = require('node:assert');
const { test } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vsctm = require('vscode-textmate');
const oniguruma = require('vscode-oniguruma');

const GRAMMAR = path.join(__dirname, '..', 'syntaxes', 'dartx.tmLanguage.json');

/** Every word is scoped, so falling through to Dart is visible in a test. */
const DART_STUB = {
  scopeName: 'source.dart',
  patterns: [{ match: '[A-Za-z_$][\\w$]*', name: 'stub.dart' }],
};

let registry;

async function tokenize(source) {
  if (!registry) {
    const wasm = fs.readFileSync(
      path.join(__dirname, '..', 'node_modules', 'vscode-oniguruma', 'release', 'onig.wasm'));
    await oniguruma.loadWASM(wasm.buffer);
    registry = new vsctm.Registry({
      onigLib: Promise.resolve({
        createOnigScanner: (p) => new oniguruma.OnigScanner(p),
        createOnigString: (s) => new oniguruma.OnigString(s),
      }),
      loadGrammar: (scope) => Promise.resolve(
        scope === 'source.dart'
          ? DART_STUB
          : vsctm.parseRawGrammar(fs.readFileSync(GRAMMAR, 'utf8'), GRAMMAR)),
    });
  }
  const grammar = await registry.loadGrammar('source.dartx');
  const out = [];
  let state = vsctm.INITIAL;
  for (const line of source.split('\n')) {
    const result = grammar.tokenizeLine(line, state);
    for (const token of result.tokens) {
      const text = line.slice(token.startIndex, token.endIndex);
      if (text.trim()) out.push({ text, scopes: token.scopes });
    }
    state = result.ruleStack;
  }
  return out;
}

/** The scopes of the first token whose text is exactly [text]. */
function scopesOf(tokens, text) {
  const token = tokens.find((t) => t.text === text);
  assert.ok(token, `no token "${text}" in ${JSON.stringify(tokens.map((t) => t.text))}`);
  return token.scopes;
}

test('text between tags is not Dart', async () => {
  const tokens = await tokenize('Component P() => <h1>Stats</h1>;');
  assert.ok(!scopesOf(tokens, 'Stats').some((s) => s === 'stub.dart'),
    'the text child fell through to the Dart grammar');
  assert.ok(scopesOf(tokens, 'Stats').includes('meta.tag.host.dartx'));
  // …while the Dart around it still is.
  assert.ok(scopesOf(tokens, 'Component').includes('stub.dart'));
});

test('an apostrophe in text does not open a Dart string', async () => {
  const tokens = await tokenize("<p>it's fine</p>\nfinal after = 1;");
  assert.ok(scopesOf(tokens, 'after').includes('stub.dart'),
    'the apostrophe swallowed the rest of the file');
});

test('a nested element closes itself, not its parent', async () => {
  const tokens = await tokenize('<div><span>a</span>b</div>\nfinal after = 1;');
  assert.ok(scopesOf(tokens, 'b').includes('meta.tag.host.dartx'));
  assert.ok(!scopesOf(tokens, 'b').includes('stub.dart'));
  assert.ok(scopesOf(tokens, 'after').includes('stub.dart'));
});

test('an expression child is Dart again', async () => {
  const tokens = await tokenize('<div>{state.count}</div>');
  assert.ok(scopesOf(tokens, 'state').includes('stub.dart'));
});

test('a component name is scoped as a component, in both tags', async () => {
  const tokens = await tokenize('<StatCard label="Done" />');
  assert.ok(scopesOf(tokens, 'StatCard').includes('support.class.component.dartx'));
  assert.ok(scopesOf(tokens, 'label').includes('entity.other.attribute-name.dartx'));

  const paired = await tokenize('<Card>hi</Card>');
  assert.strictEqual(
    paired.filter((t) => t.scopes.includes('support.class.component.dartx')).length, 2);
  assert.ok(!scopesOf(paired, 'hi').includes('stub.dart'));
});

test('attribute names do not leak into the children', async () => {
  const tokens = await tokenize('<div class="a">label</div>');
  assert.ok(!scopesOf(tokens, 'label').includes('entity.other.attribute-name.dartx'));
});

test('a void element needs no closing tag', async () => {
  const tokens = await tokenize('<div><br>after</div>\nfinal x = 1;');
  assert.ok(!scopesOf(tokens, 'after').includes('stub.dart'));
  assert.ok(scopesOf(tokens, 'x').includes('stub.dart'));
});

test('Dart generics are still Dart', async () => {
  for (const source of [
    'final names = <String>[];',
    'final m = <String, int>{};',
    'Future<List<Todo>> load() async => [];',
    'final f = <void Function()>[];',
    'final s = <Todo>{};',
  ]) {
    const tokens = await tokenize(source);
    assert.ok(
      !tokens.some((t) => t.scopes.some((s) => s.startsWith('meta.tag.'))),
      `${source} was read as markup`);
  }
});

test('a fragment groups children without an element', async () => {
  const tokens = await tokenize('<><h1>a</h1>b</>\nfinal after = 1;');
  assert.ok(scopesOf(tokens, 'b').includes('meta.tag.fragment.dartx'));
  assert.ok(scopesOf(tokens, 'after').includes('stub.dart'));
});

test('an arrow inside an attribute does not end the tag', async () => {
  const tokens = await tokenize('<button onClick={() => add()}>Add</button>');
  assert.ok(scopesOf(tokens, 'add').includes('stub.dart'));
  assert.ok(!scopesOf(tokens, 'Add').includes('stub.dart'));
});

test('a custom element with a dash owns its children', async () => {
  const tokens = await tokenize('<my-widget>text</my-widget>\nfinal after = 1;');
  assert.ok(!scopesOf(tokens, 'text').includes('stub.dart'));
  assert.ok(scopesOf(tokens, 'after').includes('stub.dart'));
});

test('a tag inside a doc comment is prose', async () => {
  const tokens = await tokenize('/// A tag `<select>`, and a submit.\nfinal after = 1;');
  assert.ok(scopesOf(tokens, '/// A tag `<select>`, and a submit.')
    .includes('comment.block.documentation.dart'));
  assert.ok(scopesOf(tokens, 'after').includes('stub.dart'));
});

test('a URL in a string is a string', async () => {
  const tokens = await tokenize("final url = 'http://example.com';\nfinal after = 1;");
  assert.ok(scopesOf(tokens, 'after').includes('stub.dart'),
    'the // in the URL was read as a comment');
});

test('markup inside a string is a string', async () => {
  const tokens = await tokenize("final s = '<div>';\nfinal after = 1;");
  assert.ok(!tokens.some((t) => t.scopes.some((x) => x.startsWith('meta.tag.'))));
  assert.ok(scopesOf(tokens, 'after').includes('stub.dart'));
});

test('the grammar knows the same tags the extension does', async () => {
  const grammar = JSON.parse(fs.readFileSync(GRAMMAR, 'utf8'));
  const named = (pattern) => new Set((pattern.match(/\(\?:([a-z|0-9]+)\)/g) || [])
    .flatMap((g) => g.slice(3, -1).split('|')));

  const extension = fs.readFileSync(path.join(__dirname, '..', 'extension.js'), 'utf8');
  const tags = fs.readFileSync(path.join(__dirname, '..', 'tags.js'), 'utf8');
  const listOf = (source, re) => new Set(
    source.match(re)[1].replace(/\s/g, '').split(',').filter(Boolean)
      .map((s) => s.replace(/'/g, '')));

  const html = listOf(extension, /const HTML_TAGS = \[([\s\S]*?)\];/);
  const voids = listOf(tags, /const VOID_ELEMENTS = new Set\(\[([\s\S]*?)\]\)/);

  const inVoidRule = named(grammar.repository['element-void'].begin);
  assert.deepStrictEqual([...inVoidRule].sort(), [...voids].sort(),
    'element-void drifted from VOID_ELEMENTS in tags.js');

  const inHostRule = named(grammar.repository['element-host'].begin);
  const expected = [...html].filter((t) => !voids.has(t)).sort();
  assert.deepStrictEqual([...inHostRule].sort(), expected,
    'element-host drifted from HTML_TAGS in extension.js');
});

test('every .dartx file in the repo closes its markup', async () => {
  const root = path.join(__dirname, '..', '..', '..');
  /** @param {string} dir @returns {string[]} */
  const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    if (e.name.startsWith('.') || e.name === 'node_modules') return [];
    const full = path.join(dir, e.name);
    return e.isDirectory() ? walk(full) : e.name.endsWith('.dartx') ? [full] : [];
  });

  const files = walk(root);
  assert.ok(files.length > 5, 'expected to find the example .dartx files');
  for (const file of files) {
    const source = fs.readFileSync(file, 'utf8');
    const tokens = await tokenize(source);
    const last = tokens[tokens.length - 1];
    // A file that ends inside a `meta.tag` scope has an element the grammar
    // never closed — the failure mode that colours the rest of the buffer.
    assert.ok(
      !last.scopes.some((s) => s.startsWith('meta.tag.')),
      `${path.relative(root, file)} ends inside markup: ${last.text} ${last.scopes}`);
  }
});
