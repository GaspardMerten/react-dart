// @ts-check
'use strict';

/** Run with: node --test (from editors/vscode) */

const test = require('node:test');
const assert = require('node:assert');

const { tagToClose, innermostOpenTag } = require('../tags');

test('tagToClose closes a plain opening tag', () => {
  assert.equal(tagToClose('  return <div>'), 'div');
  assert.equal(tagToClose('<section class="calc">'), 'section');
  assert.equal(tagToClose('<Counter>'), 'Counter');
  assert.equal(tagToClose('<widgets.Card>'), 'widgets.Card');
});

test('tagToClose leaves self-closing and void elements alone', () => {
  assert.equal(tagToClose('<br />'), null);
  assert.equal(tagToClose('<Counter />'), null);
  assert.equal(tagToClose('<img src="a.png">'), null);
  assert.equal(tagToClose('<input value={x}>'), null);
});

test('tagToClose ignores the `>` in a fat arrow', () => {
  assert.equal(tagToClose('<button onClick={() =>'), null);
});

test('tagToClose waits for the attribute expression to be balanced', () => {
  // Mid-expression: the `>` belongs to a comparison, not to the tag.
  assert.equal(tagToClose('<div class={a >'), null);
  assert.equal(tagToClose('<div class={a > b ? "x" : "y"}>'), 'div');
});

test('tagToClose does not close a Dart type argument list', () => {
  // `final names = <String>[];` — the `>` ends type arguments, not a tag.
  assert.equal(tagToClose('final names = <String>'), null);
  assert.equal(tagToClose('final m = <Map>'), null);
  // A component with the same shape still closes.
  assert.equal(tagToClose('final v = <Counter>'), 'Counter');
});

test('tagToClose handles a tag split over several lines', () => {
  assert.equal(
    tagToClose('<button\n  key={k.label}\n  onClick={() => go(k)}\n>'),
    'button');
});

test('tagToClose ignores text that is not a tag', () => {
  assert.equal(tagToClose('final ok = a > b;'), null);
  assert.equal(tagToClose('=>'), null);
  assert.equal(tagToClose(''), null);
});

test('innermostOpenTag finds the tag a `</` should close', () => {
  assert.equal(innermostOpenTag('<div><span>'), 'span');
  assert.equal(innermostOpenTag('<div><span></span>'), 'div');
  assert.equal(innermostOpenTag('<div></div>'), null);
  assert.equal(innermostOpenTag(''), null);
});

test('innermostOpenTag skips self-closing and void elements', () => {
  assert.equal(innermostOpenTag('<ul><li /><br>'), 'ul');
  assert.equal(innermostOpenTag('<form><input value={x} />'), 'form');
});

test('innermostOpenTag survives mismatched markup', () => {
  assert.equal(innermostOpenTag('<div></span>'), 'div');
  assert.equal(innermostOpenTag('</p>'), null);
});

test('innermostOpenTag is not confused by attributes containing braces', () => {
  assert.equal(
    innermostOpenTag('<div class="a"><button onClick={() => f()}>'),
    'button');
});
