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

## Remaining before v0.1 E2E gate

- Full staging E2E test (placement → bill → cycle → stock → NUI → repairkit)
- Verify server-side vehicle repair natives work correctly in FiveM runtime
- Verify no other resource registers `repairkit` (check after any upstream update)
- Production override review for fixture caps and maxBillsPerMachine

## Blockers

None.
