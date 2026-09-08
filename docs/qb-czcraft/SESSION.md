# qb-czcraft — Session Log

## 2026-09-07: Pre-E2E gate review and fixes

### Issues identified

1. **Double-handler conflict**: qb-mechanicjob and simple-repair both
   registered `CreateUseableItem('repairkit', ...)`, conflicting with
   qb-czcraft's `QBCore:Client:UseItem` hook. Three repair flows triggered
   simultaneously when a player used a repairkit.

2. **Item-loss window**: The repairkit handler consumed the item BEFORE
   sending the repair-confirmation event. If the connection dropped between
   the two, the player lost their repairkit and the vehicle stayed broken.
   No rollback or journal recovery existed — inconsistent with the
   no-data-loss pattern used by every other saga.

3. **Thin web test coverage**: Only 5 tests existed, all covering the API
   wrapper. Reducers, form validation, block states, and permission-denied
   handling were untested.

4. **Combined commit**: NUI (Task 5) and repairkit (Task 6) landed in a
   single commit (d08a6ff), making it harder to bisect if either needed
   independent revert.

### Resolutions

1. **Handler conflict** — commented out `CreateUseableItem('repairkit')`
   in both qb-mechanicjob/server/main.lua and simple-repair/server.lua.
   qb-czcraft is now the sole repairkit handler. (commit fc1b509)

2. **Item-loss window** — moved the mechanical repair server-side
   (SetVehicleFixed + health natives) to run BEFORE the success event.
   The client success handler is now cosmetic-only (dirt + sound).
   If the event is lost, the vehicle is already repaired. (commit aef9135)

3. **Web test coverage** — added 28 new tests:
   - reducer.test.ts: 17 tests (all 9 action types, immutability)
   - BillManagement.test.tsx: 11 tests (form validation, block states,
     permission-denied, disabled-recipe filtering)
   Required exporting reducer/initialState/types from App.tsx.
   (commit 33903bb)

4. **Commit split** — d08a6ff split into:
   - f23b943: NUI dashboard (Task 5)
   - 1d33138: Repairkit handler (Task 6)
   (via git reset --mixed HEAD~1 + two selective commits)

### Commits this session

- f23b943 feat(qb-czcraft): add local NUI dashboard (v0.1 Task 5)
- 1d33138 feat(qb-czcraft): add server-authoritative repairkit handler (v0.1 Task 6)
- aef9135 fix(qb-czcraft): apply vehicle repair server-side to eliminate item-loss window
- fc1b509 fix: disable old repairkit handlers to resolve double-registration conflict
- 33903bb test(qb-czcraft): add reducer, form-validation, block-state, and permission tests
- (docs commit) docs(qb-czcraft): add decisions, AI memory, status, testing docs

### Next step

v0.1 E2E gate on staging.

## 2026-09-08: Missing cycle engine + E2E harness

### Critical blocker discovered and resolved

The scheduler tick (`server/scheduler_tick.lua`) fires
`TriggerEvent('qb-czcraft:internal:processMachine', uuid)` for due machines,
but **no handler existed** for that event. The scheduler was popping machines
and firing into the void — no cycle ever started or completed. The 254 unit
tests passed because they test pure domain functions and repos in isolation,
not the orchestration glue.

This means STATUS.md/TODO.md were inaccurate: "Part 4: scheduler tick wiring"
was listed as complete, but the wiring that actually calls the cycle engine
from the tick was never written.

### Implemented: `server/cycle_engine.lua`

The per-machine orchestrator. Two modes:
1. **Real-time**: machine has an active cycle whose `due_at <= now` → complete
   it (`CyclesRepo.complete`), increment the bill (`BillsRepo.incrementProduced`),
   start the next cycle (`CyclesRepo.start`) or go idle/blocked.
2. **Catch-up**: machine is STOPPED with `next_due_at` in the past → run the
   analytic multi-cycle catch-up in chunked batches via the new
   `CyclesRepo.applyCatchUpChunk` (one transaction per chunk: net stock deltas
   + aggregated production event + machine cursor advance), yielding between
   chunks, until caught up or blocked.

Supporting repo methods added:
- `CyclesRepo.applyCatchUpChunk` — batch catch-up (idempotent via
  `idempotency_key`, gated on event INSERT affected count like `complete`).
- `MachinesRepo.setBlocked` — sets BLOCKED + clears `next_due_at`.
- `MachinesRepo.clearNextDue` — clears `next_due_at` for idle machines.

Timezone-independent `parseIsoToUnix` (Howard Hinnant's `days_from_civil`) so
DB UTC datetimes parse correctly regardless of server timezone.

5 unit tests (mock repo layer): both modes + block/idle paths. All pass.
Full suite: 254 Lua + 33 web, 0 failures.

### Implemented: E2E/load harness (`resources/[meus-scripts]/qb-czcraft-e2e/`)

6 scenarios, all emit raw numbers:
- `repair_natives`: vehicle repair native precondition (gate safety property).
- `production_chain`: iron → steel → cz_metal_parts → cz_components →
  repairkit + MAINTAIN_X.
- `concurrent`: same/different machine concurrency + optimistic version
  conflicts.
- `failure_injection`: crash-after-saga-step recovery + idempotent
  re-completion.
- `downtime_catchup`: 24h+ downtime (sufficient + insufficient inputs).
- `load_test`: 1000 machines / 250 active + SLO probes (DB p95 < 200ms,
  action p95 < 300ms, no Lua stall > 50ms).

SLO utilities: p95/p99/max recorder, Lua stall detector, threshold assertions.
Command dispatcher: `cze2e <scenario|all>` from the server console.
See `qb-czcraft-e2e/README.md` for prerequisites and cleanup SQL.

### Not yet done

- **Run the harness against staging** — requires a live FiveM server + DB.
  The gate cannot close until raw staging output confirms the SLOs.
- **Push** — held per user decision until the gate passes.

### Files changed this session

- `resources/[meus-scripts]/qb-czcraft/server/cycle_engine.lua` (NEW)
- `resources/[meus-scripts]/qb-czcraft/server/repositories/cycles.lua` (added `applyCatchUpChunk`)
- `resources/[meus-scripts]/qb-czcraft/server/repositories/machines.lua` (added `setBlocked`, `clearNextDue`)
- `resources/[meus-scripts]/qb-czcraft/fxmanifest.lua` (added `cycle_engine.lua` before `scheduler_tick.lua`)
- `tests/lua/unit/qb-czcraft/cycle_engine_spec.lua` (NEW, 5 tests)
- `tests/lua/.generated_test_suites.txt` (added cycle_engine_spec)
- `resources/[meus-scripts]/qb-czcraft-e2e/` (NEW resource, 9 files)
- `docs/qb-czcraft/STATUS.md`, `TODO.md`, `SESSION.md`, `AI_MEMORY.md` (updated)
