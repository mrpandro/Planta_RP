# qb-czcraft — TODO

## Before v0.1 E2E gate

- [x] **Implement processMachine cycle engine** (`server/cycle_engine.lua`)
      — was missing; scheduler fired the event into the void. Now handles
      real-time cycle completion + chunked catch-up. 5 unit tests pass.
- [x] **Build E2E/load harness** (`resources/[meus-scripts]/qb-czcraft-e2e/`)
      — 6 scenarios + SLO probes. Syntax-checked, not yet run against staging.
- [ ] **Run the E2E harness against staging** (requires live FiveM + DB):
      - [ ] `cze2e repair_natives` — vehicle repair native precondition
      - [ ] `cze2e production_chain` — full chain + MAINTAIN_X
      - [ ] `cze2e concurrent` — concurrency safety
      - [ ] `cze2e failure_injection` — crash recovery + idempotency
      - [ ] `cze2e downtime_catchup` — 24h+ catch-up
      - [ ] `cze2e load_test` — 1000-machine/250-active SLO probes
      - [ ] `cze2e all` — run all in order, capture raw output
- [ ] Confirm no other resource registers `repairkit` after any future
      upstream update of qb-mechanicjob
- [ ] Production override review: fixture caps (HOUSE=4, ORG=20) and
      maxBillsPerMachine=5 — these are pre-gate defaults

## Future tasks (post-v0.1)

- [ ] storageTransfers feature flag
- [ ] admin tooling feature flag
- [ ] NUI: machine control actions (start/stop) from dashboard
- [ ] NUI: stock transfer UI
