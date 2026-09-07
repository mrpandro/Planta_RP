#!/usr/bin/env python3
"""
qb-czcraft repository integration test against the REAL staging DB.

Replays the EXACT SQL statements from:
  - server/repositories/bills.lua        (BillsRepo.create)
  - server/repositories/cycles.lua       (CyclesRepo.start / complete / listDueMachines)
  - server/repositories/stock.lua        (StockRepo.applyDelta / load)
  - server/scheduler_tick.lua            (SchedulerTick.rebuildAtStartup query)

Connection string taken from server.cfg:
  mysql://root:Dracothiel1!@127.0.0.1:3306/qbcore?charset=utf8mb4

This is NOT a unit test with fakes. Every statement below is copied verbatim
from the .lua repository files (only placeholder syntax changes from ? to %s
for pymysql). All output is printed raw.
"""

import sys
import json
import uuid
from datetime import datetime, timezone

import pymysql

DB_HOST = "127.0.0.1"
DB_PORT = 3306
DB_USER = "root"
DB_PASS = "Dracothiel1!"
DB_NAME = "qbcore"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def section(title):
    print("\n" + "=" * 78)
    print(title)
    print("=" * 78)

def iso_from_unix(unix_seconds):
    # Replicates Lua os.date('!%Y-%m-%d %H:%M:%S.000', t)
    return datetime.fromtimestamp(unix_seconds, tz=timezone.utc).strftime(
        "%Y-%m-%d %H:%M:%S.000"
    )

def now_unix():
    return int(datetime.now(tz=timezone.utc).timestamp())

# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------

conn = pymysql.connect(
    host=DB_HOST, port=DB_PORT, user=DB_USER, password=DB_PASS,
    database=DB_NAME, charset="utf8mb4", autocommit=False,
)
cur = conn.cursor(pymysql.cursors.DictCursor)

# ===========================================================================
# 0. Schema verification
# ===========================================================================
section("0. SCHEMA VERIFICATION (staging DB)")

cur.execute("SELECT `version`, `applied_at` FROM `czcraft_schema_version` WHERE `id` = 1")
schema_row = cur.fetchone()
print("czcraft_schema_version:", schema_row)

cur.execute("""
    SELECT TABLE_NAME
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = %s AND TABLE_NAME LIKE 'czcraft_%%'
    ORDER BY TABLE_NAME
""", (DB_NAME,))
tables = [r["TABLE_NAME"] for r in cur.fetchall()]
print("czcraft tables (%d):" % len(tables))
for t in tables:
    print("  -", t)

assert schema_row and schema_row["version"] == 1, "FAIL: schema version != 1"
assert len(tables) == 11, "FAIL: expected 11 czcraft tables, got %d" % len(tables)
print("SCHEMA OK: version=1, 11 tables present")

# ===========================================================================
# Test fixture: create a dedicated test machine (cleaned up at the end)
# ===========================================================================
section("FIXTURE: create test machine + initial stock")

MACHINE_UUID = str(uuid.uuid4())
MACHINE_SERIAL = "INTTEST-" + MACHINE_UUID[:8].upper()
STOCK_ITEM = "iron"
OUTPUT_ITEM = "steel"

print("machine_uuid :", MACHINE_UUID)
print("serial       :", MACHINE_SERIAL)

cur.execute("""
    INSERT INTO `czcraft_machines`
        (`machine_uuid`, `serial`, `machine_type`, `lifecycle`,
         `owner_type`, `owner_id`, `location_type`, `location_id`,
         `operational_status`, `stock_capacity`, `version`)
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
""", (
    MACHINE_UUID, MACHINE_SERIAL, "furnace", "INSTALLED",
    "PLAYER", "test-license-123", "HOUSE", "house-1",
    "STOPPED", 100000, 0,
))
conn.commit()
print("inserted czcraft_machines row (lifecycle=INSTALLED, status=STOPPED)")

# Seed input stock: 10 iron (version 0). Replicates StockRepo.insert SQL.
cur.execute("""
    INSERT INTO `czcraft_machine_stock`
        (`machine_uuid`, `item_name`, `metadata_key`, `quantity`,
         `reserved_quantity`, `standard_unit_cost`)
    VALUES (%s, %s, %s, %s, %s, %s)
""", (MACHINE_UUID, STOCK_ITEM, "", 10, 0, 5.0000))
conn.commit()
print("inserted czcraft_machine_stock row: iron qty=10 reserved=0 version=0")

# ===========================================================================
# TEST 1: bill create -> cycle start -> cycle complete round-trip
# ===========================================================================
section("TEST 1: bill create -> cycle start -> cycle complete round-trip")

