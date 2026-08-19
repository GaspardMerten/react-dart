/// Stores: shared state without wrapping the tree in a provider per store.
///
/// A [Store] is declared once, at the top level, and *is* its own identity —
/// there is no name to type, so a typo is a compile error, rename works from
/// the IDE, and two packages cannot collide:
///
/// ```dart
/// final todos = defineStore(TodoState.initial, todoReducer);
///
/// VNode Badge(Props props) {
///   final remaining = useSelect(todos, (s) => s.remaining);
///   return h('span', null, '$remaining left');
/// }
/// ```
///
/// The state itself does **not** live in the [Store] object. It lives on the
/// `Root` that is rendering (client) or on the string renderer (server), which
/// is what keeps server-side rendering correct: two requests rendered
/// concurrently in one isolate each get their own state, and a test gets a
/// clean store per `createRoot`. That is the whole reason this is not a global.
library;

/// A declaration of shared state: an initial value and a reducer.
///
/// Create one with [defineStore] and read it with `useStore` / `useSelect` /
/// `useDispatch`. The object is a key, not a container — see the library doc.
final class Store<S, A> {
  const Store(this.initialState, this.reducer, {this.debugLabel});

  final S initialState;
  final S Function(S state, A action) reducer;

  /// Only ever used in error messages and diagnostics. Never for lookup.
  final String? debugLabel;

  /// Runs the reducer at the dynamic boundary the registry works in.
  Object? applyUntyped(Object? state, Object? action) =>
      reducer(state as S, action as A);

  @override
  String toString() => debugLabel ?? 'Store<$S, $A>';
}

/// Declares a store. Call it once, at the top level.
///
/// ```dart
/// final counter = defineStore(0, (int n, String action) =>
///     action == 'inc' ? n + 1 : n);
/// ```
Store<S, A> defineStore<S, A>(
  S initialState,
  S Function(S state, A action) reducer, {
  String? debugLabel,
}) =>
    Store<S, A>(initialState, reducer, debugLabel: debugLabel);
