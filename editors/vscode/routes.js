// @ts-check
'use strict';

/**
 * The file-system routing conventions, as the editor sees them.
 *
 * This is the same mapping `lib/src/routes/file_routes.dart` performs when it
 * generates the route table; it exists again here so a page can show its own
 * URL without waiting on a build. Keep the two in step — `test/routes.test.js`
 * checks the interesting cases, and the Dart side has its own.
 */

/** The three file names a routes directory recognises. */
const ROUTE_FILES = /^(page|layout|error)\.dartx?$/;

/**
 * `[id]` and `$id` capture a parameter, `[...rest]` and a bare `$` are the
 * catch-all, and a `(group)` folder groups files without adding a segment.
 *
 * @param {string} segment
 * @returns {string[]}
 */
function segmentPath(segment) {
  if (segment.startsWith('(') && segment.endsWith(')')) return [];
  if (segment.startsWith('[...') && segment.endsWith(']')) return ['*'];
  if (segment.startsWith('[') && segment.endsWith(']')) {
    return [':' + segment.slice(1, -1)];
  }
  if (segment === '$') return ['*'];
  if (segment.startsWith('$')) return [':' + segment.slice(1)];
  return [segment];
}

/**
 * What [filePath] routes to, or `null` if it is not a route file.
 *
 * The routes directory is found by name: the deepest `routes/` in the path
 * wins, so `lib/routes/…` and `example/app/src/routes/…` both work without
 * configuration.
 *
 * @param {string} filePath a path with `/` separators
 * @returns {{kind: 'page'|'layout'|'error', url: string} | null}
 */
function routeFor(filePath) {
  const parts = filePath.split('/').filter(Boolean);
  const file = parts.pop();
  if (!file) return null;

  const match = ROUTE_FILES.exec(file);
  if (!match) return null;

  const at = parts.lastIndexOf('routes');
  if (at === -1) return null;

  const url = parts.slice(at + 1).flatMap(segmentPath).join('/');
  const kind = /** @type {'page'|'layout'|'error'} */ (match[1]);
  return { kind, url: '/' + url };
}

/**
 * The one-line label a page shows above its component.
 *
 * @param {{kind: 'page'|'layout'|'error', url: string}} route
 * @returns {string}
 */
function routeLabel(route) {
  const suffix = route.url.endsWith('/') ? '' : '/';
  switch (route.kind) {
    case 'page':
      return `Route  ${route.url}`;
    case 'layout':
      return `Layout  wraps ${route.url}${suffix}*`;
    case 'error':
      return `Error boundary  for ${route.url}`;
  }
}

module.exports = { ROUTE_FILES, routeFor, routeLabel, segmentPath };