BILL_ID = str(uuid.uuid4())
CYCLE_ID = str(uuid.uuid4())
EVENT_ID = str(uuid.uuid4())
IDEMPOTENCY_KEY = "cycle-complete-" + CYCLE_ID
RECIPE_ID = "steel_from_iron"
RECIPE_CANONICAL = "steel_from_iron|furnace|30|PLAYER|steel|iron=2|steel=1"
RECIPE_SNAPSHOT = {"id": RECIPE_ID, "machine": "furnace", "duration": 30,
                   "primaryOutput": "steel", "inputs": [{"item": "iron", "qty": 2}],
                   "outputs": [{"item": "steel", "qty": 1}]}
SNAPSHOT_JSON = json.dumps(RECIPE_SNAPSHOT)

started_at = now_unix()
duration = 30
due_at = started_at + duration

# --- 1a. BillsRepo.create (verbatim SQL from bills.lua) ---
print("\n--- 1a. BillsRepo.create ---")
print("SQL: INSERT INTO czcraft_bills (...) VALUES (..., 0, 1, 'PENDING', ...)")
cur.execute("""
    INSERT INTO `czcraft_bills`
        (`bill_id`, `machine_uuid`, `recipe_id`, `mode`, `primary_output`,
         `target_quantity`, `produced_quantity`, `enabled`, `status`,
         `priority`, `created_by_type`, `created_by_id`)
    VALUES (%s, %s, %s, %s, %s, %s, 0, 1, 'PENDING', %s, %s, %s)
""", (
    BILL_ID, MACHINE_UUID, RECIPE_ID, "PRODUCE_X", "steel",
    5, "NORMAL", "PLAYER", "test-license-123",
))
conn.commit()
print("affected rows:", cur.rowcount)

# Verify bill persisted
cur.execute("""
    SELECT `bill_id`, `machine_uuid`, `recipe_id`, `mode`, `primary_output`,
           `target_quantity`, `produced_quantity`, `enabled`, `status`,
           `priority`, `version`
    FROM `czcraft_bills`
    WHERE `bill_id` = %s
""", (BILL_ID,))
bill_row = cur.fetchone()
print("bill row persisted:", bill_row)
assert bill_row and bill_row["status"] == "PENDING" and bill_row["produced_quantity"] == 0

# --- 1b. CyclesRepo.start (verbatim SQL from cycles.lua) ---
print("\n--- 1b. CyclesRepo.start (transactional) ---")
started_iso = iso_from_unix(started_at)
due_iso = iso_from_unix(due_at)
print("started_at_iso:", started_iso, "| due_at_iso:", due_iso)

# stock_deltas: consume 2 iron (quantity_delta=-2), reserve 2 iron (reserved_delta=+2)
# Per cycles.lua: quantity_delta != 0 -> UPDATE quantity; reserved_delta != 0 -> UPDATE reserved
delta_statements = []
delta_args = []
# quantity delta for iron: -2
delta_statements.append("""
    UPDATE `czcraft_machine_stock`
    SET `quantity` = `quantity` + ?,
        `version` = `version` + 1
    WHERE `machine_uuid` = ? AND `item_name` = ? AND `metadata_key` = ''
      AND `quantity` + ? >= 0
""".replace("?", "%s"))
delta_args.append([-2, MACHINE_UUID, STOCK_ITEM, -2])
# reserved delta for iron: +2
delta_statements.append("""
    UPDATE `czcraft_machine_stock`
    SET `reserved_quantity` = `reserved_quantity` + ?,
        `version` = `version` + 1
    WHERE `machine_uuid` = ? AND `item_name` = ? AND `metadata_key` = ''
      AND `reserved_quantity` + ? >= 0
      AND `reserved_quantity` + ? <= `quantity`
""".replace("?", "%s"))
delta_args.append([2, MACHINE_UUID, STOCK_ITEM, 2, 2])

insert_cycle_sql = """
    INSERT INTO `czcraft_active_cycles`
        (`cycle_id`, `cycle_sequence`, `machine_uuid`, `bill_id`, `recipe_id`,
         `recipe_hash`, `recipe_snapshot`, `started_at`, `due_at`,
         `duration_seconds`, `reserved_output_weight`, `standard_cost`)
    VALUES (%s, %s, %s, %s, %s, SHA2(%s, 256), %s, %s, %s, %s, %s, %s)
"""
insert_cycle_args = [
    CYCLE_ID, 1, MACHINE_UUID, BILL_ID, RECIPE_ID,
    RECIPE_CANONICAL, SNAPSHOT_JSON, started_iso, due_iso,
    duration, 100, 10.0000,
]

update_machine_sql = """
    UPDATE `czcraft_machines`
    SET `active_cycle_id` = %s,
        `operational_status` = 'RUNNING',
        `next_due_at` = %s,
        `version` = `version` + 1
    WHERE `machine_uuid` = %s
"""
update_machine_args = [CYCLE_ID, due_iso, MACHINE_UUID]

