/// Hot reload support, used by the entrypoint `reactx serve` generates.
///
/// You will not normally import this: the dev server writes a small entry file
/// that calls [enableHotReload] before your `main()`, and re-enters `main()`
/// after each swap. See `lib/src/hot_reload.dart` for how that works.
library;

export 'src/hot_reload.dart' show enableHotReload, hotReloadEnabled;
