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

## 2026-09-09: Harness verdict bugs found and fixed — all prior E2E results retracted

### Discovery: the "mystery auto-triggering process"

The user flagged that an unidentified process was repeatedly triggering
`cze2e all` on the live server, combined with RCON not matching its own
config file — two signs the running server's state didn't match disk.

Investigation:
- No Python processes running. No txAdmin scheduled tasks. WireMCP
  (a Wireshark/tshark MCP server) was running but unrelated to FiveM.
- The server was cleanly restarted at 04:17 today (new PIDs, old ones gone).
- The `e2e_command.txt` file had `all` (3 bytes, mtime yesterday) and was
  never truncated by the poller.
- The log showed 340+ `cze2e all` runs in ~4 minutes, each completing
  instantly (all scenarios failing with "no players online").
- Truncating the file from PowerShell stopped the loop immediately.

**Root cause**: the file-IPC poller in `e2e_run.lua` used
`io.open(COMMAND_FILE, 'w')` to truncate the command file after reading.
This silently fails on bracketed paths (`[meus-scripts]`) in FiveM's
sandboxed I/O. The file was never consumed, so the poller re-executed
the same command every second indefinitely. No external process —
self-inflicted by the harness.

### Discovery: RCON config drift explained

`server.cfg` has `rcon_password "cze2e_rcon_2026"` but the live server
returns "The server must set rcon_password." This is not a stale process
or config-not-applied — it's txAdmin server mode. The command line
includes `+set txAdminServerMode true`, which takes over server
administration via its own web interface (port 40120) and does not pass
through the Quake-3 RCON password. RCON is effectively disabled under
txAdmin. Use the txAdmin web interface, in-game menu, or server console.

### Discovery: OVERALL: PASS verdict bug (critical)