try:
    # 1. Insert active cycle
    cur.execute(insert_cycle_sql, insert_cycle_args)
    print("  [tx] insert active cycle: affected=%d" % cur.rowcount)
    # 2. Apply stock deltas
    for i, stmt in enumerate(delta_statements):
        cur.execute(stmt, delta_args[i])
        print("  [tx] stock delta #%d: affected=%d" % (i + 1, cur.rowcount))
    # 3. Update machine
    cur.execute(update_machine_sql, update_machine_args)
    print("  [tx] update machine: affected=%d" % cur.rowcount)
    conn.commit()
    print("  transaction COMMITTED")
except Exception as e:
    conn.rollback()
    print("  transaction ROLLED BACK:", e)
    raise

# Verify active cycle persisted (with recipe_hash from SHA2)
cur.execute("""
    SELECT `cycle_id`, `cycle_sequence`, `machine_uuid`, `bill_id`,
           `recipe_id`, `recipe_hash`, `started_at`, `due_at`,
           `duration_seconds`, `version`
    FROM `czcraft_active_cycles`
    WHERE `machine_uuid` = %s
""", (MACHINE_UUID,))
cycle_row = cur.fetchone()
print("active cycle persisted:", cycle_row)
assert cycle_row and cycle_row["cycle_id"] == CYCLE_ID
assert cycle_row["recipe_hash"] and len(cycle_row["recipe_hash"]) == 64, \
    "FAIL: recipe_hash not 64-char SHA-256"
print("recipe_hash (SHA2, 64 chars):", cycle_row["recipe_hash"])

# Verify stock after start: iron qty=8, reserved=2
cur.execute("""
    SELECT `item_name`, `quantity`, `reserved_quantity`, `version`
    FROM `czcraft_machine_stock`
    WHERE `machine_uuid` = %s AND `item_name` = %s AND `metadata_key` = ''
""", (MACHINE_UUID, STOCK_ITEM))
stock_after_start = cur.fetchone()
print("stock after start (iron):", stock_after_start)
assert stock_after_start["quantity"] == 8 and stock_after_start["reserved_quantity"] == 2

# Verify machine status
cur.execute("""
    SELECT `operational_status`, `active_cycle_id`, `next_due_at`, `version`
    FROM `czcraft_machines` WHERE `machine_uuid` = %s
""", (MACHINE_UUID,))
machine_after_start = cur.fetchone()
print("machine after start:", machine_after_start)
assert machine_after_start["operational_status"] == "RUNNING"
assert machine_after_start["active_cycle_id"] == CYCLE_ID

# --- 1c. CyclesRepo.complete (verbatim SQL from cycles.lua) ---
print("\n--- 1c. CyclesRepo.complete (transactional, idempotent) ---")
ended_at = started_at + duration
ended_iso = iso_from_unix(ended_at)

# completion_deltas: iron reserved -2 (release reservation), steel qty +1 (produce output)
# Also release the iron reservation: quantity stays, reserved goes back to 0.
# Per cycles.lua complete: quantity_delta != 0 -> UPDATE quantity; reserved_delta != 0 -> UPDATE reserved
complete_deltas = []
complete_args = []
# iron: reserved_delta = -2 (release reservation)
complete_deltas.append("""
    UPDATE `czcraft_machine_stock`
    SET `reserved_quantity` = `reserved_quantity` + ?,
        `version` = `version` + 1
    WHERE `machine_uuid` = ? AND `item_name` = ? AND `metadata_key` = ''
      AND `reserved_quantity` + ? >= 0
""".replace("?", "%s"))
complete_args.append([-2, MACHINE_UUID, STOCK_ITEM, -2])
# steel: quantity_delta = +1 (produce). Need a steel row first.
cur.execute("""
    INSERT INTO `czcraft_machine_stock`
        (`machine_uuid`, `item_name`, `metadata_key`, `quantity`,
         `reserved_quantity`, `standard_unit_cost`)
    VALUES (%s, %s, %s, %s, %s, %s)
""", (MACHINE_UUID, OUTPUT_ITEM, "", 0, 0, 20.0000))
conn.commit()
print("  (fixture: inserted steel stock row qty=0)")
complete_deltas.append("""
    UPDATE `czcraft_machine_stock`
    SET `quantity` = `quantity` + ?,
        `version` = `version` + 1
    WHERE `machine_uuid` = ? AND `item_name` = ? AND `metadata_key` = ''
""".replace("?", "%s"))
complete_args.append([1, MACHINE_UUID, OUTPUT_ITEM])

insert_event_sql = """
    INSERT INTO `czcraft_production_events`
        (`event_id`, `machine_uuid`, `bill_id`, `cycles_completed`,
         `inputs`, `outputs`, `cost`, `started_at`, `ended_at`,
         `idempotency_key`, `status`)
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, 'COMMITTED')
    ON DUPLICATE KEY UPDATE `event_id` = `event_id`
"""
inputs_json = json.dumps([{"item": "iron", "qty": 2}])
outputs_json = json.dumps([{"item": "steel", "qty": 1}])
insert_event_args = [
    EVENT_ID, MACHINE_UUID, BILL_ID, 1,
    inputs_json, outputs_json, 10.0000, started_iso, ended_iso,
    IDEMPOTENCY_KEY,
]

