/// The reconciler: turns a [VNode] tree into host mutations and keeps a
/// persistent fiber tree so subsequent renders can diff instead of rebuild.
///
/// It is deliberately synchronous (no time-slicing). It talks only to a
/// [HostAdapter], so it runs identically against the DOM or the in-memory
/// [TestHost].
library;

import 'dart:async';

import 'context.dart';
import 'hooks.dart';
import 'host.dart';
import 'vdom.dart';

/// Creates a root bound to [host] that renders into [container].
Root createRoot(HostAdapter host, Object container) => Root(host, container);

// ---------------------------------------------------------------------------
// Fiber: the persistent instance backing a VNode across renders.
// ---------------------------------------------------------------------------

class Fiber {
  final Root root;
  Fiber? parent;
  int depth;

  VNode vnode;
  Object? get key => vnode.key;

  /// For [TextNode]/[ElementNode] fibers: the created host node.
  Object? hostNode;

  List<Fiber> children = [];

  /// Hook state slots, in call order (rules of hooks).
  final List<Object> hooks = [];

  /// Active event listeners on [hostNode], keyed by DOM event type.
  final Map<String, void Function(Object event)> listeners = {};

  /// For [ProviderNode] fibers: the value currently provided.
  Object? providerValue;

  bool unmounted = false;

  Fiber(this.root, this.vnode, this.parent) : depth = parent == null ? 0 : parent.depth + 1;
}

// ---- Hook state holders ----------------------------------------------------

class _StateHolder<T> {
  T value;
  late StateSetter<T> setter;
  _StateHolder(this.value);
}

class _EffectHolder {
  final bool layout;
  List<Object?>? deps;
  EffectCallback? pending;
  Cleanup? cleanup;
  bool queued = false;
  _EffectHolder(this.layout);
}

class _MemoHolder {
  Object? value;
  List<Object?>? deps;
}

class _RefHolder<T> {
  final Ref<T> ref;
  _RefHolder(this.ref);
}

/// Walks the existing host children at one level during hydration.
class _Hydration {
  final List<Object> nodes;
  int _i = 0;
  _Hydration(this.nodes);
  Object? next() => _i < nodes.length ? nodes[_i++] : null;
}

// ---------------------------------------------------------------------------
// Root: owns the fiber tree, the scheduler, and the effect queues.
// ---------------------------------------------------------------------------

class Root {
  final HostAdapter host;
  final Object container;
  Fiber? _root;

  final List<(Fiber, _EffectHolder)> _layoutQueue = [];
  final List<(Fiber, _EffectHolder)> _passiveQueue = [];
  final Set<Fiber> _dirty = {};
  bool _workScheduled = false;

  Root(this.host, this.container);

  /// Mounts or updates [vnode] as the tree's single top-level child.
  void render(VNode vnode) {
    if (_root == null || !_compatible(_root!, vnode)) {
      if (_root != null) _unmount(_root!);
      _root = _mount(vnode, null, container, null);
    } else {
      _update(_root!, vnode, container, null);
    }
    _drain();
  }

  /// Hydrates server-rendered markup already present in [container]: adopts the
  /// existing host nodes instead of creating new ones, then attaches event
  /// listeners and wires up state so the tree becomes interactive without
  /// re-creating the DOM.
  ///
  /// Assumes the existing markup matches [vnode]'s structure (as produced by
  /// [renderToString]). Avoid adjacent bare-text siblings, which the server
  /// collapses into a single text node.
  void hydrate(VNode vnode) {
    _root = _mount(vnode, null, container, null, _Hydration(host.childNodes(container)));
    _drain();
  }

  /// Unmounts everything and runs all cleanups.
  void unmount() {
    if (_root != null) _unmount(_root!);
    _root = null;
    _flushEffects();
  }

  /// Runs [body] then synchronously flushes all pending state updates and
  /// effects. Mirrors React's `act()` and makes tests deterministic without
  /// awaiting microtasks.
  void act(void Function() body) {
    body();
    _drain();
  }

  /// The current top-of-tree fiber, for introspection in tests. May be `null`
  /// before the first [render].
  Fiber? get rootFiber => _root;

