/// Hooks and the [Dispatcher] indirection that powers them.
///
/// The public hook functions (`useState`, `useEffect`, ...) do not contain any
/// logic themselves; they forward to [Dispatcher.current]. The client
/// reconciler installs a fiber-backed dispatcher (real state + effects); the
/// server renderer installs a read-only dispatcher (initial state, no effects).
/// This is exactly how React keeps one component API working on both client and
/// server.
library;

import 'context.dart';

/// A teardown function returned by an effect.
typedef Cleanup = void Function();

/// The body of an effect. Return a [Cleanup] to run on unmount / before the
/// next run, or return nothing. The return type is intentionally `dynamic` so
/// that `useEffect(() { ... })` with no return value does not trip the
/// `body_might_complete_normally_nullable` analyzer warning.
typedef EffectCallback = dynamic Function();

/// Updates state. Accepts either a new value of type `T`, or an updater
/// `T Function(T previous)` for updates that depend on the previous value.
typedef StateSetter<T> = void Function(Object? valueOrUpdater);

/// A mutable box whose `.current` does not trigger re-renders when changed.
final class Ref<T> {
  T current;
  Ref(this.current);
}

/// The active hook implementation for the component currently rendering.
///
/// `null` outside of render. Hook functions throw a helpful error in that case.
abstract class Dispatcher {
  static Dispatcher? current;

  (T, StateSetter<T>) useState<T>(T Function() init);
  (S, void Function(A)) useReducer<S, A>(
    S Function(S state, A action) reducer,
    S Function() init,
  );
  void useEffect(EffectCallback effect, List<Object?>? deps, {required bool layout});
  T useMemo<T>(T Function() create, List<Object?>? deps);
  Ref<T> useRef<T>(T initial);
  T useContext<T>(Context<T> context);
}

Dispatcher get _d {
  final d = Dispatcher.current;
  if (d == null) {
    throw StateError(
      'Hooks can only be called inside a component render. '
      'Did you call a hook at the top level, in an event handler, or after '
      'an await?',
    );
  }
  return d;
}

/// Declares a piece of local state. Returns the current value and a setter.
///
/// ```dart
/// final (count, setCount) = useState(0);
/// // ...
/// setCount(count + 1);          // set directly
/// setCount((c) => c + 1);       // functional update
/// ```
(T, StateSetter<T>) useState<T>(T initial) => _d.useState<T>(() => initial);

/// Like [useState] but the initial value is computed lazily, only on mount.
(T, StateSetter<T>) useStateLazy<T>(T Function() init) => _d.useState<T>(init);

/// State managed by a reducer. Returns the state and a `dispatch` function.
(S, void Function(A)) useReducer<S, A>(
  S Function(S state, A action) reducer,
  S initial,
) =>
    _d.useReducer<S, A>(reducer, () => initial);

/// Runs [effect] after the DOM has been committed. Re-runs when [deps] change.
///
/// * `deps == null`  -> run after every render.
/// * `deps == []`    -> run once on mount, cleanup on unmount.
/// * `deps == [...]` -> run when any dependency changes (compared with `==`).
void useEffect(EffectCallback effect, [List<Object?>? deps]) =>
    _d.useEffect(effect, deps, layout: false);

/// Like [useEffect] but runs synchronously right after DOM mutations, before
/// the browser paints. Use for DOM measurements.
void useLayoutEffect(EffectCallback effect, [List<Object?>? deps]) =>
    _d.useEffect(effect, deps, layout: true);

/// Memoizes an expensive computation, recomputing only when [deps] change.
T useMemo<T>(T Function() create, [List<Object?>? deps]) =>
    _d.useMemo<T>(create, deps);

/// Memoizes a callback identity across renders (sugar over [useMemo]).
T useCallback<T extends Function>(T callback, [List<Object?>? deps]) =>
    _d.useMemo<T>(() => callback, deps);

/// A mutable value that persists across renders without causing re-renders.
Ref<T> useRef<T>(T initial) => _d.useRef<T>(initial);

/// Reads the nearest provided value for [context].
T useContext<T>(Context<T> context) => _d.useContext<T>(context);
