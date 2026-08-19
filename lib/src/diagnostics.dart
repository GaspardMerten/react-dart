/// Development-time diagnostics.
///
/// Every check that lives behind [devMode] is wrapped in an `assert`, so it
/// costs nothing in a release build (`dart compile js` strips asserts unless
/// you pass `--enable-asserts`). The point is to turn the framework's silent
/// failure modes — a hook behind an `if`, a hydration mismatch, duplicate keys
/// — into a message that names the problem, instead of a tree that is subtly
/// wrong three renders later.
library;

/// Where warnings go. Replace it to capture them (tests) or route them at a
/// logger. The default prints each distinct message once.
void Function(String message) reactxWarning = _printOnce;

final Set<String> _seen = <String>{};

void _printOnce(String message) {
  if (_seen.add(message)) {
    // ignore: avoid_print — this is the default sink and is dev-only.
    print('reactx: $message');
  }
}

/// Forgets which messages have already been printed. Useful between tests.
void resetWarnings() => _seen.clear();

/// True only when asserts are enabled.
bool get devMode {
  var enabled = false;
  assert(() {
    enabled = true;
    return true;
  }());
  return enabled;
}

/// Emits [message] through [reactxWarning] when asserts are on. Always returns
/// true so it can be used inside an `assert(...)`.
bool warn(String message) {
  if (devMode) reactxWarning(message);
  return true;
}
