/// Escaping for values that end up inside a rendered page.
///
/// Kept in one place because these are the functions that decide whether data
/// stays data. Both the SSR renderer and the router's snapshot transfer use
/// them, and neither should be reimplementing the rules.
library;

/// Makes [json] safe to place between `<script>` and `</script>`.
///
/// Escapes exactly four characters, all to their `\uXXXX` form:
///
/// * `<` and `>` — so a string containing `</script>` cannot close the element
///   early and have the rest of the value parsed as markup. This is the whole
///   attack, and it needs nothing more exotic than a user-supplied title.
/// * U+2028 and U+2029 — legal raw inside a JSON string, but JavaScript reads
///   them as line terminators, so an unescaped one is a syntax error in the
///   very payload it appears in.
///
/// JSON has no structural `<`, `>` or line separator, so escaping them is
/// lossless: `jsonDecode` gives back exactly what went in.
String escapeForScript(String json) => json
    .replaceAll('<', r'\u003c')
    .replaceAll('>', r'\u003e')
    .replaceAll('\u2028', r'\u2028')
    .replaceAll('\u2029', r'\u2029');

/// Whether [name] is safe to emit as an attribute name or a tag name.
///
/// Attribute *values* are escaped and quoted, so they are already safe. A name
/// is not: it is written into the tag unquoted, so a name containing a space
/// and an equals sign — `x onload=alert(1) y` — would inject a second
/// attribute. Names come from a props map, and a props map can be built from
/// data, so this is checked rather than assumed.
bool isSafeMarkupName(String name) {
  if (name.isEmpty) return false;
  final first = name.codeUnitAt(0);
  final startsOk = (first >= 0x41 && first <= 0x5a) || // A-Z
      (first >= 0x61 && first <= 0x7a) || // a-z
      first == 0x5f; // _
  if (!startsOk) return false;
  for (var i = 1; i < name.length; i++) {
    final c = name.codeUnitAt(i);
    final ok = (c >= 0x41 && c <= 0x5a) ||
        (c >= 0x61 && c <= 0x7a) ||
        (c >= 0x30 && c <= 0x39) || // 0-9
        c == 0x2d || // -
        c == 0x5f || // _
        c == 0x2e || // .
        c == 0x3a; // :
    if (!ok) return false;
  }
  return true;
}
