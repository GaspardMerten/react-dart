// @ts-check
'use strict';

/**
 * Tag reasoning for the dartx extension, kept free of the `vscode` module so it
 * can be exercised with `node --test`.
 *
 * Everything here works on "the text before the cursor", which is all the
 * editor gives us at the moment a key is pressed. A regex over that text is not
 * enough — `onClick={() => f()}` and `class={a > b ? 'x' : 'y'}` both put a `>`
 * inside a tag — so tags are found with a small scanner that knows about
 * strings and `{...}` expressions, the same two things the transpiler skips.
 */

/** HTML elements that never get a closing tag. */
const VOID_ELEMENTS = new Set([
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta',
  'param', 'source', 'track', 'wbr',
]);

/**
 * Names that are almost certainly a Dart type argument rather than a component,
 * so `final names = <String>` should not sprout a `</String>`. The transpiler
 * makes this call properly (it can see what follows the `>`); here we only have
 * the text typed so far, so a short list of core types earns its keep.
 */
const DART_TYPE_LITERALS = new Set([
  'String', 'int', 'double', 'num', 'bool', 'Object', 'Never', 'Null',
  'List', 'Map', 'Set', 'Iterable', 'Future', 'Stream', 'Function', 'Symbol',
  'DateTime', 'Duration', 'Uri', 'VNode', 'Props',
]);

/** Matches a tag name (and a leading `/`) immediately after a `<`. */
const TAG_HEAD = /(\/?)([A-Za-z_$][-\w$.:]*)/y;

/**
 * @typedef {object} Tag
 * @property {string} name
 * @property {boolean} closing     `</div>`
 * @property {boolean} selfClosing `<br />`
 * @property {number} end          offset just past the `>`
 */

/**
 * Finds every complete tag in `text`, in order. Incomplete trailing markup is
 * ignored, which is the normal state of a file being typed into.
 *
 * @param {string} text
 * @returns {Tag[]}
 */
function scanTags(text) {
  /** @type {Tag[]} */
  const tags = [];
  let i = 0;

  while (i < text.length) {
    if (text[i] !== '<') {
      i++;
      continue;
    }
    TAG_HEAD.lastIndex = i + 1;
    const head = TAG_HEAD.exec(text);
    if (!head) {
      i++;
      continue;
    }

    let j = TAG_HEAD.lastIndex;
    let depth = 0;
    /** @type {string | null} */
    let quote = null;
    let closed = false;
    let selfClosing = false;

    while (j < text.length) {
      const c = text[j];
      if (quote) {
        if (c === quote) quote = null;
      } else if (c === '"' || c === "'") {
        quote = c;
      } else if (c === '{') {
        depth++;
      } else if (c === '}') {
        if (depth > 0) depth--;
      } else if (depth === 0 && c === '>') {
        selfClosing = text[j - 1] === '/';
        closed = true;
        j++;
        break;
      } else if (depth === 0 && c === '<') {
        break; // malformed: a new tag started before this one ended
      }
      j++;
    }

    if (closed) {
      tags.push({
        name: head[2],
        closing: head[1] === '/',
        selfClosing,
        end: j,
      });
      i = j;
    } else {
      i++;
    }
  }

  return tags;
}

/**
 * Given the text up to and including a just-typed `>`, returns the tag name to
 * close, or null when nothing should be inserted.
 *
 * Returns null for closing tags, self-closing tags, void elements, and any `>`
 * that turns out to belong to an expression rather than to a tag.
 *
 * @param {string} before
 * @returns {string | null}
 */
function tagToClose(before) {
  if (!before.endsWith('>')) return null;

  const tags = scanTags(before);
  const last = tags[tags.length - 1];
  // The tag has to end exactly at the `>` that was just typed; otherwise the
  // character closed something else (a comparison, a fat arrow, a generic).
  if (!last || last.end !== before.length) return null;
  if (last.closing || last.selfClosing) return null;
  if (VOID_ELEMENTS.has(last.name)) return null;
  if (DART_TYPE_LITERALS.has(last.name)) return null;
  return last.name;
}

/**
 * Walks every tag in `text` and returns the innermost one still open — what a
 * freshly typed `</` should complete to.
 *
 * @param {string} text
 * @returns {string | null}
 */
function innermostOpenTag(text) {
  /** @type {string[]} */
  const stack = [];
  for (const tag of scanTags(text)) {
    if (tag.closing) {
      // Tolerate mismatched markup: unwind to the matching name if there is
      // one, and otherwise ignore the stray closing tag.
      const at = stack.lastIndexOf(tag.name);
      if (at >= 0) stack.length = at;
    } else if (!tag.selfClosing && !VOID_ELEMENTS.has(tag.name)) {
      stack.push(tag.name);
    }
  }
  return stack.length ? stack[stack.length - 1] : null;
}

module.exports = {
  VOID_ELEMENTS,
  DART_TYPE_LITERALS,
  scanTags,
  tagToClose,
  innermostOpenTag,
};
