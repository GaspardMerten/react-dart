/// VM/server stub. Input events only fire in the browser, so this is never
/// actually invoked on the server — it exists so `app.dart` stays importable
/// from non-web code (SSR).
library;

String eventTargetValue(Object event) => '';