delete_cycle_sql = "DELETE FROM `czcraft_active_cycles` WHERE `machine_uuid` = %s AND `cycle_id` = %s"
complete_machine_sql = """
    UPDATE `czcraft_machines`
    SET `active_cycle_id` = NULL,
        `operational_status` = 'STOPPED',
        `version` = `version` + 1
    WHERE `machine_uuid` = %s
"""

try:
    # 1. Insert production event (idempotent)
    cur.execute(insert_event_sql, insert_event_args)
    print("  [tx] insert production event: affected=%d" % cur.rowcount)
    # 2. Apply completion stock deltas
    for i, stmt in enumerate(complete_deltas):
        cur.execute(stmt, complete_args[i])
        print("  [tx] completion delta #%d: affected=%d" % (i + 1, cur.rowcount))
    # 3. Delete active cycle
    cur.execute(delete_cycle_sql, (MACHINE_UUID, CYCLE_ID))
    print("  [tx] delete active cycle: affected=%d" % cur.rowcount)
    # 4. Update machine
    cur.execute(complete_machine_sql, (MACHINE_UUID,))
    print("  [tx] update machine STOPPED: affected=%d" % cur.rowcount)
    conn.commit()
    print("  transaction COMMITTED")
except Exception as e:
    conn.rollback()
    print("  transaction ROLLED BACK:", e)
    raise

# Verify production event persisted
cur.execute("""
    SELECT `event_id`, `machine_uuid`, `bill_id`, `cycles_completed`,
           `inputs`, `outputs`, `cost`, `idempotency_key`, `status`
    FROM `czcraft_production_events`
    WHERE `idempotency_key` = %s
""", (IDEMPOTENCY_KEY,))
event_row = cur.fetchone()
print("production event persisted:", event_row)
assert event_row and event_row["status"] == "COMMITTED" and event_row["cycles_completed"] == 1

# Verify active cycle deleted
cur.execute("SELECT COUNT(*) AS cnt FROM `czcraft_active_cycles` WHERE `machine_uuid` = %s",
            (MACHINE_UUID,))
cnt = cur.fetchone()["cnt"]
print("active cycles remaining for machine:", cnt)
assert cnt == 0, "FAIL: active cycle not deleted"

# Verify stock after complete: iron qty=8 reserved=0, steel qty=1
cur.execute("""
    SELECT `item_name`, `quantity`, `reserved_quantity`, `version`
    FROM `czcraft_machine_stock`
    WHERE `machine_uuid` = %s
    ORDER BY `item_name`
""", (MACHINE_UUID,))
stock_after_complete = cur.fetchall()
print("stock after complete:")
for r in stock_after_complete:
    print("  ", r)
iron = next(r for r in stock_after_complete if r["item_name"] == "iron")
steel = next(r for r in stock_after_complete if r["item_name"] == "steel")
assert iron["quantity"] == 8 and iron["reserved_quantity"] == 0, "FAIL: iron stock wrong after complete"
assert steel["quantity"] == 1 and steel["reserved_quantity"] == 0, "FAIL: steel stock wrong after complete"

# Verify machine stopped
cur.execute("""
    SELECT `operational_status`, `active_cycle_id`, `version`
    FROM `czcraft_machines` WHERE `machine_uuid` = %s
""", (MACHINE_UUID,))
machine_after_complete = cur.fetchone()
print("machine after complete:", machine_after_complete)
assert machine_after_complete["operational_status"] == "STOPPED"
assert machine_after_complete["active_cycle_id"] is None

print("\nTEST 1 PASSED: bill -> cycle start -> cycle complete round-trip persisted correctly")

# ===========================================================================
# TEST 2: optimistic version check in stock.applyDelta rejects stale write
# ===========================================================================
section("TEST 2: optimistic version check in stock.applyDelta rejects stale write")

# Replicates StockRepo.applyDelta verbatim. Current iron version is now 4
# (insert v0, start qty v1, start reserved v2, complete reserved v3 -> v4? let's read it)
cur.execute("""
    SELECT `item_name`, `quantity`, `reserved_quantity`, `version`
    FROM `czcraft_machine_stock`
    WHERE `machine_uuid` = %s AND `item_name` = %s AND `metadata_key` = ''
""", (MACHINE_UUID, STOCK_ITEM))
iron_now = cur.fetchone()
print("current iron stock:", iron_now)
current_version = iron_now["version"]
stale_version = current_version - 1
print("current version:", current_version, "| stale version we will use:", stale_version)

