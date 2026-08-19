/// Dev-time hot reload support.
///
/// Hot reload swaps new code into a program that keeps running. Once the new
/// libraries are live, someone has to rebuild the tree with them — and that
/// rebuild must reach the *new* code, not the closures captured before the
/// swap. The trick reactx uses is to simply re-enter the app's own `main()`
/// through the reloaded library, which re-reads every top-level reference and
/// so hands the reconciler freshly-compiled components.
///
/// For that to update rather than remount, [runApp] and [hydrateApp] have to
/// reuse the [Root] they made the first time. They only do that while
/// [hotReloadEnabled] is set, so ordinary apps keep the old behaviour, where
/// calling `runApp` twice mounts twice.
///
/// This library is platform-neutral: it holds a flag and nothing else, so it
/// imports cleanly on the VM and costs a release build nothing.
library;

/// Whether a dev server is driving hot reloads in this program.
///
/// Set by [enableHotReload]; never true in a release build, because nothing
/// calls it there.
bool hotReloadEnabled = false;

/// Marks this program as hot-reloadable. Called by the entrypoint that
/// `reactx serve` generates — you do not need to call it yourself.
void enableHotReload() => hotReloadEnabled = true;
