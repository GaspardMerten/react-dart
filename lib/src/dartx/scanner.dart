/// Lexical helpers for walking Dart source without parsing it.
///
/// The dartx transpiler is a *preprocessor*: it copies Dart through untouched
/// and only takes over when it finds markup. To do that safely it must know
/// where strings and comments are (so a `<` inside them is never markup), and
/// it must decide whether a given `<` opens an element or is one of Dart's own
/// uses of the character.
library;

/// Characters that may start a Dart identifier.
bool isIdentifierStart(int c) =>
    (c >= 0x41 && c <= 0x5a) || // A-Z
    (c >= 0x61 && c <= 0x7a) || // a-z
    c == 0x5f || // _
    c == 0x24; // $

/// Characters that may continue a Dart identifier.
bool isIdentifierPart(int c) =>
    isIdentifierStart(c) || (c >= 0x30 && c <= 0x39); // 0-9

bool isWhitespace(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == 0x0c;

/// Keywords after which an expression may begin, so `<` there is markup.
const _expressionKeywords = {
  'return',
  'yield',
  'await',
  'throw',
  'else',
  'case',
  'in',
  'do',
  'when',
};

/// Lowercase names that are types rather than host-element tags, so
/// `<int>[]` reads as a typed literal and `<span>[x]</span>` reads as markup.
const _lowercaseTypeNames = {
  'int',
  'double',
  'num',
  'bool',
  'void',
  'dynamic',
  'var',
};

/// Operators/punctuation after which an expression may begin.
const _expressionPunctuation = {
  0x3d, // =
  0x28, // (
  0x2c, // ,
  0x5b, // [
  0x7b, // {
  0x3b, // ;
  0x3a, // :
  0x3f, // ?
  0x21, // !
  0x26, // &
  0x7c, // |
  0x2b, // +
  0x2d, // -
  0x2a, // *
  0x2f, // /
  0x25, // %
  0x5e, // ^
  0x7e, // ~
};

/// True when a `<` at [lt] — given that the last significant character before
/// it is at [prevSignificant] (`-1` for start of input) — sits in expression
/// position, i.e. where a value, not an operator's right-hand side, is
/// expected.
///
/// This is the same judgement call a JSX-aware parser makes; Dart just has a
/// couple more `<` spellings to rule out (`a < b`, `List<String>`).
bool isExpressionPosition(String src, int prevSignificant) {
  if (prevSignificant < 0) return true;
  final c = src.codeUnitAt(prevSignificant);

  // `=>` opens an expression; a bare `>` (`a > b`) does not.
  if (c == 0x3e) {
    return prevSignificant > 0 && src.codeUnitAt(prevSignificant - 1) == 0x3d;
  }
  // `a << b`: the second `<` is an operator, never markup.
  if (c == 0x3c) return false;
  if (_expressionPunctuation.contains(c)) return true;

  if (isIdentifierPart(c)) {
    return _expressionKeywords.contains(_wordEndingAt(src, prevSignificant));
  }
  // A `)` usually ends a value — `f() < 2` is a comparison — but it also ends
  // the header of a collection `for`/`if`, where markup is exactly what comes
  // next: `[for (final x in xs) <li>{x}</li>]`.
  if (c == 0x29) {
    final open = _matchingOpenParen(src, prevSignificant);
    if (open < 0) return false;
    final before = skipWhitespaceBackwards(src, open - 1);
    if (before < 0 || !isIdentifierPart(src.codeUnitAt(before))) return false;
    return const {'for', 'if', 'while'}.contains(_wordEndingAt(src, before));
  }
  // `]`, `}`, a quote or a digit all end a value: `<` after one is an operator.
  return false;
}

/// The identifier ending at [end] (inclusive).
String _wordEndingAt(String src, int end) {
  var start = end;
  while (start > 0 && isIdentifierPart(src.codeUnitAt(start - 1))) {
    start--;
  }
  return src.substring(start, end + 1);
}

/// Index of the first non-whitespace character at or before [i], or `-1`.
int skipWhitespaceBackwards(String src, int i) {
  while (i >= 0 && isWhitespace(src.codeUnitAt(i))) {
    i--;
  }
  return i;
}

/// Given the index of a `)`, returns the index of its `(`, or `-1`.
int _matchingOpenParen(String src, int close) {
  var depth = 0;
  for (var i = close; i >= 0; i--) {
    final c = src.codeUnitAt(i);
    if (c == 0x29) {
      depth++;
    } else if (c == 0x28) {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// True when the `<` at [lt] starts a Dart type-argument list that is part of a
/// literal or a generic invocation — `<String>[]`, `<String, Object?>{}`,
/// `<Foo>(x)` — rather than an element.
///
/// Without this check `final names = <String>[];` would be read as an element
/// named `String`, which is the one place dartx and Dart genuinely collide.
bool looksLikeTypeArguments(String src, int lt) {
  var depth = 0;
  var i = lt;
  while (i < src.length) {
    final c = src.codeUnitAt(i);
    if (c == 0x3c) {
      depth++;
    } else if (c == 0x3e) {
      depth--;
      if (depth == 0) {
        final after = skipWhitespace(src, i + 1);
        if (after >= src.length) return false;
        final next = src.codeUnitAt(after);
        // A type-argument list is only ever followed by a literal or a call.
        if (next != 0x5b && next != 0x7b && next != 0x28) return false;
        if (!_allNamesAreTypes(src.substring(lt + 1, i))) return false;
        // `<Card>{count}</Card>` reaches here — an element whose first child is
        // an expression is indistinguishable from `<Card>{…}` as a type
        // argument plus a set literal, on everything up to this point. A
        // closing tag settles it: a type-argument list is never followed by
        // one, and markup always is.
        return !_hasClosingTag(src, after, src.substring(lt + 1, i));
      }
    } else if (!(isIdentifierPart(c) ||
        isWhitespace(c) ||
        c == 0x2c || // ,
        c == 0x2e || // .
        c == 0x3f || // ?
        // Function types live in type-argument lists too: `<void Function()>[]`
        // is a list of callbacks, not an element called `void`.
        c == 0x28 || // (
        c == 0x29)) {
      // )
      return false;
    }
    i++;
  }
  return false;
}

/// Whether `</name>` appears after [from], for a [name] that is a single plain
/// identifier (the only shape markup can have).
bool _hasClosingTag(String src, int from, String name) {
  final tag = name.trim();
  if (tag.isEmpty) return false;
  for (var i = 0; i < tag.length; i++) {
    if (!isIdentifierPart(tag.codeUnitAt(i)) && tag.codeUnitAt(i) != 0x2e) {
      return false; // `int, String`, `void Function()` — not a tag name
    }
  }
  return src.indexOf('</$tag>', from) >= 0;
}

bool _allNamesAreTypes(String inner) {
  final names = RegExp(r'[A-Za-z_$][A-Za-z0-9_$]*').allMatches(inner);
  if (names.isEmpty) return false;
  for (final m in names) {
    final name = m.group(0)!;
    // Private and generated types keep their leading `_`/`$`: `<_Key>[…]`.
    final bare = name.replaceFirst(RegExp(r'^[_$]+'), '');
    if (bare.isEmpty) return false;
    final first = bare.codeUnitAt(0);
    final isUpper = first >= 0x41 && first <= 0x5a;
    if (!isUpper && !_lowercaseTypeNames.contains(bare)) return false;
  }
  return true;
}

/// Returns the index of the first non-whitespace character at or after [i].
int skipWhitespace(String src, int i) {
  while (i < src.length && isWhitespace(src.codeUnitAt(i))) {
    i++;
  }
  return i;
}

/// Returns the index just past the whitespace and comments starting at [i],
/// stopping at [limit] (defaults to the end of [src]).
int skipWhitespaceAndComments(String src, int i, [int? limit]) {
  final end = limit ?? src.length;
  while (i < end) {
    final c = src.codeUnitAt(i);
    if (isWhitespace(c)) {
      i++;
    } else if (c == 0x2f && i + 1 < src.length) {
      final n = src.codeUnitAt(i + 1);
      if (n == 0x2f) {
        i = skipLineComment(src, i);
      } else if (n == 0x2a) {
        i = skipBlockComment(src, i);
      } else {
        return i;
      }
    } else {
      return i;
    }
  }
  return i;
}

/// [i] points at `//`. Returns the index of the terminating newline (or the end
/// of input) — the newline itself is left to the caller.
int skipLineComment(String src, int i) {
  while (i < src.length && src.codeUnitAt(i) != 0x0a) {
    i++;
  }
  return i;
}

/// [i] points at `/*`. Returns the index just past the matching `*/`. Dart
/// block comments nest, so this counts depth.
int skipBlockComment(String src, int i) {
  var depth = 0;
  while (i < src.length) {
    if (src.startsWith('/*', i)) {
      depth++;
      i += 2;
    } else if (src.startsWith('*/', i)) {
      depth--;
      i += 2;
      if (depth == 0) return i;
    } else {
      i++;
    }
  }
  return i;
}

/// True when a string literal starts at [i] (including the `r` of a raw string).
bool isStringStart(String src, int i) {
  final c = src.codeUnitAt(i);
  if (c == 0x27 || c == 0x22) return true; // ' "
  if (c == 0x72 && i + 1 < src.length) {
    // r
    final n = src.codeUnitAt(i + 1);
    return n == 0x27 || n == 0x22;
  }
  return false;
}

/// [i] points at the start of a string literal (or its `r` prefix). Returns the
/// index just past the closing quote.
///
/// Handles raw strings, triple quotes, escapes and `${...}` interpolation
/// (including nested strings inside the interpolation).
int skipStringLiteral(String src, int i) {
  var raw = false;
  if (src.codeUnitAt(i) == 0x72) {
    raw = true;
    i++;
  }
  final quote = src[i];
  final triple = src.startsWith(quote * 3, i);
  final terminator = triple ? quote * 3 : quote;
  i += terminator.length;

  while (i < src.length) {
    if (!raw && src.codeUnitAt(i) == 0x5c) {
      // backslash
      i += 2;
      continue;
    }
    if (!raw && src.startsWith(r'${', i)) {
      i = skipBalancedBraces(src, i + 1);
      continue;
    }
    if (src.startsWith(terminator, i)) return i + terminator.length;
    i++;
  }
  return i;
}

/// [open] points at `{`. Returns the index just past the matching `}`,
/// skipping over strings, comments and nested markup on the way.
///
/// The markup part matters: inside `{cond ? <p>don't</p> : <p>no</p>}` the
/// apostrophe is *text*, not the start of a Dart string, and treating it as one
/// swallows the rest of the file.
int skipBalancedBraces(String src, int open) {
  var depth = 0;
  var i = open;
  var prevSignificant = -1;
  while (i < src.length) {
    final c = src.codeUnitAt(i);
    if (c == 0x7b) {
      depth++;
      prevSignificant = i;
      i++;
    } else if (c == 0x7d) {
      depth--;
      i++;
      if (depth == 0) return i;
      prevSignificant = i - 1;
    } else if (isStringStart(src, i)) {
      i = skipStringLiteral(src, i);
      prevSignificant = i - 1;
    } else if (c == 0x2f && i + 1 < src.length && src.codeUnitAt(i + 1) == 0x2f) {
      i = skipLineComment(src, i);
    } else if (c == 0x2f && i + 1 < src.length && src.codeUnitAt(i + 1) == 0x2a) {
      i = skipBlockComment(src, i);
    } else if (c == 0x3c && _opensMarkup(src, i, prevSignificant)) {
      i = skipMarkupElement(src, i);
      prevSignificant = i - 1;
    } else {
      if (!isWhitespace(c)) prevSignificant = i;
      i++;
    }
  }
  return -1; // unbalanced
}

/// The same three questions the transpiler asks before treating `<` as a tag.
bool _opensMarkup(String src, int lt, int prevSignificant) {
  if (lt + 1 >= src.length) return false;
  final next = src.codeUnitAt(lt + 1);
  if (next == 0x3e) return true; // `<>`
  if (!isIdentifierStart(next)) return false;
  if (!isExpressionPosition(src, prevSignificant)) return false;
  return !looksLikeTypeArguments(src, lt);
}

/// [open] points at the `<` of an element. Returns the index just past its
/// final `>`, treating everything between as markup rather than as Dart.
///
/// The distinction that matters is tag vs. text: a quote inside a tag opens an
/// attribute value, and a quote in text is an apostrophe. Reading `don't` as
/// the start of a Dart string is what used to swallow the rest of the file.
int skipMarkupElement(String src, int open) {
  var i = open;
  var depth = 0;

  while (i < src.length) {
    final c = src.codeUnitAt(i);

    if (c == 0x3c) {
      final closing = src.startsWith('</', i);
      i += closing ? 2 : 1;

      // Inside the tag, until its `>`.
      var selfClosing = false;
      while (i < src.length) {
        final t = src.codeUnitAt(i);
        if (t == 0x7b) {
          final brace = skipBalancedBraces(src, i);
          if (brace < 0) return src.length;
          i = brace;
          continue;
        }
        if (t == 0x22 || t == 0x27) {
          // Markup quoting has no escapes, so the next matching quote ends it.
          final quote = src.indexOf(String.fromCharCode(t), i + 1);
          i = quote < 0 ? src.length : quote + 1;
          continue;
        }
        if (t == 0x3e) {
          selfClosing = i > 0 && src.codeUnitAt(i - 1) == 0x2f;
          i++;
          break;
        }
        i++;
      }

      if (closing) {
        depth--;
      } else if (!selfClosing) {
        depth++;
      }
      if (depth <= 0) return i;
      continue;
    }

    if (c == 0x7b) {
      // An expression child: Dart rules again, recursively.
      final brace = skipBalancedBraces(src, i);
      if (brace < 0) return src.length;
      i = brace;
      continue;
    }

    i++; // ordinary text, apostrophes included
  }
  return i;
}