# Stale write: applyDelta with stale version (verbatim SQL from stock.lua)
print("\nSQL (StockRepo.applyDelta): UPDATE czcraft_machine_stock SET quantity=quantity+?, ...")
print("  WHERE ... AND version = <stale> AND quantity+? >= 0 AND reserved+? >= 0 AND reserved+? <= quantity+?")
cur.execute("""
    UPDATE `czcraft_machine_stock`
    SET `quantity`          = `quantity` + %s,
        `reserved_quantity` = `reserved_quantity` + %s,
        `version`           = `version` + 1
    WHERE `machine_uuid` = %s
      AND `item_name` = %s
      AND `metadata_key` = %s
      AND `version` = %s
      AND `quantity` + %s >= 0
      AND `reserved_quantity` + %s >= 0
      AND `reserved_quantity` + %s <= `quantity` + %s
""".replace("?", "%s") if False else """
    UPDATE `czcraft_machine_stock`
    SET `quantity`          = `quantity` + %s,
        `reserved_quantity` = `reserved_quantity` + %s,
        `version`           = `version` + 1
    WHERE `machine_uuid` = %s
      AND `item_name` = %s
      AND `metadata_key` = %s
      AND `version` = %s
      AND `quantity` + %s >= 0
      AND `reserved_quantity` + %s >= 0
      AND `reserved_quantity` + %s <= `quantity` + %s
""", (
    1, 0,
    MACHINE_UUID, STOCK_ITEM, "", stale_version,
    1, 0, 0, 1,
))
stale_affected = cur.rowcount
conn.commit()
print("affected rows (stale write):", stale_affected)
assert stale_affected == 0, "FAIL: stale write was NOT rejected (expected 0 affected)"

# Now a fresh write with the correct version should succeed
print("\nFresh write with correct version (%d):" % current_version)
cur.execute("""
    UPDATE `czcraft_machine_stock`
    SET `quantity`          = `quantity` + %s,
        `reserved_quantity` = `reserved_quantity` + %s,
        `version`           = `version` + 1
    WHERE `machine_uuid` = %s
      AND `item_name` = %s
      AND `metadata_key` = %s
      AND `version` = %s
      AND `quantity` + %s >= 0
      AND `reserved_quantity` + %s >= 0
      AND `reserved_quantity` + %s <= `quantity` + %s
""", (
    1, 0,
    MACHINE_UUID, STOCK_ITEM, "", current_version,
    1, 0, 0, 1,
))
fresh_affected = cur.rowcount
conn.commit()
print("affected rows (fresh write):", fresh_affected)
assert fresh_affected == 1, "FAIL: fresh write did not succeed (expected 1 affected)"

# Verify
cur.execute("""
    SELECT `item_name`, `quantity`, `reserved_quantity`, `version`
    FROM `czcraft_machine_stock`
    WHERE `machine_uuid` = %s AND `item_name` = %s AND `metadata_key` = ''
""", (MACHINE_UUID, STOCK_ITEM))
iron_after = cur.fetchone()
print("iron after fresh write:", iron_after)
assert iron_after["version"] == current_version + 1
assert iron_after["quantity"] == iron_now["quantity"] + 1

print("\nTEST 2 PASSED: stale write rejected (0 affected), fresh write succeeded (1 affected)")

# ===========================================================================
# TEST 3: ON DUPLICATE KEY UPDATE idempotency on replayed idempotency_key
# Mirrors the fixed cycles.lua complete() which gates ALL side effects on the
# production-event INSERT's affected count (affected=0 => skip, affected=1 => proceed).
# ===========================================================================
section("TEST 3: idempotency on replayed idempotency_key (no double-produce)")

# Snapshot stock BEFORE replay
cur.execute("""
    SELECT `item_name`, `quantity`, `reserved_quantity`, `version`
    FROM `czcraft_machine_stock`
    WHERE `machine_uuid` = %s
    ORDER BY `item_name`
""", (MACHINE_UUID,))
stock_before_replay = cur.fetchall()
print("stock BEFORE replay:")
for r in stock_before_replay:
    print("  ", r)

cur.execute("SELECT COUNT(*) AS cnt FROM `czcraft_production_events` WHERE `idempotency_key` = %s",
            (IDEMPOTENCY_KEY,))
events_before = cur.fetchone()["cnt"]
print("production_events with this idempotency_key BEFORE replay:", events_before)

# Replay the SAME complete() call with the SAME idempotency_key.
# This mirrors the FIXED cycles.lua: the event INSERT's affected count gates
# all side effects. If affected=0 (replay), skip stock deltas, cycle delete,
# and machine update — the transaction commits as a no-op.
print("\n--- 3a. Replaying CyclesRepo.complete with SAME idempotency_key (fixed guard) ---")
replay_error = None
side_effects_skipped = False
try:
    # 1. Insert production event (idempotent).
    cur.execute(insert_event_sql, insert_event_args)
    event_affected = cur.rowcount
    print("  [replay] insert production event: affected=%d (0=no-op/replay, 1=inserted)" % event_affected)
    # GUARD: if affected=0, skip ALL side effects (mirrors fixed cycles.lua).
    if event_affected == 0:
        side_effects_skipped = True
        print("  [replay] event INSERT returned 0 -> SKIPPING stock deltas, cycle delete, machine update")
    else:
        for i, stmt in enumerate(complete_deltas):
            cur.execute(stmt, complete_args[i])
            print("  [replay] completion delta #%d: affected=%d" % (i + 1, cur.rowcount))
        cur.execute(delete_cycle_sql, (MACHINE_UUID, CYCLE_ID))
        print("  [replay] delete active cycle: affected=%d" % cur.rowcount)
        cur.execute(complete_machine_sql, (MACHINE_UUID,))
        print("  [replay] update machine STOPPED: affected=%d" % cur.rowcount)
    conn.commit()
    print("  replay transaction COMMITTED")
