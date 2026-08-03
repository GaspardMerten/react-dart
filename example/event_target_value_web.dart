/// Browser implementation: reads `event.target.value` with proper `package:web`
/// types.
///
/// This must use static types, not `dynamic`: `web.Event` is a js_interop
/// extension type whose members are erased, so a `dynamic` `.target` access
/// compiles to a lookup the real DOM object doesn't have and throws at runtime.
library;

import 'package:web/web.dart' as web;

String eventTargetValue(Object event) {
  final target = (event as web.Event).target as web.HTMLInputElement?;
  return target?.value ?? '';
}
