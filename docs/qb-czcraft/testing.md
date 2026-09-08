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
- **Cycle engine orchestration** (NEW): processMachine handler with mock
  repos — real-time completion, catch-up to completion, block on inputs,
  idle on no bill, premature-wake re-heap.

### Running

```
lua tests/lua/test_runner.lua
```

Run from the **repo root**, not `tests/lua/` — the runner reads
`tests/lua/.generated_test_suites.txt` with paths relative to root.

Exclude broken/unrelated suites (PowerShell):
```
$env:TEST_SUITE_EXCLUDE_PATTERN="qb-weapons"
lua tests/lua/test_runner.lua
```

The `qb-weapons/aiming_logic_spec.lua` suite references a missing file
(`resources/[qb]/qb-weapons/client/aiming_logic.lua`); exclude it. It is
unrelated to qb-czcraft.

### Coverage

LuaCov coverage reports in `tests/lua/reports/`.

**Total: 254 tests** (249 + 5 cycle_engine_spec).

## Live staging E2E (qb-czcraft-e2e resource)

### Scope

These are **live tests against a real FiveM server + database**, not unit
tests. They exercise the full server-authoritative stack: processMachine →
domain → repos → MySQL → scheduler re-heap. All scenarios emit raw numbers
(timings, stock counts, event counts, percentile breakdowns).

### Prerequisites

1. FiveM staging server with `qb-czcraft` loaded and ready (schema migrated).
2. At least one player online (vehicle spawn anchor + owner citizenid).
3. Staging DB you can dirty (cleanup SQL in `qb-czcraft-e2e/README.md`).
4. `server.cfg`: `ensure qb-czcraft` then `ensure qb-czcraft-e2e`.

### Running

From the **server console** (not in-game):

```
cze2e repair_natives        # vehicle repair native precondition
cze2e production_chain      # iron -> steel -> parts -> components -> repairkit + MAINTAIN_X
cze2e concurrent            # same/different machine concurrency + version conflicts
cze2e failure_injection     # crash-after-saga-step recovery + idempotent re-completion
cze2e downtime_catchup      # 24h+ downtime catch-up (sufficient + insufficient inputs)
cze2e load_test             # 1000 machines / 250 active + SLO probes
cze2e all                   # run all scenarios in order
```

### SLO thresholds

| SLO | Threshold | Measured by |
|-----|-----------|-------------|
| DB p95 | < 200ms | stock load timings (50 samples post-run) |
| Action p95 | < 300ms | processMachine dispatch timings |
| Recovery | < 60s | failure_injection crash recovery |
| Lua stall | < 50ms | stall detector wrapping event dispatch |

### Output

Every scenario prints raw measurements prefixed with `[E2E]`. SLO verdicts
print `[E2E][SLO] ... PASS` or `[E2E][SLO] ... FAIL`. Capture the server
console log to retain the raw output for the gate record.

### What this harness does NOT do

- Web/NUI unit tests (use Vitest, above).
- Repairkit item flow end-to-end (requires a client-side test driver). The
  `repair_natives` scenario verifies the server-side native precondition.
- Automatic DB cleanup (run the cleanup SQL in `qb-czcraft-e2e/README.md`).