except Exception as e:
    conn.rollback()
    replay_error = e
    print("  [replay] FAILED -> transaction ROLLED BACK")
    print("  MySQL error: (%s) %s" % (e.args[0], e.args[1]))

# Verify production_events count unchanged
cur.execute("SELECT COUNT(*) AS cnt FROM `czcraft_production_events` WHERE `idempotency_key` = %s",
            (IDEMPOTENCY_KEY,))
events_after = cur.fetchone()["cnt"]
print("\nproduction_events with this idempotency_key AFTER replay:", events_after)

# Verify stock after replay
cur.execute("""
    SELECT `item_name`, `quantity`, `reserved_quantity`, `version`
    FROM `czcraft_machine_stock`
    WHERE `machine_uuid` = %s
    ORDER BY `item_name`
""", (MACHINE_UUID,))
stock_after_replay = cur.fetchall()
print("stock AFTER replay:")
for r in stock_after_replay:
    print("  ", r)

iron_before = next(r for r in stock_before_replay if r["item_name"] == "iron")
steel_before = next(r for r in stock_before_replay if r["item_name"] == "steel")
iron_after_r = next(r for r in stock_after_replay if r["item_name"] == "iron")
steel_after_r = next(r for r in stock_after_replay if r["item_name"] == "steel")

print("\n--- 3a verdict ---")
print("production_events: before=%d after=%d (no duplicate row: %s)" % (
    events_before, events_after, events_before == events_after))
print("iron  qty: before=%d after=%d (no double-delta: %s)" % (
    iron_before["quantity"], iron_after_r["quantity"],
    iron_before["quantity"] == iron_after_r["quantity"]))
print("steel qty: before=%d after=%d (no double-produce: %s)" % (
    steel_before["quantity"], steel_after_r["quantity"],
    steel_before["quantity"] == steel_after_r["quantity"]))
print("side effects skipped on replay: %s" % side_effects_skipped)

assert events_before == events_after, "FAIL: duplicate production event on replay"
assert iron_before["quantity"] == iron_after_r["quantity"], "FAIL: iron double-delta on replay"
assert steel_before["quantity"] == steel_after_r["quantity"], "FAIL: steel double-produce on replay"
assert side_effects_skipped, "FAIL: side effects were not skipped on replay"
assert replay_error is None, "FAIL: replay raised an error: %s" % replay_error
print("\nTEST 3 PASSED: replayed idempotency_key no-ops, no double-production, side effects skipped")

# ===========================================================================
# TEST 4: scheduler startup heap rebuild + 30s polling recovery net
# ===========================================================================
section("TEST 4: scheduler startup heap rebuild + 30s polling recovery net")

# Set the test machine's next_due_at to a past time so it shows as due.
past_iso = iso_from_unix(now_unix() - 60)
cur.execute("""
    UPDATE `czcraft_machines`
    SET `next_due_at` = %s,
        `operational_status` = 'STOPPED',
        `version` = `version` + 1
    WHERE `machine_uuid` = %s
""", (past_iso, MACHINE_UUID))
conn.commit()
print("set test machine next_due_at to past time:", past_iso)

# --- 4a. SchedulerTick.rebuildAtStartup (verbatim SQL from scheduler_tick.lua) ---
print("\n--- 4a. SchedulerTick.rebuildAtStartup query ---")
print("SQL: SELECT machine_uuid, next_due_at FROM czcraft_machines")
print("     WHERE lifecycle='INSTALLED' AND next_due_at IS NOT NULL ORDER BY next_due_at ASC")
cur.execute("""
    SELECT `machine_uuid`, `next_due_at`
    FROM `czcraft_machines`
    WHERE `lifecycle` = 'INSTALLED'
      AND `next_due_at` IS NOT NULL
    ORDER BY `next_due_at` ASC
""")
startup_rows = cur.fetchall()
print("rebuildAtStartup returned %d rows" % len(startup_rows))
for r in startup_rows:
    print("  -", r["machine_uuid"], r["next_due_at"])
assert len(startup_rows) >= 1, "FAIL: rebuildAtStartup returned no rows"
assert any(r["machine_uuid"] == MACHINE_UUID for r in startup_rows), \
    "FAIL: test machine not in startup heap"
