/// The reconciler: turns a [VNode] tree into host mutations and keeps a
/// persistent fiber tree so subsequent renders can diff instead of rebuild.
///
/// It is deliberately synchronous (no time-slicing). It talks only to a
/// [HostAdapter], so it runs identically against the DOM or the in-memory
/// [TestHost].
library;

import 'dart:async';

import 'context.dart';
import 'diagnostics.dart';
import 'hooks.dart';
import 'host.dart';
import 'store.dart';
import 'styles.dart';
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

  /// Which hook produced each slot. Maintained only when asserts are on, so
  /// that a hook moved behind an `if` is reported instead of silently reading
  /// another hook's state.
  final List<String> hookKinds = [];

  /// Trampolines registered on [hostNode], keyed by DOM event type. Registered
  /// once and kept, so a re-render never has to touch the host's listener list.
  final Map<String, void Function(Object event)> listeners = {};

  /// The handler each trampoline currently forwards to. Swapping an inline
  /// closure between renders means writing here — not re-binding the DOM.
  final Map<String, Function> handlers = {};

  /// Set by `setState`, cleared the moment the component function runs again.
  /// Lets the scheduler skip a fiber that a dirty ancestor already refreshed.
  bool dirty = false;

  /// For [ProviderNode] fibers: the value currently provided.
  Object? providerValue;

  /// Contexts read by *this fiber's own render*. Cleared each time it runs.
  final Set<Context<Object?>> ownContexts = {};

  /// Contexts read anywhere in this subtree, or `null` when that is not known
  /// yet. A provider change may only skip a subtree whose answer is known and
  /// does not include the context that changed — unknown means re-render, which
  /// is the behaviour this replaces.
  Set<Context<Object?>>? contexts;

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

/// [_StateHolder] plus the reducer, re-read on every render so a closure over
/// props cannot go stale.
class _ReducerHolder<S, A> extends _StateHolder<S> {
  _ReducerHolder(super.value, this.reducer);
  S Function(S, A) reducer;
}

class _MemoHolder {
  Object? value;
  List<Object?>? deps;
}

class _RefHolder<T> {
  final Ref<T> ref;
  _RefHolder(this.ref);
}

/// The live state of one [Store] within one [Root], plus who is watching it.
class _StoreCell {
  _StoreCell(this.state);

  Object? state;

  /// Fibers that read the whole state; every change re-renders them.
  final Set<Fiber> subscribers = {};

  /// Fibers watching a derived slice; only a changed slice re-renders them.
  ///
  /// A Set, because unmounting is `remove` — and a list makes tearing down n
  /// rows O(n²), which a long store-backed list notices.
  final Set<_Selection> selections = {};

  /// The dispatch closure handed to components. Cached so it is identical on
  /// every render, which is what makes it safe as a `memo` prop or an effect
  /// dependency.
  Object? dispatch;
}

/// One `useSelect` subscription: a fiber, its selector, and what that selector
/// last returned.
class _Selection {
  _Selection(this.cell, this.fiber, this.select, this.last);

  final _StoreCell cell;
  final Fiber fiber;
  Object? Function(Object? state) select;
  Object? last;
}

/// A `useStore` subscription, parked in a hook slot so unmount can undo it.
class _Subscription {
  _Subscription(this.cell);
  final _StoreCell cell;
}

/// Walks the existing host children at one level during hydration.
class _Hydration {
  final List<Object> nodes;
  int _i = 0;
  _Hydration(this.nodes);

  Object? next() => _i < nodes.length ? nodes[_i++] : null;

  /// The next node that has not been claimed, without claiming it. A fresh node
  /// built to replace a rejected one is inserted *before* this, so it lands in
  /// the slot the rejected one occupied rather than at the end.
  Object? get upcoming => _i < nodes.length ? nodes[_i] : null;

  /// Everything the client tree never claimed.
  Iterable<Object> get unclaimed => nodes.skip(_i);
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

  /// The contexts whose value changed in the reconcile currently running, as a
  /// stack — providers nest. A subtree that reads none of them can still bail
  /// out, which is the difference between one theme toggle re-rendering its
  /// consumers and re-rendering the whole app.
  final List<Context<Object?>> _changedContexts = [];

