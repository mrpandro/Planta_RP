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

- 232 tests total (including 5 cycle_engine_spec + 8 e2e_verdict_spec +
  10 unsigned_guard_spec tests added 2026-09-08/09).
- Cycle engine tests use a mock repo layer (in-memory state) since the
  orchestrator integrates pure domain + repos + FiveM globals.
- The `cycle_engine_spec.lua` stubs `CreateThread` (synchronous), `Wait`,
  `RegisterNetEvent`, `AddEventHandler`, and `os.time` (fixed clock) for
  deterministic testing under stock Lua 5.4.
- `e2e_verdict_spec.lua` tests the extracted `executeScenarios` function
  with stub scenarios (pass, fail, crash, load-fail, mixed, unknown).
- `unsigned_guard_spec.lua` is a static-analysis test that reads the repo
  source files and verifies WHERE clauses don't use unguarded UNSIGNED
  arithmetic (the `CAST(... AS SIGNED)` pattern or `>= ?` guard).

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
- **CRITICAL**: All prior E2E results are retracted (2026-09-09). Three
  harness bugs were found and fixed:
  1. allPass verdict bug: scenario returning false never set allPass=false.
  2. Poller infinite loop: io.open write-mode fails on [meus-scripts] paths.
  3. No player-online precondition: all scenarios silently no-opped.
  Four additional issues were also fixed:
  4. Dirty-state flapping: math.random bill IDs collided on repeated runs.
  5. UNSIGNED stock-decrement: quantity - ? underflowed before >= 0 guard.
  6. load_test measurement: dispatch p95 measured TriggerEvent, not completion.
  7. Harness gating: poller + command now gated behind GetResourceState.
  See STATUS.md and SESSION.md (2026-09-09) for details.
- The actual runner lives in `qb-czcraft/server/e2e_run.lua` (merged into
  qb-czcraft), NOT in `qb-czcraft-e2e/server/runner.lua` (which is not
  loaded by the fxmanifest). The poller and cze2e command are now gated
  behind `GetResourceState('qb-czcraft-e2e')` — stopping qb-czcraft-e2e
  fully disables the harness for the manual playtest.
- `repair_natives` PASS confirms only server-side preconditions (vehicle
  networking, GetEntityType==2, no-op behavior, handler structure). It does
  NOT test the full client-side repair flow — the scenario says so itself.

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

## Server runtime (txAdmin)

- The live server runs under txAdmin server mode
  (`+set txAdminServerMode true` in the command line).
- **RCON is unavailable**: txAdmin does not pass through `rcon_password`
  from server.cfg. Use the txAdmin web interface (port 40120), in-game
  menu, or server console for commands.
- txAdmin web interface: `http://127.0.0.1:40120/`
- Server data path: `C:/DEV/NewRP/Planta_RP/` (confirmed via txAdmin config).
- Server log: `C:\DEV\txData\default\logs\fxserver.log` (held open by
  FXServer — use shared-read methods like `Get-Content -Tail`).
- PowerShell: paths containing `[meus-scripts]` or `[qb]` need
  `-LiteralPath` to avoid wildcard interpretation.