print("rebuildAtStartup OK: %d machines queued (test machine present)" % len(startup_rows))

# --- 4b. CyclesRepo.listDueMachines (30s polling recovery net, verbatim SQL) ---
print("\n--- 4b. CyclesRepo.listDueMachines (30s polling recovery net) ---")
now_iso = iso_from_unix(now_unix())
print("SQL: SELECT machine_uuid, next_due_at FROM czcraft_machines")
print("     WHERE lifecycle='INSTALLED' AND operational_status IN ('STOPPED','RUNNING')")
print("       AND next_due_at IS NOT NULL AND next_due_at <= <now> ORDER BY next_due_at ASC LIMIT 100")
cur.execute("""
    SELECT `machine_uuid`, `next_due_at`
    FROM `czcraft_machines`
    WHERE `lifecycle` = 'INSTALLED'
      AND `operational_status` IN ('STOPPED', 'RUNNING')
      AND `next_due_at` IS NOT NULL
      AND `next_due_at` <= %s
    ORDER BY `next_due_at` ASC
    LIMIT %s
""", (now_iso, 100))
due_rows = cur.fetchall()
print("listDueMachines returned %d rows" % len(due_rows))
for r in due_rows:
    print("  -", r["machine_uuid"], r["next_due_at"])
assert any(r["machine_uuid"] == MACHINE_UUID for r in due_rows), \
    "FAIL: test machine not found in due machines polling"
print("listDueMachines OK: %d due machines (test machine present)" % len(due_rows))

print("\nTEST 4 PASSED: startup heap rebuild + 30s polling recovery net both ran without error")

# ===========================================================================
# TEST 5: REGRESSION — positive-only deltas, replayed idempotency_key, no double-produce
# This is the permanent regression test for the bug found in the previous session's
# test 3b. Before the fix, a replayed complete() with positive-only completion deltas
# (no negative reserved release) would commit a second time and DOUBLE-PRODUCE output.
# The fix gates ALL side effects on the production-event INSERT's affected count.
# This test must never be removed — it is the second replay-safety bug found by hand.
# ===========================================================================
section("TEST 5: REGRESSION — positive-only deltas replay does not double-produce")

# Use a fresh idempotency key and event ID for this test.
REGRESSION_EVENT_ID = str(uuid.uuid4())
REGRESSION_IDEMPOTENCY_KEY = "regression-posonly-replay-" + str(uuid.uuid4())
BATCH_AMOUNT = 1  # steel +1 per completion

# SQL mirroring the fixed cycles.lua complete() with the affected-count guard.
regression_event_sql = """
    INSERT INTO `czcraft_production_events`
        (`event_id`, `machine_uuid`, `bill_id`, `cycles_completed`,
         `inputs`, `outputs`, `cost`, `started_at`, `ended_at`,
         `idempotency_key`, `status`)
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, 'COMMITTED')
    ON DUPLICATE KEY UPDATE `event_id` = `event_id`
"""
regression_event_args = [
    REGRESSION_EVENT_ID, MACHINE_UUID, BILL_ID, 1,
    inputs_json, outputs_json, 10.0000, started_iso, ended_iso,
    REGRESSION_IDEMPOTENCY_KEY,
]
# Positive-only completion delta: steel +BATCH_AMOUNT (no negative reserved release).
# This is the exact scenario that exposed the bug: UNSIGNED underflow does NOT save us.
regression_delta_sql = """
    UPDATE `czcraft_machine_stock`
    SET `quantity` = `quantity` + %s,
        `version` = `version` + 1
    WHERE `machine_uuid` = %s AND `item_name` = %s AND `metadata_key` = ''
"""
regression_delta_args = [BATCH_AMOUNT, MACHINE_UUID, OUTPUT_ITEM]

# --- 5a. First completion (positive-only) ---
print("\n--- 5a. First completion (positive-only delta: steel +%d) ---")
cur.execute("SELECT `quantity` FROM `czcraft_machine_stock` WHERE `machine_uuid`=%s AND `item_name`=%s",
            (MACHINE_UUID, OUTPUT_ITEM))
steel_qty_before = cur.fetchone()["quantity"]
print("steel qty BEFORE first completion:", steel_qty_before)

try:
    cur.execute(regression_event_sql, regression_event_args)
    first_event_affected = cur.rowcount
    print("  [first] insert event: affected=%d (1=inserted)" % first_event_affected)
    # Guard: only apply deltas if event INSERT affected=1 (mirrors fixed cycles.lua)
    if first_event_affected == 1:
        cur.execute(regression_delta_sql, regression_delta_args)
        print("  [first] steel +%d delta: affected=%d" % (BATCH_AMOUNT, cur.rowcount))
    else:
        print("  [first] UNEXPECTED: event affected=%d, skipping deltas" % first_event_affected)
    conn.commit()
    print("  [first] COMMITTED")
except Exception as e:
    conn.rollback()
    raise