  // -- Mounting --------------------------------------------------------------

  Fiber _mount(VNode vnode, Fiber? parent, Object hostParent, Object? anchor,
      [_Hydration? hydrate]) {
    final fiber = Fiber(this, vnode, parent);
    switch (vnode) {
      case TextNode t:
        final adopt = hydrate?.next();
        if (adopt != null && host.isText(adopt)) {
          host.setText(adopt, t.text);
          fiber.hostNode = adopt;
        } else {
          final node = host.createText(t.text);
          fiber.hostNode = node;
          host.insertBefore(hostParent, node, anchor);
        }
      case ElementNode e:
        final adopt = hydrate?.next();
        _Hydration? childHydrate;
        Object node;
        if (adopt != null && !host.isText(adopt)) {
          node = adopt;
          childHydrate = _Hydration(host.childNodes(node));
        } else {
          node = host.createElement(e.tag);
          host.insertBefore(hostParent, node, anchor);
        }
        fiber.hostNode = node;
        _applyProps(fiber, node, const {}, e.props);
        if (!e.props.containsKey('dangerouslySetInnerHTML')) {
          for (final child in e.children) {
            fiber.children.add(_mount(child, fiber, node, null, childHydrate));
          }
        }
      case FragmentNode f:
        for (final child in f.children) {
          fiber.children.add(_mount(child, fiber, hostParent, anchor, hydrate));
        }
      case ProviderNode p:
        fiber.providerValue = p.value;
        for (final child in p.children) {
          fiber.children.add(_mount(child, fiber, hostParent, anchor, hydrate));
        }
      case ComponentNode c:
        final rendered = _renderComponent(fiber, c);
        fiber.children.add(_mount(rendered, fiber, hostParent, anchor, hydrate));
    }
    return fiber;
  }

  // -- Updating --------------------------------------------------------------

  void _update(Fiber fiber, VNode next, Object hostParent, Object? anchor) {
    switch (next) {
      case TextNode t:
        if ((fiber.vnode as TextNode).text != t.text) {
          host.setText(fiber.hostNode!, t.text);
        }
        fiber.vnode = t;
      case ElementNode e:
        _applyProps(fiber, fiber.hostNode!, (fiber.vnode as ElementNode).props, e.props);
        fiber.vnode = e;
        _reconcileChildren(fiber, fiber.hostNode!, e.children);
      case FragmentNode f:
        fiber.vnode = f;
        _reconcileChildren(fiber, hostParent, f.children);
      case ProviderNode p:
        fiber.providerValue = p.value;
        fiber.vnode = p;
        _reconcileChildren(fiber, hostParent, p.children);
      case ComponentNode c:
        fiber.vnode = c;
        final rendered = _renderComponent(fiber, c);
        _reconcileChildren(fiber, hostParent, [rendered]);
    }
  }

  void _rerender(Fiber fiber) {
    final v = fiber.vnode;
    if (v is! ComponentNode) return;
    final rendered = _renderComponent(fiber, v);
    _reconcileChildren(fiber, _hostParentOf(fiber), [rendered]);
  }

  VNode _renderComponent(Fiber fiber, ComponentNode c) {
    final prev = Dispatcher.current;
    Dispatcher.current = _FiberDispatcher(this, fiber);
    try {
      return c.component(c.props);
    } finally {
      Dispatcher.current = prev;
    }
  }

  // -- Children reconciliation (keyed) ---------------------------------------

