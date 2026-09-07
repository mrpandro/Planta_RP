# qb-czcraft — Testing

## Web (Vitest + React Testing Library)

### Scope

The NUI web app tests cover these layers:

| Layer | File | Tests | What's covered |
|-------|------|-------|----------------|
| API wrapper | `api.test.ts` | 5 | nuiFetch POST format, request body, failure reason propagation, closeNUI fire-and-forget + error swallowing |
| Reducer | `reducer.test.ts` | 17 | All 9 action types (SET_PAGE, SET_MACHINE, SET_LOADING, SET_ERROR, SET_MACHINE_DATA, SET_STOCK, SET_BILLS, SET_RECIPES, SET_OVERVIEW), initial state, immutability |
| Forms/validation | `BillManagement.test.tsx` | 2 | Empty recipe selection rejected, target quantity < 1 rejected, fetch not called on validation failure |
| Block states | `BillManagement.test.tsx` | 6 | ACTIVE shows Pause+Remove, PAUSED shows Resume+Remove, REMOVED shows no actions, PENDING shows Remove only, blockReason displayed, no-data message |
| Permissions | `BillManagement.test.tsx` | 2 | Server returns success:false with reason → error displayed; successful bill action calls onBillsChanged with correct endpoint + body |
| Recipe filtering | `BillManagement.test.tsx` | 1 | Disabled recipes excluded from select options |

**Total: 33 tests (5 + 17 + 11)**

### Running

```
npm --prefix "resources/[meus-scripts]/qb-czcraft/web" test
npm --prefix "resources/[meus-scripts]/qb-czcraft/web" run typecheck
npm --prefix "resources/[meus-scripts]/qb-czcraft/web" run build
```

### Test infrastructure

- Vitest 3.2.7 with jsdom environment
- @testing-library/react 16.3.3 for component tests
- @testing-library/jest-dom for DOM matchers
- Global fetch mocked via `vi.stubGlobal('fetch', ...)` in tests that
  exercise the API layer
- Setup file: `src/__tests__/setup.ts` (imports jest-dom matchers)

### What's NOT tested (web)

- Visual rendering / CSS (no visual regression tests)
- i18n locale switching (default locale detection only)
- Full App component integration (reducer is tested in isolation;
  component wiring is covered by manual E2E)
- NUI bridge (client/nui.lua) — Lua-side, not web

## Lua (busted-compatible specs)

### Scope

- Config validation: feature flags, fixture caps, recipe catalog integrity
- Recipe hash/snapshot: fail-closed validation
- Schema gate: version check before resource startup
- Inventory batch: idempotent batch with PENDING/COMMITTED journal,
  tx_2 retry, generation counter
- Cycle completion: dedup-key affected-count gating

### Running

```
cd tests/lua
lua test_runner.lua
```

### Coverage

LuaCov coverage reports in `tests/lua/reports/`.
