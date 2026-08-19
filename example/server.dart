/// Server-side rendering entrypoint.
///
/// Run it to print a full HTML document to stdout:
///
/// ```
/// dart run build_runner build             # compiles app.dartx
/// dart run example/server.dart > index.html
/// ```
///
/// The emitted page references `main.dart.js` (compile `example/main.dart`),
/// which hydrates the same tree in the browser.
library;

import 'dart:io';

import 'package:reactx/reactx.dart';

// Generated from app.dartx by `dart run build_runner build`.
import 'app.dartx.dart';

void main() {
  final html = renderToDocument(
    App,
    title: 'reactx demo',
    bootstrapScript: 'main.dart.js',
    head: '<style>'
        'body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto}'
        'section{border:1px solid #ddd;border-radius:8px;padding:1rem;margin:1rem 0}'
        'button{margin-right:.5rem}'
        '</style>',
  );

  stdout.write(html);
}
