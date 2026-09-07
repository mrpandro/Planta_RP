# qb-czcraft — TODO

## Before v0.1 E2E gate

- [ ] Full staging E2E: placement → bill creation → cycle execution → stock
      update → NUI dashboard verification → repairkit flow
- [ ] Verify server-side vehicle repair natives (SetVehicleFixed, etc.) work
      correctly in FiveM runtime — some natives may behave differently
      server-side vs client-side
- [ ] Confirm no other resource registers `repairkit` after any future
      upstream update of qb-mechanicjob
- [ ] Production override review: fixture caps (HOUSE=4, ORG=20) and
      maxBillsPerMachine=5 — these are pre-gate defaults

## Future tasks (post-v0.1)

- [ ] storageTransfers feature flag
- [ ] admin tooling feature flag
- [ ] NUI: machine control actions (start/stop) from dashboard
- [ ] NUI: stock transfer UI
