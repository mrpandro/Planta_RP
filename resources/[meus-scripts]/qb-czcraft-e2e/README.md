# qb-czcraft-e2e

Staging E2E + load-test harness for `qb-czcraft` v0.1. Runs **live against a
real FiveM server + database** — these are not unit tests. All scenarios emit
raw numbers (timings, stock counts, event counts, percentile breakdowns), not
just pass/fail.

## Prerequisites

1. **FiveM staging server** running with `qb-czcraft` loaded and ready
   (schema migrated, bootstrap passed).
2. **At least one player online** — several scenarios need a player to anchor
   vehicle spawns and provide an owner citizenid for test machines.
3. **Staging database** you can dirty (the harness creates machine/bill/stock/
   cycle rows). Clean up with:
   ```sql
   DELETE FROM czcraft_production_events WHERE machine_uuid LIKE '%e2e-%';
   DELETE FROM czcraft_active_cycles WHERE machine_uuid LIKE '%e2e-%';
   DELETE FROM czcraft_machine_stock WHERE machine_uuid LIKE '%e2e-%';
   DELETE FROM czcraft_bills WHERE bill_id LIKE 'e2e-%';
   DELETE FROM czcraft_machines WHERE location_id LIKE 'e2e-%';
   ```
4. Add to `server.cfg`:
   ```
   ensure qb-czcraft
   ensure qb-czcraft-e2e
   ```

## Running scenarios

All commands run from the **server console** (not in-game):

```
cze2e repair_natives        # vehicle repair native precondition
cze2e production_chain      # iron -> steel -> parts -> components -> repairkit + MAINTAIN_X
cze2e concurrent            # same/different machine concurrency + version conflicts
cze2e failure_injection     # crash-after-saga-step recovery + idempotent re-completion
cze2e downtime_catchup      # 24h+ downtime catch-up (sufficient + insufficient inputs)
cze2e load_test             # 1000 machines / 250 active + SLO probes
cze2e all                   # run all scenarios in order
```

## Scenarios

### repair_natives (gate precondition)

Verifies `SetVehicleFixed`, `SetVehicleEngineHealth`, `SetVehicleBodyHealth`,
`SetVehiclePetrolTankHealth`, `SetVehicleWheelHealth`, `SetVehicleTyreBurst`
apply server-side against a real networked vehicle resolved via
`NetworkGetEntityFromNetworkId`. Spawns a vehicle, damages it, applies the
repair sequence from `qb-czcraft/server/repairkit.lua`, reads back the health
values, and verifies each native mutated the vehicle. **This is the safety
precondition for the repair-before-consume design (ADR-001).**

### production_chain

Exercises the full chain: `iron + metalscrap -> steel -> cz_metal_parts ->
cz_components + cz_mechanical_parts -> repairkit`, plus a `MAINTAIN_X` bill.
Each stage creates a machine, deposits inputs, creates a bill, sets
`next_due_at` to 24h ago to trigger catch-up, fires `processMachine`, and
verifies the output stock and bill completion.

### concurrent

- Same machine: 5 concurrent `processMachine` calls — verifies no cycle
  duplication (active-cycle PK + idempotency keys).
- Different machines: 2 concurrent `processMachine` calls — verifies no
  interference.
- Optimistic version conflict: stale bill version is rejected.

### failure_injection

- Crash after cycle start (pre-completion): deletes the active cycle row
  without completing, fires `processMachine`, verifies fail-closed behavior
  (no duplication, machine blocks) and recovery time < 60s.
- Idempotent re-completion: fires `processMachine` twice, verifies only one
  production event is committed.

### downtime_catchup

- 25h downtime with sufficient inputs: 500 cycles run via chunked catch-up,
  verifies correct stock deltas, bill completion, and 5 aggregated production
  events (chunks of 100).
- 24h downtime with insufficient inputs: 10 cycles run then blocks on input
  exhaustion — verifies the catch-up formula respects stock availability.

### load_test

Creates 1000 machines (250 active with due bills, 750 idle), fires
`processMachine` for all 250 active, and measures:
- DB stock-load p95 (threshold < 200ms)
- Action dispatch p95 (threshold < 300ms)
- Lua stalls > 50ms (threshold: zero)
- Correctness: all 250 machines produced 2 steel
- Throughput (machines/sec)

## Output format

Every scenario prints raw measurements prefixed with `[E2E]`. SLO verdicts
print `[E2E][SLO] ... PASS` or `[E2E][SLO] ... FAIL`. Capture the server
console log to retain the raw output for the gate record.

## What this harness does NOT do

- It does not run the qb-czcraft web/NUI tests — those are unit tests, run
  with `npm --prefix "resources/[meus-scripts]/qb-czcraft/web" test`.
- It does not test the repairkit item flow end-to-end (player uses repairkit
  item on a damaged vehicle) — that requires a client-side test driver. The
  `repair_natives` scenario verifies the server-side native precondition that
  the repairkit handler depends on.
- It does not clean up its own DB rows — run the cleanup SQL above after each
  full run.