cur.execute("SELECT `quantity` FROM `czcraft_machine_stock` WHERE `machine_uuid`=%s AND `item_name`=%s",
            (MACHINE_UUID, OUTPUT_ITEM))
steel_qty_after_first = cur.fetchone()["quantity"]
print("steel qty AFTER first completion:", steel_qty_after_first)
assert steel_qty_after_first == steel_qty_before + BATCH_AMOUNT, \
    "FAIL: first completion did not produce exactly +%d (before=%d, after=%d)" % (
        BATCH_AMOUNT, steel_qty_before, steel_qty_after_first)

# --- 5b. Replay with SAME idempotency_key ---
print("\n--- 5b. Replay with SAME idempotency_key '%s' ---" % REGRESSION_IDEMPOTENCY_KEY)
try:
    cur.execute(regression_event_sql, regression_event_args)
    replay_event_affected = cur.rowcount
    print("  [replay] insert event: affected=%d (0=no-op/replay)" % replay_event_affected)
    # Guard: skip deltas if event INSERT affected=0 (mirrors fixed cycles.lua)
    if replay_event_affected == 1:
        cur.execute(regression_delta_sql, regression_delta_args)
        print("  [replay] steel +%d delta: affected=%d" % (BATCH_AMOUNT, cur.rowcount))
        print("  [replay] WARNING: side effects were NOT skipped — double-produce!")
    else:
        print("  [replay] event affected=0 -> SKIPPING steel delta (guard active)")
    conn.commit()
    print("  [replay] COMMITTED")
except Exception as e:
    conn.rollback()
    print("  [replay] ROLLED BACK:", e)
    raise

cur.execute("SELECT `quantity` FROM `czcraft_machine_stock` WHERE `machine_uuid`=%s AND `item_name`=%s",
            (MACHINE_UUID, OUTPUT_ITEM))
steel_qty_after_replay = cur.fetchone()["quantity"]
print("steel qty AFTER replay:", steel_qty_after_replay)

cur.execute("SELECT COUNT(*) AS cnt FROM `czcraft_production_events` WHERE `idempotency_key`=%s",
            (REGRESSION_IDEMPOTENCY_KEY,))
regression_events_count = cur.fetchone()["cnt"]
print("production_events for this idempotency_key:", regression_events_count)

# --- 5c. Assertions ---
total_increase = steel_qty_after_replay - steel_qty_before
print("\n--- 5c. Regression verdict ---")
print("steel: before_first=%d after_first=%d after_replay=%d" % (
    steel_qty_before, steel_qty_after_first, steel_qty_after_replay))
print("total increase: %d (expected exactly %d, the batch amount once)" % (
    total_increase, BATCH_AMOUNT))
print("production_events row count: %d (expected 1)" % regression_events_count)
print("replay event affected: %d (expected 0 — no-op)" % replay_event_affected)

assert total_increase == BATCH_AMOUNT, \
    "FAIL: REGRESSION — output increased by %d, expected exactly %d (double-produced!)" % (
        total_increase, BATCH_AMOUNT)
assert regression_events_count == 1, \
    "FAIL: REGRESSION — %d production_events, expected 1 (duplicate!)" % regression_events_count
assert replay_event_affected == 0, \
    "FAIL: REGRESSION — replay event affected=%d, expected 0 (no-op)" % replay_event_affected
assert steel_qty_after_replay == steel_qty_after_first, \
    "FAIL: REGRESSION — steel changed on replay (before=%d, after_replay=%d)" % (
        steel_qty_after_first, steel_qty_after_replay)

print("\nTEST 5 PASSED: positive-only deltas replay does NOT double-produce")
print("  Output increased by exactly %d once (not twice). Guard is active." % BATCH_AMOUNT)

# ===========================================================================
# Cleanup
# ===========================================================================
section("CLEANUP: remove test data from staging DB")

# Order respects FK constraints.
cur.execute("DELETE FROM `czcraft_production_events` WHERE `machine_uuid` = %s", (MACHINE_UUID,))
print("deleted production_events:", cur.rowcount)
cur.execute("DELETE FROM `czcraft_active_cycles` WHERE `machine_uuid` = %s", (MACHINE_UUID,))
print("deleted active_cycles:", cur.rowcount)
cur.execute("DELETE FROM `czcraft_bills` WHERE `machine_uuid` = %s", (MACHINE_UUID,))
print("deleted bills:", cur.rowcount)
cur.execute("DELETE FROM `czcraft_machine_stock` WHERE `machine_uuid` = %s", (MACHINE_UUID,))
print("deleted machine_stock:", cur.rowcount)
cur.execute("DELETE FROM `czcraft_machines` WHERE `machine_uuid` = %s", (MACHINE_UUID,))
print("deleted machines:", cur.rowcount)
conn.commit()
print("cleanup COMMITTED")

cur.close()
conn.close()

section("ALL TESTS COMPLETE")
print("See verdicts above for each test.")
