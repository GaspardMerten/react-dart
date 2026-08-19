/// Rewriting a stylesheet so it can only reach one component's markup.
///
/// The technique is the one Vue settled on, and for the reason Vue settled on
/// it: every element the component renders carries a unique attribute, and
/// every selector in its stylesheet is required to end at an element with that
/// attribute. `.card` becomes `.card[data-rx-a1b2]`.
///
/// The alternative — renaming classes, as CSS Modules does — cannot work here.
/// A class in dartx is frequently an expression:
///
/// ```dart
/// <div class={todo.done ? 'todo is-done' : 'todo'}>
/// ```
///
/// Renaming would mean rewriting arbitrary Dart that computes strings at
/// runtime, which is not something a preprocessor can do. An attribute is
/// added to the element rather than to the class, so it does not care how the
/// class was arrived at.
///
/// What this deliberately does not do is parse CSS. It scans for the structure
/// it needs — selector lists, blocks, at-rules — and leaves declarations
/// untouched. That is enough to place an attribute, and it means a stylesheet
/// using syntax this does not know about still passes through intact.
library;

/// Selectors inside these at-rules are not selectors.
///
/// `@keyframes` holds percentages and `from`/`to`; `@font-face` and `@page`
/// hold declarations. Appending an attribute to any of them produces CSS that
/// silently does nothing.
const _opaqueAtRules = {
  'keyframes',
  '-webkit-keyframes',
  '-moz-keyframes',
  'font-face',
  'page',
  'counter-style',
  'property',
  'viewport',
};

/// Returns [css] with every selector confined to elements carrying
/// [attribute], which should be an attribute name such as `data-rx-a1b2`.
String scopeCss(String css, String attribute) =>
    _scopeBlock(css, '[$attribute]');

String _scopeBlock(String css, String suffix) {
  final out = StringBuffer();
  var i = 0;
  var chunkStart = 0;

  while (i < css.length) {
    final c = css[i];

    // Comments and strings are copied through: a `{` inside either is not a
    // block, and a selector inside a comment is not a selector.
    if (css.startsWith('/*', i)) {
      final end = css.indexOf('*/', i + 2);
      i = end < 0 ? css.length : end + 2;
      continue;
    }
    if (c == '"' || c == "'") {
      i = _skipString(css, i);
      continue;
    }

    if (c == '{') {
      final selector = css.substring(chunkStart, i);
      final blockEnd = _matchingBrace(css, i);
      final body = css.substring(i + 1, blockEnd);

      if (selector.trimLeft().startsWith('@')) {
        final name = _atRuleName(selector);
        out
          ..write(selector)
          ..write('{')
          // A conditional group (`@media`, `@supports`) contains rules, so its
          // contents are scoped. Everything else contains something that only
          // looks like one.
          ..write(_opaqueAtRules.contains(name) ? body : _scopeBlock(body, suffix))
          ..write('}');
      } else {
        out
          ..write(_scopeSelectorList(selector, suffix))
          ..write('{')
          ..write(body)
          ..write('}');
      }

      i = blockEnd + 1;
      chunkStart = i;
      continue;
    }
    i++;
  }

  out.write(css.substring(chunkStart));
  return out.toString();
}

/// `.a, .b > .c` -> `.a[…], .b > .c[…]`, keeping the original spacing.
String _scopeSelectorList(String selectors, String suffix) {
  final parts = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < selectors.length; i++) {
    final c = selectors[i];
    if (c == '(' || c == '[') depth++;
    if (c == ')' || c == ']') depth--;
    if (c == ',' && depth == 0) {
      parts.add(selectors.substring(start, i));
      start = i + 1;
    }
  }
  parts.add(selectors.substring(start));

  return [for (final part in parts) _scopeOne(part, suffix)].join(',');
}

/// Appends [suffix] to the last compound selector, before any pseudo.
///
/// `.card .title:hover` -> `.card .title[…]:hover`. The attribute belongs to
/// the element the rule finally selects, and a pseudo-class applies after it.
String _scopeOne(String selector, String suffix) {
  final trimmed = selector.trim();
  if (trimmed.isEmpty) return selector;

  final leading = selector.substring(0, selector.indexOf(trimmed[0]));
  final trailing =
      selector.substring(leading.length + trimmed.length);

  // Where the last compound selector begins: after the last combinator that is
  // not inside brackets or parentheses.
  var depth = 0;
  var compoundStart = 0;
  for (var i = 0; i < trimmed.length; i++) {
    final c = trimmed[i];
    if (c == '(' || c == '[') depth++;
    if (c == ')' || c == ']') depth--;
    if (depth != 0) continue;
    if (c == ' ' || c == '>' || c == '+' || c == '~') compoundStart = i + 1;
  }

  final compound = trimmed.substring(compoundStart);
  // `::before` is not a place to insert an attribute, and neither is `:hover`.
  var insertAt = compound.length;
  var bracket = 0;
  for (var i = 0; i < compound.length; i++) {
    final c = compound[i];
    if (c == '(' || c == '[') bracket++;
    if (c == ')' || c == ']') bracket--;
    if (bracket == 0 && c == ':') {
      insertAt = i;
      break;
    }
  }

  final scoped = compound.substring(0, insertAt) +
      suffix +
      compound.substring(insertAt);
  return '$leading${trimmed.substring(0, compoundStart)}$scoped$trailing';
}

String _atRuleName(String selector) {
  final trimmed = selector.trimLeft().substring(1);
  final end = trimmed.indexOf(RegExp(r'[\s({]'));
  return (end < 0 ? trimmed : trimmed.substring(0, end)).toLowerCase();
}

int _matchingBrace(String css, int open) {
  var depth = 0;
  var i = open;
  while (i < css.length) {
    if (css.startsWith('/*', i)) {
      final end = css.indexOf('*/', i + 2);
      i = end < 0 ? css.length : end + 2;
      continue;
    }
    final c = css[i];
    if (c == '"' || c == "'") {
      i = _skipString(css, i);
      continue;
    }
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return css.length - 1;
}

int _skipString(String css, int start) {
  final quote = css[start];
  var i = start + 1;
  while (i < css.length) {
    if (css[i] == r'\') {
      i += 2;
      continue;
    }
    if (css[i] == quote) return i + 1;
    i++;
  }
  return i;
}

/// A short, stable scope id for [uri].
///
/// Derived from the path so it does not move when the file's contents change —
/// a stylesheet that reshuffles should not invalidate every cached page.
String scopeIdFor(String uri) {
  var hash = 0x811c9dc5;
  for (final unit in uri.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0').substring(0, 6);
}


/// Whether [source] declares a `@scoped` stylesheet.
///
/// Checked with a regex rather than a parse because the answer is needed
/// *before* the file is compiled — every host element in it has to be stamped
/// with the scope attribute as it is emitted.
bool hasScopedStyles(String source) => _scopedMarker.hasMatch(source);

final _scopedMarker = RegExp(r'@scoped\b');
