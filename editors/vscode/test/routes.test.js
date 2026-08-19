// @ts-check
'use strict';

const assert = require('node:assert');
const { test } = require('node:test');
const { routeFor, routeLabel } = require('../routes');

test('a page maps its folder to a URL', () => {
  assert.deepStrictEqual(routeFor('lib/routes/page.dartx'), { kind: 'page', url: '/' });
  assert.deepStrictEqual(routeFor('lib/routes/stats/page.dartx'),
    { kind: 'page', url: '/stats' });
});

test('[id] and [...rest] become the router spellings', () => {
  assert.strictEqual(routeFor('lib/routes/todo/[id]/page.dartx').url, '/todo/:id');
  assert.strictEqual(routeFor('lib/routes/[...rest]/page.dartx').url, '/*');
  assert.strictEqual(routeFor('lib/routes/todo/$id/page.dartx').url, '/todo/:id');
  assert.strictEqual(routeFor('lib/routes/$/page.dartx').url, '/*');
});

test('a (group) folder adds no segment', () => {
  assert.strictEqual(routeFor('lib/routes/(marketing)/about/page.dartx').url, '/about');
});

test('the deepest routes/ directory wins', () => {
  assert.strictEqual(
    routeFor('example/routes/app/src/routes/stats/page.dartx').url, '/stats');
});

test('a file the conventions do not name is not a route', () => {
  assert.strictEqual(routeFor('lib/routes/components/card.dartx'), null);
  assert.strictEqual(routeFor('lib/pages/page.dartx'), null);
  assert.strictEqual(routeFor('page.dartx'), null);
});

test('layout and error say what they cover', () => {
  assert.strictEqual(routeLabel(routeFor('lib/routes/layout.dartx')),
    'Layout  wraps /*');
  assert.strictEqual(routeLabel(routeFor('lib/routes/todo/[id]/layout.dartx')),
    'Layout  wraps /todo/:id/*');
  assert.strictEqual(routeLabel(routeFor('lib/routes/todo/[id]/error.dartx')),
    'Error boundary  for /todo/:id');
  assert.strictEqual(routeLabel(routeFor('lib/routes/stats/page.dartx')),
    'Route  /stats');
});
