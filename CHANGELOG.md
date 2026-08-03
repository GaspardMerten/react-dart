# Changelog

## 0.1.0

Initial release — React, reimplemented in pure Dart.

- Virtual DOM (`VNode`) with `h()` hyperscript and HTML element helpers.
- Function components with hooks: `useState`, `useReducer`, `useEffect`,
  `useLayoutEffect`, `useMemo`, `useCallback`, `useRef`, `useContext`.
- Context via `createContext` / providers.
- Host-agnostic reconciler: fiber tree, keyed reconciliation, effect
  scheduling, batched `act()`, and hydration — all testable headlessly through
  an in-memory `TestHost`.
- Server-side rendering: `renderToString` / `renderToDocument`.
- Browser client renderer over `package:web`: `runApp` / `hydrateApp`.
- `jsx(...)` template syntax: an HTML/JSX-like runtime compiler with a parse
  cache.
- Optional `build_runner` precompiler that turns `jsx(r'...')` calls into direct
  `h(...)` construction.
