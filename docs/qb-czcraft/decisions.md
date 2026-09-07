# qb-czcraft — Design Decisions

## ADR-001: Repairkit — server-side repair eliminates item-loss window

**Date:** 2026-09-07
**Status:** Implemented

### Context

The repairkit handler (Task 6) originally consumed the item BEFORE sending
the repair-confirmation event to the client. If the connection dropped
between `RemoveItem` and `TriggerClientEvent('...:success')`, the player
lost their repairkit and the vehicle stayed broken. The original code
comment called this a "safe failure mode," but it was only safe for the
server (no free repair) — not for the player (item lost, vehicle unrepaired).

This was inconsistent with every other saga in the project, which all
follow a no-data-loss pattern:
- Inventory batch: PENDING/COMMITTED two-transaction journal with retry
- Cycle completion: dedup-key gating on affected count
- Placement/pickup: server-authoritative with rollback-on-failure

### Decision

Apply the mechanical repair to the vehicle entity **server-side** (via
`SetVehicleFixed`, `SetVehicleEngineHealth`, `SetVehicleBodyHealth`,
`SetVehiclePetrolTankHealth`, `SetVehicleWheelHealth`, `SetVehicleTyreBurst`)
BEFORE sending the success event. The client success handler is now
cosmetic-only (dirt removal + repair sound + notification).

If the client never receives the success event, the vehicle is already
repaired and the item is consumed — no player-side data loss window.

### Alternatives considered

1. **Accept item loss as a documented exception** — rejected: inconsistent
   with the project's no-data-loss pattern; the user explicitly chose to fix.
2. **Reorder: confirm repair first, then consume** — rejected: creates the
   opposite problem (free repair if crash between confirm and consume),
   which is worse (exploitable).
3. **Journal/PENDING pattern (like inventory batch)** — rejected: a full
   saga with journal entries, client ack, and timeout reconciliation is
   disproportionate for a cheap consumable item. The server-side repair
   achieves the same guarantee with far less complexity.

### Trade-offs

- Some cosmetic natives (`SetVehicleDirtLevel`, `PlayVehicleSound`) remain
  client-side in the success handler. If the event is lost, the vehicle is
  mechanically repaired but may still be dirty and won't play the sound.
  This is acceptable — cosmetics are non-critical.
- Server-side vehicle natives rely on the entity being available server-side
  via `NetworkGetEntityFromNetworkId`. This is reliable for networked
  vehicles (which all player vehicles are).

---

## ADR-002: qb-czcraft is the sole repairkit handler

**Date:** 2026-09-07
**Status:** Implemented

### Context

The `repairkit` item was registered by three handlers simultaneously:
- `qb-mechanicjob` (`CreateUseableItem('repairkit', ...)`)
- `simple-repair` (`CreateUseableItem('repairkit', ...)`)
- `qb-czcraft` (`QBCore:Client:UseItem` event hook)

Using a repairkit triggered two repair flows at once — the
double-registration conflict flagged in the original audit.

### Decision

Comment out the `CreateUseableItem('repairkit', ...)` registrations in
both `qb-mechanicjob/server/main.lua` and `simple-repair/server.lua`.
qb-czcraft is the sole repairkit handler.

`qb-mechanicjob`'s `advancedrepairkit` and `tirerepairkit` registrations
are left untouched — qb-czcraft only handles `repairkit`.

### Trade-offs

- These are third-party resource files. A future upstream update of
  `qb-mechanicjob` could re-add the registration. The commented-out block
  includes a note explaining why it's disabled.
- `simple-repair` is effectively disabled (its only function was the
  repairkit). The resource folder is kept for reference but no longer
  processes repairkit uses.
