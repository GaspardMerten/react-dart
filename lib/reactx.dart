/// reactx — React, reimagined in pure Dart.
///
/// This barrel is platform-neutral: it contains the virtual DOM, component
/// model, hooks, the reconciler, the in-memory host, the `jsx` template
/// syntax, and the server-side renderer. It has **no** browser dependency, so
/// it runs on the Dart VM (tests, servers, SSR).
///
/// For the browser client renderer (mounting + hydration into the real DOM),
/// import `package:reactx/dom.dart` from a web entrypoint.
library;

export 'src/context.dart';
export 'src/diagnostics.dart' show reactxWarning, resetWarnings;
export 'src/elements.dart';
export 'src/escape.dart' show escapeForScript;
export 'src/hooks.dart' show
    Ref,
    Cleanup,
    EffectCallback,
    StateSetter,
    useState,
    useStateLazy,
    useReducer,
    useEffect,
    useLayoutEffect,
    useMemo,
    useCallback,
    useRef,
    useContext,
    useStore,
    useSelect,
    useDispatch;
export 'src/host.dart' show HostAdapter, TestHost, TestNode;
export 'src/jsx.dart' show jsx, registerCompiledTemplate;
export 'src/reconciler.dart' show Root, Fiber, createRoot;
export 'src/ssr.dart' show renderToString, renderToDocument;
export 'src/store.dart' show Store, defineStore;
export 'src/styles.dart' show resetAdoptedStyles;
export 'src/vdom.dart';