While investigating, found that all 6 scenarios showed FAIL ("no players
online") but the report said `OVERALL: PASS`. The root cause is in
`runAll` (line 224): when a scenario returns `false`, `pcall` returns
`(true, false)` — `runOk=true`, `runErr=false`. The code set
`results[name] = runErr` (correctly recording false) but **never set
`allPass = false`**. The `allPass` flag was only updated on crash or
load-failure, not on a scenario returning false.

**This means every prior `OVERALL: PASS` in the project's history was
"nothing crashed," not "everything passed." The verdict line was never
trustworthy for any run, ever.** All prior E2E results are retracted.

### Fixes applied (3 bugs)

1. **allPass verdict bug** (`e2e_run.lua`):
   - Extracted the execution loop into `executeScenarios(scenarios, order,
     emitFn)` — a pure function that takes a scenarios table, order list,
     and emit function, returns `(results, allPass)`.
   - Added `if not runErr then allPass = false end` at the false-return
     path (line 229).
   - Exported as `CZE2E._executeScenarios` for unit testing.
   - Also fixed the identical bug in `qb-czcraft-e2e/server/runner.lua`
     (line 82) — not loaded currently, but has the same code.

2. **Poller infinite loop** (`e2e_run.lua` file-IPC poller):
   - Replaced `io.open(COMMAND_FILE, 'w')` with `os.remove` (primary) +
     `io.open` write-mode (fallback) + skip-execution guard if both fail.
   - If consumption fails, the poller logs a WARNING and skips execution
     instead of re-executing the same command forever.

3. **Player-online precondition** (`e2e_run.lua` `runAll`):
   - Added `GetPlayers()` check at the top of `runAll`. If no player is
     online, it emits `PRECONDITION FAILED`, `OVERALL: FAIL`, and returns
     false — instead of running all 6 scenarios into a guaranteed-failure
     no-op.

### Regression test

`tests/lua/unit/qb-czcraft/e2e_verdict_spec.lua` (8 tests):
- scenario returning false → allPass=false (the core regression)
- scenario returning true → allPass=true
- scenario that crashes → allPass=false
- scenario that fails to load → allPass=false
- mixed pass/fail → allPass=false
- all pass → allPass=true
- unknown scenario → allPass=false
- emit receives per-scenario lines

All 8 pass. Full qb-czcraft suite: 222 tests, 0 failures.

### Additional findings (not yet fixed)

- **load_test measurement scope**: action dispatch p95=0ms times
  `TriggerEvent` (returns immediately), not end-to-end completion. The
  stall detector wraps only the dispatch call — a real 236ms engine hitch
  during provisioning was missed. "No Lua stall > 50ms" is true for the
  measured segment, false for the run as a whole.
- **UNSIGNED stock-decrement**: `quantity - 5` on an UNSIGNED column
  errors before the `>= 0` guard protects it. Fail-closed by accident,
  via errors. Needs a dedicated fix + regression test.
- **Dirty-state flapping**: harness doesn't clean up its own DB rows.
  `load_test` bill IDs use `math.random` 6-digit suffixes that collide
  on repeated runs. Clean run → PASS, immediate re-run → FAIL (Duplicate
  entry on `czcraft_bills.PRIMARY`).
- **e2e_run.lua merged into qb-czcraft**: the harness runner lives inside
  qb-czcraft proper, so "unload the harness" is structurally impossible.
  Must be separated or gated behind a feature flag.

### Additional fixes (2026-09-09, same session)

All four remaining harness issues were also fixed:

- **UNSIGNED stock-decrement**: `quantity - ?` and `quantity + ?` on
  UNSIGNED columns underflowed before the `>= 0` guard. Fixed with
  `CAST(quantity AS SIGNED)` in WHERE clauses (`stock.lua`, `cycles.lua`)
  and `quantity >= ?` in `applyCatchUpChunk`. Regression test:
  `unsigned_guard_spec.lua` (10 static-analysis tests).
- **Dirty-state flapping**: `Slo.uniqueId()` replaces `math.random` for
  bill/cycle/machine IDs. `Slo.cleanup()` auto-deletes e2e-prefixed rows
  before `cze2e all`. No more collisions on repeated runs.
- **load_test measurement scope**: end-to-end completion p95 replaces
  dispatch-only p95. Stall detector now covers provisioning + settle-wait.
  The SLO threshold applies to completion, not dispatch.
- **Harness gating**: poller + cze2e command gated behind
  `GetResourceState('qb-czcraft-e2e')`. Stopping the resource fully
  disables the harness for the manual playtest.

### Files changed this session

- `resources/[meus-scripts]/qb-czcraft/server/e2e_run.lua` (3 bug fixes +
  extract executeScenarios + export for testing + harness gating)
- `resources/[meus-scripts]/qb-czcraft-e2e/server/runner.lua` (same
  allPass verdict fix — not loaded currently, but has identical code)
- `resources/[meus-scripts]/qb-czcraft-e2e/server/slo.lua` (uniqueId +
  cleanup functions)
- `resources/[meus-scripts]/qb-czcraft-e2e/server/scenarios/*.lua`
  (replaced all math.random with Slo.uniqueId, added local Slo to concurrent.lua)
- `resources/[meus-scripts]/qb-czcraft-e2e/README.md` (updated cleanup docs)
- `resources/[meus-scripts]/qb-czcraft/server/repositories/stock.lua`
  (CAST AS SIGNED in WHERE guards)
- `resources/[meus-scripts]/qb-czcraft/server/repositories/cycles.lua`
  (CAST AS SIGNED + quantity >= ? guards)
- `resources/[meus-scripts]/qb-czcraft-e2e/server/scenarios/load_test.lua`
  (end-to-end completion timing + provisioning stall detector)
- `tests/lua/unit/qb-czcraft/e2e_verdict_spec.lua` (NEW, 8 regression tests)
- `tests/lua/unit/qb-czcraft/unsigned_guard_spec.lua` (NEW, 10 tests)
- `docs/qb-czcraft/STATUS.md`, `TODO.md`, `SESSION.md`, `AI_MEMORY.md`
  (all prior E2E results retracted, gate remains open)

### Test results

- 232 Lua tests pass (0 failures)
- 33 web tests pass (unchanged)
- Full repo Lua suite still exits nonzero due to pre-existing
  qb-inventory/qb-weapons broken suites (unrelated to qb-czcraft)

### Next steps

1. Restart qb-czcraft via txAdmin to load the fixes.
2. Re-run `cze2e all` with a player online — first trustworthy verdict.
3. Harness-removed manual playtest (requires human at game client):
   stop qb-czcraft-e2e, place machines, run chain, test repairkit.
4. Decide rollout checklist items (audit/security/admin/rollback).