  void _reconcileChildren(Fiber parent, Object hostParent, List<VNode> next) {
    final anchor = parent.vnode is ElementNode ? null : _nextHostAnchor(parent);
    final old = parent.children;

    final keyed = <Object, Fiber>{};
    final unkeyed = <Fiber>[];
    for (final f in old) {
      if (f.key != null) {
        keyed[f.key!] = f;
      } else {
        unkeyed.add(f);
      }
    }

    var cursor = 0;
    final matched = <Fiber>{};
    final result = <Fiber>[];

    for (final v in next) {
      Fiber? match;
      if (v.key != null) {
        final cand = keyed[v.key!];
        if (cand != null && _compatible(cand, v)) match = cand;
      } else {
        while (cursor < unkeyed.length) {
          final cand = unkeyed[cursor++];
          if (matched.contains(cand)) continue;
          if (_compatible(cand, v)) match = cand;
          break;
        }
      }

      if (match != null) {
        matched.add(match);
        _update(match, v, hostParent, anchor);
        result.add(match);
      } else {
        result.add(_mount(v, parent, hostParent, anchor));
      }
    }

    for (final f in old) {
      if (!matched.contains(f)) _unmount(f);
    }

    parent.children = result;
    _placeInOrder(parent, hostParent, anchor);
  }

  // -- Placement -------------------------------------------------------------

  /// Positions each child's host nodes in document order (right-to-left so a
  /// single stable anchor suffices). A node already in the correct spot is left
  /// untouched — critical in the DOM, where re-inserting a focused `<input>`
  /// would blur it and drop the caret.
  void _placeInOrder(Fiber parent, Object hostParent, Object? trailing) {
    Object? anchor = trailing;
    for (final child in parent.children.reversed) {
      final nodes = _hostNodesOf(child);
      for (final n in nodes.reversed) {
        final inPlace = identical(host.parentNode(n), hostParent) &&
            identical(host.nextSibling(n), anchor);
        if (!inPlace) host.insertBefore(hostParent, n, anchor);
        anchor = n;
      }
    }
  }

  List<Object> _hostNodesOf(Fiber f) {
    if (f.vnode is TextNode || f.vnode is ElementNode) return [f.hostNode!];
    final out = <Object>[];
    for (final c in f.children) {
      out.addAll(_hostNodesOf(c));
    }
    return out;
  }

  Object? _firstHostNode(Fiber f) {
    if (f.vnode is TextNode || f.vnode is ElementNode) return f.hostNode;
    for (final c in f.children) {
      final n = _firstHostNode(c);
      if (n != null) return n;
    }
    return null;
  }

  /// The host node that follows [fiber]'s whole subtree within its container.
  Object? _nextHostAnchor(Fiber fiber) {
    Fiber? cur = fiber;
    while (cur != null) {
      final parent = cur.parent;
      if (parent == null) return null;
      final sibs = parent.children;
      final idx = sibs.indexOf(cur);
      for (var i = idx + 1; i < sibs.length; i++) {
        final n = _firstHostNode(sibs[i]);
        if (n != null) return n;
      }
      if (parent.vnode is ElementNode) return null; // container boundary
      cur = parent;
    }
    return null;
  }

  Object _hostParentOf(Fiber fiber) {
    Fiber? p = fiber.parent;
    while (p != null) {
      if (p.vnode is ElementNode) return p.hostNode!;
      p = p.parent;
    }
    return container;
  }

  // -- Unmounting ------------------------------------------------------------

  void _unmount(Fiber fiber) {
    fiber.unmounted = true;
    for (final h in fiber.hooks) {
      if (h is _EffectHolder) {
        h.cleanup?.call();
        h.cleanup = null;
      }
    }
    for (final c in fiber.children) {
      _unmount(c);
    }
    final node = fiber.hostNode;
    if (node != null) {
      for (final e in fiber.listeners.entries) {
        host.removeEventListener(node, e.key, e.value);
      }
      final v = fiber.vnode;
      if (v is ElementNode && v.props['ref'] is Ref) {
        (v.props['ref'] as Ref).current = null;
      }
      final p = host.parentNode(node);
      if (p != null) host.removeChild(p, node);
    }
  }

  // -- Props / attributes / events ------------------------------------------

