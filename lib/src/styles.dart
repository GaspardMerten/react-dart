/// Getting a component's scoped stylesheet onto the page.
///
/// Styles travel with the components that use them, so a page carries what it
/// actually rendered. The two halves collect them differently, and the
/// difference matters:
///
///  * **On the server** each request's renderer keeps its own set. One isolate
///    renders many pages at once, and a shared collection would leak one
///    visitor's stylesheet into another's document.
///  * **In the browser** there is one document, and a stylesheet is a constant.
///    A global set is therefore correct, and it is what stops the same rules
///    being appended once per render.
library;

/// Where the browser puts a stylesheet it has not seen before. Set by
/// `lib/src/dom.dart`; null anywhere else, which is why this file is safe to
/// import from platform-neutral code.
void Function(String css)? styleSink;

final Set<String> _adopted = {};

/// Called by the reconciler the first time a component with styles renders.
void adoptStyles(String css) {
  if (!_adopted.add(css)) return;
  styleSink?.call(css);
}

/// Forgets what has been adopted. For tests, which mount many roots into many
/// documents and would otherwise see the first one's styles as already there.
void resetAdoptedStyles() => _adopted.clear();
