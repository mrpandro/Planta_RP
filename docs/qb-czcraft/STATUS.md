# qb-czcraft — Status

**Last updated:** 2026-09-09

## CRITICAL: All prior E2E results retracted

On 2026-09-09, three harness bugs were discovered that invalidate every
prior E2E run:

1. **allPass verdict bug** (`e2e_run.lua:224`): when a scenario returned
   `false`, `pcall` returned `(true, false)` — the code recorded `false`
   in `results[name]` but never set `allPass = false`. The `allPass` flag
   was only updated on crash or load-failure. This means every prior
   `OVERALL: PASS` was "nothing crashed," not "everything passed." The
   verdict line was never trustworthy for any run, ever.

2. **Poller infinite loop** (`e2e_run.lua` file-IPC poller): the poller
   used `io.open(COMMAND_FILE, 'w')` to truncate the command file after
   reading, but this silently fails on bracketed paths (`[meus-scripts]`)
   in FiveM. The file was never consumed, so the poller re-executed the
   same command every second indefinitely. On 2026-09-09, 340+ `cze2e all`
   runs were logged in ~4 minutes, all failing with "no players online"
   but reporting `OVERALL: PASS` due to bug #1.

3. **No player-online precondition**: `runAll` did not check for an
   online player before executing scenarios. Without a player, every
   scenario silently no-ops with "no players online" — the run is
   meaningless. Combined with bug #1, this produced `OVERALL: PASS` for
   runs where nothing actually happened.

All three bugs are fixed (see SESSION.md 2026-09-09). A regression test
(`tests/lua/unit/qb-czcraft/e2e_verdict_spec.lua`, 8 tests) confirms the
verdict logic. The fixes are on disk but not yet loaded on the live
server — a resource restart via txAdmin is required before re-running.

**All prior E2E results — including every "PASS" discussed in previous
sessions — are retracted pending re-verification under the corrected
verdict logic.** The v0.1 gate is NOT closed.

## v0.1 feature flags

| Flag | State | Notes |
|------|-------|-------|
| placement | enabled | |
| bills | enabled | |
| production | enabled | |
| scheduler | enabled | |
| nui | enabled | Local dashboard (4 pages) |
| repairkit | enabled | Server-authoritative, sole handler |
| storageTransfers | disabled | Future task |
| admin | disabled | Future task |

## Completed (v0.1)

- **Part 1**: Placement + pickup (server-authoritative, ghost prop, raycast)
- **Part 2**: Recipe hash/snapshot + fail-closed validation
- **Part 3**: Bills + cycle engine + scheduler + catch-up
- **Part 4**: Bill/cycle/stock repository SQL + scheduler tick wiring
- **Part 5**: Local NUI dashboard (React 19, 4 pages, 33 web tests)
- **Part 6**: Server-authoritative repairkit handler
  - Item-loss window eliminated (server-side repair before success event)
  - Old handlers (qb-mechanicjob, simple-repair) disabled — qb-czcraft is sole handler
- **Pre-gate fixes**:
  - Cycle completion side-effect gating on dedup-key affected count
  - NUI + repairkit split into separate commits for bisectability
  - Web test coverage expanded: reducers, forms, block states, permissions
- **Cycle engine (processMachine handler)** — NEW
  - `server/cycle_engine.lua`: the per-machine orchestrator that the scheduler
    tick fires via `qb-czcraft:internal:processMachine`. Connects the pure
    domain (bills, production, catch-up) to the repositories.
  - Two modes: real-time cycle completion + chunked catch-up.
  - `CyclesRepo.applyCatchUpChunk`: one-transaction-per-chunk batch catch-up
    (net stock deltas + aggregated production event + machine cursor advance).
  - `MachinesRepo.setBlocked` + `clearNextDue` helpers.
  - 5 unit tests (mock repo layer) covering both modes + block/idle paths.
  - This was previously missing — the scheduler fired `processMachine` into
    the void. STATUS.md/TODO.md had incorrectly listed Part 4 as complete.
- **E2E/load harness** — NEW (`resources/[meus-scripts]/qb-czcraft-e2e/`)
  - 6 scenarios: repair_natives, production_chain, concurrent,
    failure_injection, downtime_catchup, load_test.
  - SLO measurement utilities (p95/p99/max, Lua stall detector).
  - Raw output (not just pass/fail). See its README.md.

## Remaining before v0.1 E2E gate

- **Restart qb-czcraft on the live server** (via txAdmin) to load the
  harness fixes, then re-run `cze2e all` with a player online.
  Treat the result as the first trustworthy E2E verdict.
- **Harness-removed manual playtest** (requires a human at a game client):
  stop `qb-czcraft-e2e` (the poller and cze2e command are now gated
  behind `GetResourceState('qb-czcraft-e2e')` — stopping the resource
  fully disables the harness), then as a real player: place 4 machines,
  deposit inputs via NUI/target, run the full chain (iron→steel→
  cz_metal_parts→cz_components→cz_mechanical_parts→repairkit), damage
  a vehicle, use a repairkit. This is the only test of the client-side
  repair flow + pending-ack consumption semantics.
- Verify no other resource registers `repairkit` (check after any upstream update)
- Production override review for fixture caps and maxBillsPerMachine

## Harness fixes applied (2026-09-09, pending server restart)

All fixes are on disk, verified with 232 unit tests (0 failures), but
NOT yet loaded on the live server:

1. **allPass verdict bug** — scenario returning `false` now correctly
   sets `allPass = false`. Regression test: `e2e_verdict_spec.lua` (8 tests).
2. **Poller infinite loop** — `os.remove` + io.open fallback + skip guard.
3. **Player-online precondition** — `runAll` refuses to run without a player.
4. **Dirty-state cleanup** — `Slo.uniqueId()` replaces `math.random` for
   bill/cycle/machine IDs (no more collisions on repeated runs).
   `Slo.cleanup()` auto-deletes e2e-prefixed rows before `cze2e all`.
5. **UNSIGNED stock-decrement** — `CAST(quantity AS SIGNED)` in WHERE
   guards prevents underflow. Regression test: `unsigned_guard_spec.lua` (10 tests).
6. **load_test measurement scope** — end-to-end completion p95 replaces
   dispatch-only p95. Stall detector now covers provisioning + settle-wait.
7. **Harness gating** — poller + cze2e command gated behind
   `GetResourceState('qb-czcraft-e2e')`. Stopping the resource fully
   disables the harness for the manual playtest.

## Blockers

- **All prior E2E results retracted** (see CRITICAL section above).
  The gate cannot close until the harness is re-run under the corrected
  verdict logic with a player online, AND the harness-removed manual
  playtest is completed by a human.
- **RCON unavailable**: txAdmin server mode does not pass through
  `rcon_password` from server.cfg. Console commands must be run via
  the txAdmin web interface (port 40120), in-game menu, or server console.
- **Harness-removed playtest blocked on human**: requires a real player
  at a game client. Cannot be done by a CLI agent.
