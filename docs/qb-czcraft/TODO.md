# qb-czcraft — TODO

## Before v0.1 E2E gate

### Harness bug fixes (DONE 2026-09-09, pending server restart)

- [x] **Fix allPass verdict bug** (`e2e_run.lua:224`): scenario returning
      `false` never set `allPass = false` — every prior OVERALL: PASS was
      "nothing crashed," not "everything passed." Fixed + regression test
      (`e2e_verdict_spec.lua`, 8 tests).
- [x] **Fix poller infinite loop**: `io.open(COMMAND_FILE, 'w')` silently
      fails on `[meus-scripts]` bracketed paths in FiveM. Replaced with
      `os.remove` + io.open fallback + skip-execution guard.
- [x] **Add player-online precondition**: `runAll` now refuses to run
      and reports FAIL if no player is online, instead of silently
      no-opping all 6 scenarios.
- [x] **Fix dirty-state cleanup**: `Slo.uniqueId()` replaces `math.random`
      for bill/cycle/machine IDs. `Slo.cleanup()` auto-deletes e2e-prefixed
      rows before `cze2e all`. No more collisions on repeated runs.
- [x] **Fix UNSIGNED stock-decrement bug**: `CAST(quantity AS SIGNED)` in
      WHERE guards prevents underflow. Regression test: `unsigned_guard_spec.lua`
      (10 tests). Fixed in `stock.lua` and `cycles.lua`.
- [x] **Fix load_test measurement scope**: end-to-end completion p95 replaces
      dispatch-only p95. Stall detector now covers provisioning + settle-wait.
- [x] **Gate harness behind resource state**: poller + cze2e command gated
      behind `GetResourceState('qb-czcraft-e2e')`. Stopping the resource
      fully disables the harness for the manual playtest.

### Re-verification (after fixes are loaded on the server)

- [ ] **Restart qb-czcraft via txAdmin** to load the harness fixes
- [ ] **Run `cze2e all` with a player online** — first trustworthy verdict
- [ ] **Harness-removed manual playtest** (requires human at game client):
      - [ ] Stop qb-czcraft-e2e (harness is now fully disabled)
      - [ ] Place 4 machines via NUI/target
      - [ ] Deposit inputs, run full chain: iron→steel→cz_metal_parts→
            cz_components→cz_mechanical_parts→repairkit
      - [ ] Damage a vehicle, use a repairkit, verify pending-ack flow
- [ ] Confirm no other resource registers `repairkit` after any future
      upstream update of qb-mechanicjob
- [ ] Production override review: fixture caps (HOUSE=4, ORG=20) and
      maxBillsPerMachine=5 — these are pre-gate defaults

### Rollout checklist decision (user's call: pre-v0.2 or deferred)

- [ ] Decide: audit retention/rollups — pre-v0.2 or deferred?
- [ ] Decide: security abuse cases — pre-v0.2 or deferred?
- [ ] Decide: admin recovery commands (inspect/pause/resume/reconcile/
      recover/health) — currently disabled, don't exist yet
- [ ] Decide: staging rollback rehearsal — pre-v0.2 or deferred?
- [ ] Note: migrations 002–005 are expected to belong to v0.2–v0.5,
      not a v0.1 gap.

## Future tasks (post-v0.1)

- [ ] storageTransfers feature flag
- [ ] admin tooling feature flag
- [ ] NUI: machine control actions (start/stop) from dashboard
- [ ] NUI: stock transfer UI
