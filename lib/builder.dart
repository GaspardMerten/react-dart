/// build_runner entrypoints for reactx.
///
/// Referenced from `build.yaml`; you do not import this directly.
///
///   * [reactxDartxBuilder] compiles `.dartx` files (Dart + JSX-style markup)
///     into `.dartx.dart`. See `lib/src/builder/dartx_builder.dart`.
///   * [reactxJsxBuilder] precompiles runtime `jsx(r'...')` string templates.
///     See `lib/src/builder/jsx_precompiler.dart`.
library;

export 'src/builder/dartx_builder.dart' show reactxDartxBuilder;
export 'src/builder/jsx_precompiler.dart' show reactxJsxBuilder;
