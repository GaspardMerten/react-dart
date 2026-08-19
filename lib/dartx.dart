/// The dartx transpiler — `.dartx` (Dart + JSX-style markup) to plain Dart.
///
/// This is a **build-time** library: import it from a builder, a script or an
/// editor tool. Application code never needs it, because by the time your app
/// runs the markup is already ordinary `h(...)` calls.
///
/// ```dart
/// import 'package:reactx/dartx.dart';
///
/// final result = transpileDartx(source, uri: 'counter.dartx');
/// if (result.ok) print(result.code);
/// else print(result.errors.first);   // counter.dartx:12:5: ...
/// ```
///
/// See `bin/dartx.dart` for the CLI and `lib/src/builder/dartx_builder.dart`
/// for the build_runner integration.
library;

export 'src/dartx/ast.dart';
export 'src/dartx/diagnostics.dart' show DartxError, LineMap;
export 'src/dartx/emitter.dart' show emitElement, emitNode;
export 'src/dartx/parser.dart' show DartxParser, htmlVoidElements;
export 'src/dartx/transpiler.dart' show DartxResult, transpileDartx;
