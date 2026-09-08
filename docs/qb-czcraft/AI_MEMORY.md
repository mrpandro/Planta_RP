# qb-czcraft — AI Memory

Persistent project facts for AI agents working on qb-czcraft.

## Project location

- Resource: `resources/[meus-scripts]/qb-czcraft/`
- Docs: `docs/qb-czcraft/`
- Tests (Lua): `tests/lua/unit/qb-czcraft/`
- Tests (Web): `resources/[meus-scripts]/qb-czcraft/web/src/__tests__/`

## Architecture

- Server-authoritative: all mutations go through server-side validation.
  Clients propose; the server decides.
- No-data-loss pattern: every saga (inventory batch, cycle completion,
  placement, pickup, repairkit) must not lose player data on failure.
  See `concurrency.md` for the inventory batch PENDING/COMMITTED model.
- Data-driven: stats, recipes, and balance numbers live in `config/` and
  `shared/recipe_catalog.lua`, not hardcoded in logic.
- Feature flags in `config/general.lua` gate each subsystem.

## Key decisions

- **Repairkit**: server-side repair before success event (ADR-001 in
  `decisions.md`). No item-loss window.
- **Sole handler**: qb-czcraft is the only repairkit handler. Old
  registrations in qb-mechanicjob and simple-repair are commented out
  (ADR-002).
- **NUI**: React 19 + Vite 6 + TypeScript 5, `useReducer` (no external
  state library), plain CSS (no framework), i18n en/pt.
- **NUI security**: server never sends recipe data to NUI — only intent +
  IDs. All NUI callbacks gated by session + ownership + access checks.

## Test commands

- Web: `npm --prefix "resources/[meus-scripts]/qb-czcraft/web" test`
- Web typecheck: `npm --prefix "resources/[meus-scripts]/qb-czcraft/web" run typecheck`
- Web build: `npm --prefix "resources/[meus-scripts]/qb-czcraft/web" run build`
- Lua: `lua tests/lua/test_runner.lua` (run from repo root, not tests/lua/)
  - Exclude broken suites: `$env:TEST_SUITE_EXCLUDE_PATTERN="qb-weapons"` (PowerShell)
  - The `qb-weapons/aiming_logic_spec.lua` suite references a missing file;
    exclude it — it's unrelated to qb-czcraft.

## Test coverage (web)

- API wrapper: 5 tests (`api.test.ts`) — nuiFetch POST, body, failure, closeNUI
- Reducer: 17 tests (`reducer.test.ts`) — all 9 action types, immutability
- BillManagement: 11 tests (`BillManagement.test.tsx`) — form validation,
  block states, permission-denied, disabled-recipe filtering
- Total: 33 tests

## Test coverage (Lua)

- 254 tests total (including 5 cycle_engine_spec tests added 2026-09-08).
- Cycle engine tests use a mock repo layer (in-memory state) since the
  orchestrator integrates pure domain + repos + FiveM globals.
- The `cycle_engine_spec.lua` stubs `CreateThread` (synchronous), `Wait`,
  `RegisterNetEvent`, `AddEventHandler`, and `os.time` (fixed clock) for
  deterministic testing under stock Lua 5.4.

## Cycle engine (processMachine handler)

- **Critical**: `server/cycle_engine.lua` is the orchestrator that the
  scheduler tick fires via `qb-czcraft:internal:processMachine`. Without it,
  the scheduler pops machines but nothing happens — no cycle starts/completes.
- Two modes: real-time completion (active cycle due) + chunked catch-up
  (STOPPED machine with past `next_due_at`).
- Catch-up uses `CyclesRepo.applyCatchUpChunk` — ONE transaction per chunk
  (net stock deltas + aggregated production event + machine cursor advance).
  This is the SLO-critical path: per-cycle start/complete would be 2N txs.
- `parseIsoToUnix` uses `days_from_civil` (timezone-independent) — do NOT
  replace with `os.time(table)` which interprets as local time.
- Loaded in fxmanifest AFTER nui_api/repairkit, BEFORE scheduler_tick.

## E2E/load harness

- Resource: `resources/[meus-scripts]/qb-czcraft-e2e/`
- Command: `cze2e <scenario|all>` from the server console (not in-game).
- Requires: live FiveM server + DB + at least one player online.
- 6 scenarios: repair_natives, production_chain, concurrent,
  failure_injection, downtime_catchup, load_test.
- All emit raw numbers (timings, stock counts, event counts, percentiles).
- Cleanup SQL in `qb-czcraft-e2e/README.md`.

## Commit discipline

- One logical change per commit. NUI and repairkit are separate commits
  for bisectability (split on 2026-09-07 from a combined commit).
- Commit message format: `type(scope): summary` with body explaining why.

## Server.cfg resource loading

- `ensure [qb]` loads all resources in `resources/[qb]/` (including
  qb-mechanicjob).
- `ensure [meus-scripts]` loads all resources in `resources/[meus-scripts]/`
  (including simple-repair and qb-czcraft).
- To disable a resource loaded via folder ensure, comment out its
  registration code (e.g., `CreateUseableItem`) rather than removing the
  folder.