  void _applyProps(Fiber fiber, Object node, Props oldProps, Props newProps) {
    for (final name in oldProps.keys) {
      if (_isSpecial(name)) continue;
      if (!newProps.containsKey(name)) {
        if (_isEvent(name, oldProps[name])) {
          _detach(fiber, node, name);
        } else {
          host.removeAttribute(node, _attrName(name));
        }
      }
    }

    newProps.forEach((name, value) {
      if (_isSpecial(name)) return;
      final old = oldProps[name];
      if (_isEvent(name, value)) {
        if (!identical(old, value)) {
          _detach(fiber, node, name);
          _attach(fiber, node, name, value as Function);
        }
        return;
      }
      if (identical(old, value) || old == value) return;
      _setAttr(node, name, value);
    });

    final ref = newProps['ref'];
    if (ref is Ref && !identical(oldProps['ref'], ref)) ref.current = node;

    final raw = newProps['dangerouslySetInnerHTML'];
    if (raw is Map && raw['__html'] != null &&
        !identical(oldProps['dangerouslySetInnerHTML'], raw)) {
      host.setInnerHtml(node, raw['__html'].toString());
    }
  }

  void _setAttr(Object node, String name, Object? value) {
    if (name == 'style' && value is Map) {
      host.setAttribute(node, 'style', _styleToString(value));
      return;
    }
    if (value == null || value == false) {
      host.removeAttribute(node, _attrName(name));
    } else {
      host.setAttribute(node, _attrName(name), value);
    }
  }

  void _attach(Fiber fiber, Object node, String name, Function fn) {
    final type = name.substring(2).toLowerCase();
    void listener(Object event) => _invokeHandler(fn, event);
    fiber.listeners[type] = listener;
    host.addEventListener(node, type, listener);
  }

  void _detach(Fiber fiber, Object node, String name) {
    final type = name.substring(2).toLowerCase();
    final l = fiber.listeners.remove(type);
    if (l != null) host.removeEventListener(node, type, l);
  }

  // -- Scheduler -------------------------------------------------------------

  void _markDirty(Fiber f) {
    if (f.unmounted) return;
    _dirty.add(f);
    if (!_workScheduled) {
      _workScheduled = true;
      scheduleMicrotask(() {
        _workScheduled = false;
        _drain();
      });
    }
  }

  void _queueEffect(Fiber f, _EffectHolder h) {
    if (h.queued) return;
    h.queued = true;
    (h.layout ? _layoutQueue : _passiveQueue).add((f, h));
  }

  /// Processes pending state updates and queued effects until both settle.
  /// Effects may themselves call `setState`, so this loops: render dirty
  /// fibers, run effects, and repeat if effects produced more work. Synchronous
  /// — this is also what [act] relies on for deterministic tests.
  void _drain() {
    var guard = 0;
    do {
      while (_dirty.isNotEmpty) {
        if (guard++ > 100000) {
          throw StateError('Too many re-renders. A component keeps updating '
              'state during render.');
        }
        final batch = _dirty.toList()
          ..sort((a, b) => a.depth.compareTo(b.depth));
        _dirty.clear();
        for (final f in batch) {
          if (!f.unmounted) _rerender(f);
        }
      }
      _flushEffects();
    } while (_dirty.isNotEmpty);
  }

  void _flushEffects() {
    void run(List<(Fiber, _EffectHolder)> q) {
      final items = List.of(q);
      q.clear();
      for (final (f, h) in items) {
        h.queued = false;
        if (f.unmounted) continue;
        h.cleanup?.call();
        final result = h.pending?.call();
        h.pending = null;
        h.cleanup = result is Function ? () => (result as dynamic)() : null;
      }
    }

    run(_layoutQueue);
    run(_passiveQueue);
  }

  // -- VNode <-> fiber compatibility ----------------------------------------

  bool _compatible(Fiber f, VNode v) {
    if (f.key != v.key) return false;
    final fv = f.vnode;
    return switch (v) {
      TextNode() => fv is TextNode,
      ElementNode e => fv is ElementNode && fv.tag == e.tag,
      FragmentNode() => fv is FragmentNode,
      ProviderNode p => fv is ProviderNode && identical(fv.context, p.context),
      ComponentNode c => fv is ComponentNode && fv.component == c.component,
    };
  }
}

// ---------------------------------------------------------------------------
// The client-side hook dispatcher, bound to one rendering fiber.
// ---------------------------------------------------------------------------

class _FiberDispatcher implements Dispatcher {
  final Root root;
  final Fiber fiber;
  int index = 0;

  _FiberDispatcher(this.root, this.fiber);

