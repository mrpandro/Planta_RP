# qb-czcraft — Concurrency Model

This document describes the concurrency model for the qb-inventory
idempotent batch patch (`ApplyIdempotentBatch`), which is the persistence
path for CzCraft deposit/withdraw sagas. It reflects the **actual
implementation** in `resources/[qb]/qb-inventory/server/functions.lua`,
not the original plan (the plan had a silent-loss bug that was fixed
during implementation — see "Design deviation" below).

## Runtime constraints

- **FiveM server Lua is single-threaded cooperative.** Synchronous
  functions run atomically to completion; only `await`/callback yields
  can interleave other code.
- `AddItem`/`RemoveItem`/`SetInventory`/`ClearInventory` are all
  **synchronous** (return boolean, no yield) and are called without
  await at ~15 call sites in `server/main.lua`. Their signatures cannot
  be changed to async.
- No mutex/lock facility exists in ox_lib or qb-inventory.

## Optimistic generation counter

A per-identifier counter (`InventoryGeneration[identifier]`) is bumped
by every in-memory mutator:

- `AddItem` (player path)
- `RemoveItem` (player path)
- `SetInventory` (player path)
- `ClearInventory` (player path)
- The batch's own in-memory swap

This counter is internal state only — no public signature or return
value changes. It lets the batch detect that a concurrent sync mutator
ran while it was awaiting a SQL transaction, without needing a real
lock.

## PENDING/COMMITTED two-transaction flow

`ApplyIdempotentBatch` uses **two separate transactions** to avoid the
silent-loss bug in the original single-transaction design:

### tx_1 — journal intent (PENDING)

`MySQL.startTransaction` callback:

1. `SELECT ... FROM czcraft_inventory_mutations WHERE mutation_id = ? FOR UPDATE`
   - **No prior row** → `INSERT` a new row with `status = "PENDING"`.
     `players.inventory` is **NOT** written in tx_1.
   - **Prior row exists, hash matches, status = COMMITTED** → true
     replay. Return the stored `result` to the caller.
   - **Prior row exists, hash matches, status = PENDING** → a prior
     attempt of this same mutation did not reach COMMITTED. Re-apply
     against the current (re-snapshotted) items.
   - **Prior row exists, hash differs** → security incident. Rollback,
     log, return `{ securityIncident = true }`.

2. After tx_1 commits (PENDING path): **synchronous check-then-swap** —
   no yield is allowed between the generation check and the in-memory
   swap.
   - If `InventoryGeneration[identifier] ~= savedGen` → a sync mutator
     ran during tx_1's await. `goto retry` (re-snapshot, re-validate,
     max 3 retries).
   - If generation is unchanged → swap in-memory:
     `Player.SetPlayerData('items', result.items)`, `bumpGeneration`,
     notify client, log.

### tx_2 — persist + commit

`MySQL.transaction.await` with two statements:

1. `UPDATE players SET inventory = ? WHERE citizenid = ?`
2. `UPDATE czcraft_inventory_mutations SET status = 'COMMITTED', result = ? WHERE mutation_id = ?`

If tx_2 succeeds → `{ success = true, replayed = false }`.

### Why the split?

In the original plan, `players.inventory` was written inside tx_1
together with the journal row. The bug: if a concurrent sync `AddItem`
ran during tx_1's await, the retry would find the COMMITTED journal row
with matching hash, hit the replay branch, and return `success = true`
**without applying the batch** — silently losing the batch's changes
while the concurrent AddItem's in-memory state was overwritten by the
DB write inside tx_1.

The PENDING/COMMITTED split fixes this:

- **PENDING unambiguously means "DB inventory not yet written."** A
  cross-session retry (player reconnects, LoadInventory loads the
  original DB inventory) re-applies the batch safely.
- The in-memory swap is gated by a **synchronous** generation check
  after tx_1, so a concurrent sync mutator during tx_1's await triggers
  a re-snapshot/re-validate retry instead of silently overwriting.
- tx_2 only runs after the generation check passes and the in-memory
  swap is done, so the DB write and the in-memory state are consistent
  at the point of tx_2.

## tx_2-failure handling

If tx_2 fails **after** the in-memory swap already happened:

- **In-memory state**: has the batch applied (swap + bumpGeneration
  already ran).
- **DB state**: `players.inventory` still has the original pre-batch
  inventory; journal row is still `PENDING`.
- **Same-session retry**: The caller calls `ApplyIdempotentBatch` again
  with the same `mutationId`. The function detects the persist-pending
  state (tracked in `PersistPending[identifier][mutationId]`) and
  **retries only tx_2** — it does NOT re-validate, does NOT re-check
  generation, does NOT re-swap. It serializes the current
  `Player.PlayerData.items` (which already includes the batch) and
  writes it to `players.inventory` + marks the journal row COMMITTED.
  This avoids double-application (re-validating against already-applied
  state would fail or double-apply) and avoids the retry storm that
  would result from the generation check seeing the batch's own
  bumpGeneration.
- **Cross-session retry**: Player disconnects/reconnects. LoadInventory
  loads the original DB inventory (tx_2 never wrote it). The journal
  row is PENDING with matching hash. The batch re-validates against the
  original inventory and re-applies normally — a clean re-application,
  not a replay.

tx_2 failure is expected to be extremely rare (it's a simple two-statement
transaction on a single connection). Saga callers must treat
`{ success = false, reason = 'persist failed' }` as retryable.

## Scope

This patch does NOT refactor the native `SetInventoryData` UI flow or
any other existing qb-inventory export. Only the new
`ApplyIdempotentBatch` export, the pure validator module
(`idempotent_batch.lua`), the generation counter, and the
`CzCraftAllowedResources` allow-list are added.
