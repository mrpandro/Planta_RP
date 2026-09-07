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
