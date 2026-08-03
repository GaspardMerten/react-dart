/// Context: pass values down the tree without threading them through props.
library;

import 'vdom.dart';

/// A context object created by [createContext]. Read it with `useContext`.
final class Context<T> {
  /// Value returned by `useContext` when there is no matching provider above.
  final T defaultValue;

  /// Debug label.
  final String name;

  Context(this.defaultValue, {this.name = 'Context'});

  /// Wraps [children] in a provider that exposes [value] to the subtree.
  VNode provider({required T value, Object? children, Object? key}) {
    return ProviderNode(
      this as Context<Object?>,
      value,
      normalizeChildren(children),
      key: key,
    );
  }
}

/// Creates a new [Context] with the given [defaultValue].
Context<T> createContext<T>(T defaultValue, {String name = 'Context'}) =>
    Context<T>(defaultValue, name: name);
