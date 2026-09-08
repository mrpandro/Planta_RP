# qb-czcraft — Status

**Last updated:** 2026-09-07

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

- **Run the E2E harness against staging** (requires live FiveM server + DB):
  - `cze2e repair_natives` — vehicle repair native precondition
  - `cze2e production_chain` — full chain + MAINTAIN_X
  - `cze2e concurrent` — concurrency safety
  - `cze2e failure_injection` — crash recovery + idempotency
  - `cze2e downtime_catchup` — 24h+ catch-up
  - `cze2e load_test` — 1000-machine/250-active SLO probes
  - `cze2e all` — run all in order
- Verify no other resource registers `repairkit` (check after any upstream update)
- Production override review for fixture caps and maxBillsPerMachine

## Blockers

None (code-complete). The gate is now blocked on **staging execution**, not
implementation. All harness scenarios are built and syntax-checked; the cycle
engine has unit-test coverage. The gate cannot close until the harness is run
against a real FiveM server + database and the raw output confirms the SLOs.