  /// Store state for this root only — never static, so concurrent server
  /// renders cannot see each other's data.
  final Map<Object, _StoreCell> _stores = {};

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
    if (_root != null) _unmount(_root!); // don't leak a prior tree's cleanups
    final hydration = _Hydration(host.childNodes(container));
    _root = _mount(vnode, null, container, null, hydration);
    _discardUnclaimed(hydration, container);
    _drain();
  }

  /// Unmounts everything and runs all cleanups.
  ///
  /// Store state goes with it. It belongs to this root — that is the whole
  /// reason it is not static — so leaving it behind would let a second
  /// `render` on the same root read the previous session's data, which is
  /// exactly the isolation `defineStore` promises.
  void unmount() {
    if (_root != null) _unmount(_root!);
    _root = null;
    _flushEffects();
    _stores.clear();
    // Dropping these also drops the last references to the unmounted tree.
    _dirty.clear();
    _layoutQueue.clear();
    _passiveQueue.clear();
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

  /// Re-runs every component in the tree, keeping every fiber — and therefore
  /// every hook's state — exactly where it is. This is what a hot reload calls.
  ///
  /// It deliberately does *not* rebuild the tree from the root vnode. Doing
  /// that would mean re-entering `main()`, which re-runs whatever else your
  /// entrypoint does — timers, listeners, analytics — once per save. Flutter
  /// draws the same line with `reassemble()`: new code, same element tree, and
  /// the app is not restarted behind your back.
  ///
  /// New code reaches the tree because a component's *body* is looked up
  /// through its library, which the reload has already replaced. What a fiber
  /// holds onto is its position and its state, neither of which the edit
  /// changed.
  void reassemble() {
    final root = _root;
    if (root == null) return;
    _markSubtreeDirty(root);
    _drain();
  }

  void _markSubtreeDirty(Fiber fiber) {
    if (fiber.unmounted) return;
    final v = fiber.vnode;
    if (v is ComponentNode || v is ComponentProps) _markDirty(fiber);
    for (final child in fiber.children) {
      _markSubtreeDirty(child);
    }
  }

  // -- Stores ----------------------------------------------------------------

  _StoreCell _cellFor(Store<Object?, Object?> store) =>
      _stores.putIfAbsent(store, () => _StoreCell(store.initialState));

  /// Applies [action] and wakes exactly the fibers whose view of the store
  /// actually changed.
  void _dispatchToStore(Store<Object?, Object?> store, Object? action) {
    final cell = _cellFor(store);
    final next = store.applyUntyped(cell.state, action);
    if (identical(cell.state, next) || cell.state == next) return;
    cell.state = next;

    for (final f in cell.subscribers) {
      if (!f.unmounted) _markDirty(f);
    }

    // No sweep for unmounted fibers here: `_unmount` deregisters them, so this
    // would be a full scan on every dispatch to find nothing.
    for (final s in cell.selections.toList()) {
      final value = s.select(next);
      if (identical(value, s.last) || value == s.last) continue;
      s.last = value;
      _markDirty(s.fiber);
    }
  }

  // -- Mounting --------------------------------------------------------------

  Fiber _mount(VNode vnode, Fiber? parent, Object hostParent, Object? anchor,
      [_Hydration? hydrate]) {
    final fiber = Fiber(this, vnode, parent);
    switch (vnode) {
      case TextNode t:
        final adopt = _adopt(hydrate, hostParent, null);
        if (adopt != null) {
          host.setText(adopt, t.text);
          fiber.hostNode = adopt;
        } else {
          final node = host.createText(t.text);
          fiber.hostNode = node;
          host.insertBefore(hostParent, node, _slot(hydrate, anchor));
        }
      case ElementNode e:
        final adopt = _adopt(hydrate, hostParent, e.tag);
        _Hydration? childHydrate;
        Object node;
        if (adopt != null) {
          node = adopt;
          childHydrate = _Hydration(host.childNodes(node));
        } else {
          node = host.createElement(e.tag);
          host.insertBefore(hostParent, node, _slot(hydrate, anchor));
        }
        fiber.hostNode = node;
        // Hydrating diffs against what the server actually wrote, so an
        // attribute it set and the client no longer wants is removed rather
        // than left behind. A fresh node has nothing to diff against.
        _applyProps(fiber, node, adopt == null ? const {} : host.attributesOf(node),
            e.props);
        if (!e.props.containsKey('dangerouslySetInnerHTML')) {
          assert(_keysAreUnique(fiber, e.children));
          for (final child in e.children) {
            fiber.children.add(_mount(child, fiber, node, null, childHydrate));
          }
          // Whatever the server rendered and the client did not claim is gone
          // from the tree, so it has to go from the DOM too — otherwise it
          // stays visible forever and every later insert lands after it.
          _discardUnclaimed(childHydrate, node);
        }
      case FragmentNode f:
        assert(_keysAreUnique(fiber, f.children));
        for (final child in f.children) {
          fiber.children.add(_mount(child, fiber, hostParent, anchor, hydrate));
        }
      case ProviderNode p:
        fiber.providerValue = p.value;
        assert(_keysAreUnique(fiber, p.children));
        for (final child in p.children) {
          fiber.children.add(_mount(child, fiber, hostParent, anchor, hydrate));
        }
      // Both component shapes mount identically: render once, and mount what
      // came back. They differ only in how the arguments got there.
      case ComponentNode _:
      case ComponentProps _:
        final rendered = _renderComponent(fiber, vnode);
        fiber.children.add(_mount(rendered, fiber, hostParent, anchor, hydrate));
    }
    _recordContexts(fiber);
    return fiber;
  }

  /// Where a freshly built node goes during hydration: in front of the next
  /// unclaimed server node, so it takes the slot of whatever was rejected
  /// instead of being appended after its own later siblings.
  Object? _slot(_Hydration? hydrate, Object? anchor) =>
      hydrate?.upcoming ?? anchor;

  /// Removes the server nodes the client tree never claimed.
  void _discardUnclaimed(_Hydration? hydrate, Object hostParent) {
    if (hydrate == null) return;
    final leftovers = hydrate.unclaimed.toList();
    if (leftovers.isEmpty) return;
    assert(warn(
      'hydration mismatch: the server rendered ${leftovers.length} more '
      'child node(s) here than the tree does. Removing them; check that the '
      'client renders the same tree the server did.',
    ));
    for (final node in leftovers) {
      host.removeChild(hostParent, node);
    }
  }

  /// Claims the next server-rendered node for a vnode, or `null` when there is
  /// nothing to claim.
  ///
  /// [tag] is the element tag wanted, or `null` for a text node. A node that
  /// does not match is *discarded* rather than adopted: adopting it would give
  /// the tree a host node of the wrong kind, which then fails in ways that
  /// point nowhere near the mismatch. In dev the discard is reported.
  Object? _adopt(_Hydration? hydrate, Object hostParent, String? tag) {
    final node = hydrate?.next();
    if (node == null) return null;

    final wantText = tag == null;
    final isText = host.isText(node);
    var ok = wantText == isText;
    if (ok && !wantText) {
      final actual = host.tagOf(node);
      ok = actual == null || actual == tag.toLowerCase();
    }
    if (ok) return node;

    assert(warn(
      'hydration mismatch: the server rendered '
      '${isText ? 'text' : '<${host.tagOf(node) ?? '?'}>'} where the tree '
      'wants ${wantText ? 'text' : '<$tag>'}. Discarding the server node and '
      'building a fresh one; check that the client renders the same tree the '
      'server did.',
    ));
    host.removeChild(hostParent, node);
    return null;
  }

  // -- Updating --------------------------------------------------------------

  /// Whether [fiber] may skip its work given the provider values that changed
  /// on the way down to it.
  ///
  /// A subtree that reads none of the changed contexts cannot be affected by
  /// them, so it keeps its bailout — a theme toggle re-renders the components
  /// that read the theme, not the whole application. A subtree whose reads are
  /// not yet known (`contexts == null`) never bails out, so the unknown case
  /// behaves exactly as it did before this existed.
  bool _mayBailOut(Fiber fiber) {
    if (_changedContexts.isEmpty) return true;
    final read = fiber.contexts;
    if (read == null) return false;
    for (final context in _changedContexts) {
      if (read.contains(context)) return false;
    }
    return true;
  }

  /// Records what this subtree reads, for [_mayBailOut]. Called once a fiber's
  /// children are settled, so it is the union of its own reads and theirs.
  void _recordContexts(Fiber fiber) {
    Set<Context<Object?>>? result;
    if (fiber.ownContexts.isNotEmpty) result = {...fiber.ownContexts};
    for (final child in fiber.children) {
      final sub = child.contexts;
      if (sub == null) {
        fiber.contexts = null; // unknown propagates up, and disables bailouts
        return;
      }
      if (sub.isEmpty) continue;
      (result ??= <Context<Object?>>{}).addAll(sub);
    }
    // The common case allocates nothing: most fibers read no context at all.
    fiber.contexts = result ?? const {};
  }

  void _update(Fiber fiber, VNode next, Object hostParent, Object? anchor) {
    // The same VNode instance means the same tree: nothing below can have
    // changed, so skip the whole subtree. This is what makes hoisting a node
    // out of a component (or memoizing it with `useMemo`) actually pay — the
    // equivalent of Flutter short-circuiting on a `const` widget.
    //
    // Safe even for components with pending state: `setState` marks the fiber
    // dirty and the scheduler re-renders it on its own, independently of the
    // parent's pass.
    //
    // The one thing that *can* change without the vnode changing is context:
    // a provider whose value moved has to reach consumers below, and those
    // consumers are frequently reached through an identical vnode — the very
    // common `Scope(children: props['children'])` shape hands the same child
    // instance back on every render. [_mayBailOut] suspends the bailout for
    // exactly the subtrees that read a context whose value moved.
    if (identical(fiber.vnode, next) && _mayBailOut(fiber)) return;

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
        _recordContexts(fiber);
      case FragmentNode f:
        fiber.vnode = f;
        _reconcileChildren(fiber, hostParent, f.children);
        _recordContexts(fiber);
      case ProviderNode p:
        // A new value has to be seen by every `useContext` below, whether or
        // not the vnodes in between changed. Memoize the value (so it stays
        // `identical`) and the subtree keeps its bailouts.
        final changed = !identical(fiber.providerValue, p.value);
        fiber.providerValue = p.value;
        fiber.vnode = p;
        if (changed) _changedContexts.add(p.context);
        try {
          _reconcileChildren(fiber, hostParent, p.children);
        } finally {
          if (changed) _changedContexts.removeLast();
        }
        _recordContexts(fiber);
      case ComponentNode c:
        // `memo`: same props as last time means the same output, so skip the
        // render and everything under it. Never while a provider above changed
        // (the props can be equal and the context still new), and never for a
        // fiber with its own pending update — that one still needs to run.
        final areEqual = memoEqualityOf(c.component);
        if (areEqual != null &&
            !fiber.dirty &&
            _mayBailOut(fiber) &&
            areEqual((fiber.vnode as ComponentNode).props, c.props)) {
          fiber.vnode = c;
          return;
        }
        fiber.vnode = c;
        _reconcileChildren(fiber, hostParent, [_renderComponent(fiber, c)]);
        _recordContexts(fiber);
      case ComponentProps p:
        // The same bailout, with the arguments compared field by field instead
        // of key by key. `@memoized` opts in.
        if (p.memoized &&
            !fiber.dirty &&
            _mayBailOut(fiber) &&
            fieldsEqual((fiber.vnode as ComponentProps).fields, p.fields)) {
          fiber.vnode = p;
          return;
        }
        fiber.vnode = p;
        _reconcileChildren(fiber, hostParent, [_renderComponent(fiber, p)]);
        _recordContexts(fiber);
    }
  }

  void _rerender(Fiber fiber) {
    final v = fiber.vnode;
    if (v is! ComponentNode && v is! ComponentProps) return;
    final rendered = _renderComponent(fiber, v);
    _reconcileChildren(fiber, _hostParentOf(fiber), [rendered]);
    _recordContexts(fiber);
  }

  /// Runs [c], which is a [ComponentNode] or a [ComponentProps].
  VNode _renderComponent(Fiber fiber, VNode c) {
    // Running the component reads the latest hook state, so whatever made this
    // fiber dirty is now accounted for — however we got here.
    fiber.dirty = false;
    // What it reads this time, not last time: a component may stop using a
    // context, and keeping the stale entry would only cost it bailouts.
    fiber.ownContexts.clear();
    final prev = Dispatcher.current;
    final dispatcher = _FiberDispatcher(this, fiber);
    Dispatcher.current = dispatcher;
    try {
      if (c is ComponentProps) {
        // The first render of a component with a scoped stylesheet is what puts
        // that stylesheet on the page. Later renders cost a set lookup.
        final css = c.styles;
        if (css != null) adoptStyles(css);
      }
      final out = switch (c) {
        ComponentProps p => p.build(),
        ComponentNode n => n.component(n.props),
        _ => throw StateError('reactx: $c is not a component'),
      };
      assert(_hooksBalanced(fiber, dispatcher, c));
      return out;
    } catch (error) {
      // Dart's stack trace names the closure, not the component, and says
      // nothing about where it sits in the tree. Print that before rethrowing
      // the original error untouched.
      assert(warn('${_nameOf(c)} threw during render.\n'
          '  in ${_treePath(fiber)}'));
      rethrow;
    } finally {
      Dispatcher.current = prev;
    }
  }

  /// Every render of a component must call the same hooks in the same order.
  /// Calling fewer means one is behind a condition — the next render would read
  /// another hook's slot.
  bool _hooksBalanced(Fiber fiber, _FiberDispatcher d, VNode c) {
    if (d.index == fiber.hooks.length) return true;
    throw StateError(
      'reactx: ${_nameOf(c)} called ${d.index} hooks this render but '
      '${fiber.hooks.length} last time. Hooks must run in the same order every '
      'render — move the conditional inside the hook, not around it.\n'
      '  in ${_treePath(fiber)}',
    );
  }

  /// `App > Layout > TodoList`, for diagnostics.
  String _treePath(Fiber fiber) {
    final names = <String>[];
    for (Fiber? f = fiber; f != null; f = f.parent) {
      final name = _nameOf(f.vnode);
      if (name != null) names.add(name);
    }
    return names.reversed.join(' > ');
  }

  /// The component's name, or null when [v] is not a component.
  static String? _nameOf(VNode v) => switch (v) {
        ComponentProps p => p.name,
        ComponentNode n => n.name,
        _ => null,
      };

  // -- Children reconciliation (keyed) ---------------------------------------

  void _reconcileChildren(Fiber parent, Object hostParent, List<VNode> next) {
    assert(_keysAreUnique(parent, next));
    final anchor = parent.vnode is ElementNode ? null : _nextHostAnchor(parent);
    final old = parent.children;

    // Every component render lands here with exactly one child, and the
    // overwhelming majority of those match the child that is already there.
    // Doing that case without four collection allocations is worth the branch.
    if (old.length == 1 && next.length == 1) {
      final only = old.first;
      if (_compatible(only, next.first)) {
        _update(only, next.first, hostParent, anchor);
        return;
      }
    }

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

    // Whether anything actually moved. Reordering costs two host reads per node
    // plus a list per fiber, and a list that only had its contents *updated* —
    // by far the common case — does not need any of it.
    var moved = old.length != next.length;

    for (final v in next) {
      Fiber? match;
      if (v.key != null) {
        final cand = keyed[v.key!];
        // `!matched.contains` is what stops two children with the same key from
        // both adopting one fiber — which would render only the last of them
        // and, on the next pass, unmount that fiber twice.
        if (cand != null && !matched.contains(cand) && _compatible(cand, v)) {
          match = cand;
        }
      } else {
        while (cursor < unkeyed.length) {
          final cand = unkeyed[cursor++];
          if (matched.contains(cand)) continue;
          if (_compatible(cand, v)) match = cand;
          break;
        }
      }

      if (match != null) {
        final index = result.length;
        if (index >= old.length || !identical(old[index], match)) moved = true;
        matched.add(match);
        _update(match, v, hostParent, anchor);
        result.add(match);
      } else {
        moved = true;
        result.add(_mount(v, parent, hostParent, anchor));
      }
    }

    for (final f in old) {
      if (!matched.contains(f)) _unmount(f);
    }

    parent.children = result;
    if (moved) _placeInOrder(parent, hostParent, anchor);
  }

  /// Two siblings with the same key make the keyed diff match the wrong one,
  /// which shows up as a row keeping another row's state. Cheap to detect and
  /// impossible to guess from the symptom.
  bool _keysAreUnique(Fiber parent, List<VNode> children) {
    final seen = <Object>{};
    for (final child in children) {
      final key = child.key;
      if (key == null || seen.add(key)) continue;
      warn('duplicate key "$key" among siblings in ${_treePath(parent)}. '
          'Keys must be unique between siblings, or the reconciler will pair '
          'up the wrong nodes.');
    }
    return true;
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
    // Children first: a cleanup that releases something its parent's cleanup
    // also touches has to run while the parent is still whole. React unmounts
    // depth-first for the same reason.
    for (final c in fiber.children) {
      _unmount(c);
    }
    for (final h in fiber.hooks) {
      if (h is _EffectHolder) {
        h.cleanup?.call();
        h.cleanup = null;
      } else if (h is _Subscription) {
        h.cell.subscribers.remove(fiber);
      } else if (h is _Selection) {
        h.cell.selections.remove(h);
      }
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
        _bind(fiber, node, name, value as Function);
        return;
      }
      // An `on…` prop that stops being a function — `onClick={enabled ? f :
      // null}` — has to be unbound, or the old handler keeps firing.
      if (_isEvent(name, old)) _detach(fiber, node, name);
      if (identical(old, value) || old == value) return;
      _setAttr(node, name, value);
    });

    // A ref that is swapped out or dropped while the element stays mounted has
    // to be cleared, or it keeps pointing at a node its owner believes it has
    // let go of — and a null check on `current` stops meaning "detached".
    final ref = newProps['ref'];
    final oldRef = oldProps['ref'];
    if (oldRef is Ref && !identical(oldRef, ref)) oldRef.current = null;
    if (ref is Ref && !identical(oldRef, ref)) ref.current = node;

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

  /// Points the trampoline for `on…` prop [name] at [fn], registering it with
  /// the host the first time only.
  ///
  /// Inline closures — `onClick={() => setCount(c + 1)}` — are a fresh object
  /// every render, so comparing identity to decide whether to re-bind means
  /// re-binding always. Instead the registered listener is a stable trampoline
  /// that reads the current handler out of the fiber, so a re-render is a map
  /// write rather than a `removeEventListener` + `addEventListener` per prop.
  void _bind(Fiber fiber, Object node, String name, Function fn) {
    final type = name.substring(2).toLowerCase();
    fiber.handlers[type] = fn;
    if (fiber.listeners.containsKey(type)) return;

    void trampoline(Object event) {
      final current = fiber.handlers[type];
      if (current != null) _invokeHandler(current, event);
    }

    fiber.listeners[type] = trampoline;
    host.addEventListener(node, type, trampoline);
  }

  void _detach(Fiber fiber, Object node, String name) {
    final type = name.substring(2).toLowerCase();
    fiber.handlers.remove(type);
    final l = fiber.listeners.remove(type);
    if (l != null) host.removeEventListener(node, type, l);
  }

  // -- Scheduler -------------------------------------------------------------

  void _markDirty(Fiber f) {
    if (f.unmounted) return;
    f.dirty = true;
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
          // Shallowest first, and skip anything a dirty ancestor already
          // refreshed on its way down — `_renderComponent` clears the flag.
          if (!f.unmounted && f.dirty) _rerender(f);
        }
      }
      _flushEffects();
    } while (_dirty.isNotEmpty);
  }

  void _flushEffects() {
    // Two passes, not one interleaved loop: every cleanup in the batch runs
    // before any of the new effects. Otherwise a parent's new effect can
    // acquire a resource that a child's old cleanup then releases — React
    // orders destroys before creates for exactly this reason.
    void run(List<(Fiber, _EffectHolder)> q) {
      final items = List.of(q);
      q.clear();
      for (final (f, h) in items) {
        h.queued = false;
        if (f.unmounted) continue;
        h.cleanup?.call();
        h.cleanup = null;
      }
      for (final (f, h) in items) {
        if (f.unmounted) continue;
        final result = h.pending?.call();
        h.pending = null;
        // Only a zero-arg function is a valid cleanup. Anything else (a Future
        // from an async effect, a value, a function needing args) is ignored,
        // rather than crashing later when we'd try to call it.
        h.cleanup = result is Cleanup ? result : null;
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
      // Identity is the generated props type, which is one per component. That
      // is stabler than a closure: it survives a hot reload, so state is kept
      // across an edit rather than remounted.
      ComponentProps p => fv.runtimeType == p.runtimeType,
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

  T _slot<T>(String kind, T Function() create) {
    assert(_sameHookAsLastTime(kind));
    if (index >= fiber.hooks.length) fiber.hooks.add(create() as Object);
    return fiber.hooks[index++] as T;
  }

  /// Checks that slot [index] is being claimed by the same hook as on the
  /// previous render. Assert-only; the list is not even maintained in release.
  bool _sameHookAsLastTime(String kind) {
    final kinds = fiber.hookKinds;
    if (index >= kinds.length) {
      kinds.add(kind);
      return true;
    }
    if (kinds[index] == kind) return true;
    throw StateError(
      'reactx: hook #${index + 1} was $kind this render but ${kinds[index]} '
      'last render. Hooks must be called unconditionally, in the same order, '
      'every time — a hook inside an `if` or a loop reads the wrong slot.',
    );
  }

  @override
  (T, StateSetter<T>) useState<T>(T Function() init) {
    final holder = _slot<_StateHolder<T>>('useState', () {
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
    final holder = _slot<_ReducerHolder<S, A>>('useReducer', () {
      final h = _ReducerHolder<S, A>(init(), reducer);
      h.setter = (dynamic action) {
        // `h.reducer`, not the captured `reducer`: a reducer that closes over
        // props or context is a different function on every render, and the
        // one from the mount render would be permanently stale.
        final next = h.reducer(h.value, action as A);
        if (identical(h.value, next) || h.value == next) return;
        h.value = next;
        root._markDirty(fiber);
      };
      return h;
    });
    holder.reducer = reducer;
    return (holder.value, (A action) => holder.setter(action));
  }

  @override
  void useEffect(EffectCallback effect, List<Object?>? deps, {required bool layout}) {
    assert(_sameHookAsLastTime(layout ? 'useLayoutEffect' : 'useEffect'));
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
    assert(_sameHookAsLastTime('useMemo'));
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
    final holder =
        _slot<_RefHolder<T>>('useRef', () => _RefHolder<T>(Ref<T>(initial)));
    return holder.ref;
  }

  @override
  (S, void Function(A)) useStore<S, A>(Store<S, A> store) {
    final cell = root._cellFor(store as Store<Object?, Object?>);
    _slot<_Subscription>('useStore', () {
      cell.subscribers.add(fiber);
      return _Subscription(cell);
    });
    return (cell.state as S, _dispatcherFor<S, A>(store, cell));
  }

  @override
  T useSelect<S, A, T>(Store<S, A> store, T Function(S state) select) {
    final cell = root._cellFor(store as Store<Object?, Object?>);
    final selection = _slot<_Selection>('useSelect', () {
      final s = _Selection(cell, fiber, (raw) => select(raw as S), null);
      cell.selections.add(s);
      return s;
    });
    // The closure is new on every render; keep the latest so a selector that
    // captures a prop cannot go stale.
    selection.select = (raw) => select(raw as S);
    final value = select(cell.state as S);
    // Remember what was rendered, so the next dispatch compares against it.
    selection.last = value;
    return value;
  }

  @override
  void Function(A) useDispatch<S, A>(Store<S, A> store) {
    final cell = root._cellFor(store as Store<Object?, Object?>);
    return _dispatcherFor<S, A>(store, cell);
  }

  /// One dispatch closure per store per root, so its identity is stable.
  void Function(A) _dispatcherFor<S, A>(Store<S, A> store, _StoreCell cell) =>
      (cell.dispatch ??= (A action) =>
          root._dispatchToStore(store as Store<Object?, Object?>, action))
      as void Function(A);

  @override
  T useContext<T>(Context<T> context) {
    // Recorded so an ancestor provider that changes knows whether this subtree
    // can be skipped. Reading is the subscription.
    fiber.ownContexts.add(context as Context<Object?>);
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