  T _slot<T>(T Function() create) {
    if (index >= fiber.hooks.length) fiber.hooks.add(create() as Object);
    return fiber.hooks[index++] as T;
  }

  @override
  (T, StateSetter<T>) useState<T>(T Function() init) {
    final holder = _slot<_StateHolder<T>>(() {
      final h = _StateHolder<T>(init());
      h.setter = (dynamic v) {
        final prev = h.value;
        // Like React: a function argument is a functional updater
        // `(prev) => next`. To store a function as state, wrap it.
        final next = v is Function ? (v as dynamic)(prev) as T : v as T;
        if (identical(prev, next) || prev == next) return;
        h.value = next;
        root._markDirty(fiber);
      };
      return h;
    });
    return (holder.value, holder.setter);
  }

  @override
  (S, void Function(A)) useReducer<S, A>(
    S Function(S, A) reducer,
    S Function() init,
  ) {
    final holder = _slot<_StateHolder<S>>(() {
      final h = _StateHolder<S>(init());
      h.setter = (dynamic action) {
        final next = reducer(h.value, action as A);
        if (identical(h.value, next) || h.value == next) return;
        h.value = next;
        root._markDirty(fiber);
      };
      return h;
    });
    return (holder.value, (A action) => holder.setter(action));
  }

  @override
  void useEffect(EffectCallback effect, List<Object?>? deps, {required bool layout}) {
    final i = index;
    if (i >= fiber.hooks.length) {
      final h = _EffectHolder(layout)
        ..deps = deps
        ..pending = effect;
      fiber.hooks.add(h);
      root._queueEffect(fiber, h);
    } else {
      final h = fiber.hooks[i] as _EffectHolder;
      final changed = deps == null || !_depsEqual(h.deps, deps);
      if (changed) {
        h.deps = deps;
        h.pending = effect;
        root._queueEffect(fiber, h);
      }
    }
    index++;
  }

  @override
  T useMemo<T>(T Function() create, List<Object?>? deps) {
    final i = index;
    if (i >= fiber.hooks.length) {
      final h = _MemoHolder()
        ..deps = deps
        ..value = create();
      fiber.hooks.add(h);
      index++;
      return h.value as T;
    }
    final h = fiber.hooks[i] as _MemoHolder;
    if (deps == null || !_depsEqual(h.deps, deps)) {
      h.deps = deps;
      h.value = create();
    }
    index++;
    return h.value as T;
  }

  @override
  Ref<T> useRef<T>(T initial) {
    final holder = _slot<_RefHolder<T>>(() => _RefHolder<T>(Ref<T>(initial)));
    return holder.ref;
  }

  @override
  T useContext<T>(Context<T> context) {
    Fiber? p = fiber.parent;
    while (p != null) {
      final v = p.vnode;
      if (v is ProviderNode && identical(v.context, context)) {
        return p.providerValue as T;
      }
      p = p.parent;
    }
    return context.defaultValue;
  }
}

// ---------------------------------------------------------------------------
// Shared helpers.
// ---------------------------------------------------------------------------

bool _depsEqual(List<Object?>? a, List<Object?>? b) {
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _isSpecial(String name) =>
    name == 'key' ||
    name == 'children' ||
    name == 'ref' ||
    name == 'dangerouslySetInnerHTML';

bool _isEvent(String name, Object? value) =>
    name.length > 2 && name.startsWith('on') && value is Function;

String _attrName(String name) => switch (name) {
      'className' => 'class',
      'htmlFor' => 'for',
      _ => name,
    };

void _invokeHandler(Function f, Object event) {
  if (f is void Function()) {
    f();
    return;
  }
  Function.apply(f, [event]);
}

String _styleToString(Map<Object?, Object?> style) {
  final b = StringBuffer();
  style.forEach((k, v) {
    if (v == null) return;
    b.write('${_kebab('$k')}: $v; ');
  });
  return b.toString().trimRight();
}

String _kebab(String s) => s.replaceAllMapped(
      RegExp('[A-Z]'),
      (m) => '-${m[0]!.toLowerCase()}',
    );
