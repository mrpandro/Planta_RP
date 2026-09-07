-- Regression test for CyclesRepo.complete() idempotency guard.
-- This is the second replay-safety bug found by hand rather than by test.
-- The fix gates ALL side effects (stock deltas, cycle delete, machine update)
-- on the production-event INSERT's affected count. If affected = 0 (replay),
-- the transaction is a committed no-op.
--
-- This test mocks the MySQL global to verify the guard at the code level.
-- The companion DB-level test (TEST 5 in czcraft_repo_integration.py) verifies
-- the same scenario against the real staging DB with positive-only deltas.

-- Mock MySQL: tracks every update call and returns configurable affected counts.
local updateCalls = {}
local nextAffected = {}  -- queue of affected counts to return per update call

local function mockUpdate(stmt, args)
    local call = { stmt = stmt, args = args }
    updateCalls[#updateCalls + 1] = call
    -- Pop the next configured affected count, default to 1.
    if #nextAffected > 0 then
        return table.remove(nextAffected, 1)
    end
    return 1
end

MySQL = {
    transaction = {
        await = function(fn)
            -- Execute the transaction body synchronously.
            return fn()
        end,
    },
    update = mockUpdate,
    single = {
        await = function(stmt, args)
            return nil
        end,
    },
    query = {
        await = function(stmt, args)
            return {}
        end,
    },
}

-- Mock json (FiveM global) — only encode is used by cycles.lua.
json = {
    encode = function(tbl)
        return "{}"
    end,
}

CZCraft = CZCraft or {}

-- Load the repository module under test.
local CyclesRepo = dofile("resources/[meus-scripts]/qb-czcraft/server/repositories/cycles.lua")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "Assertion failed") .. " | expected=" .. tostring(expected) .. ", actual=" .. tostring(actual))
    end
end

local function assertTrue(value, message)
    if not value then
        error(message or "Expected truthy value")
    end
end

local function resetCalls()
    updateCalls = {}
    nextAffected = {}
end

local function countUpdatesContaining(fragment)
    local count = 0
    for _, call in ipairs(updateCalls) do
        if string.find(call.stmt, fragment, 1, true) then
            count = count + 1
        end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Test cases
-- ---------------------------------------------------------------------------

return {
    {
        name = "complete() applies stock deltas, cycle delete, and machine update on first call (affected=1)",
        test = function()
            resetCalls()
            -- First call: event INSERT returns 1 (new row), all subsequent updates return 1.
            nextAffected = { 1, 1, 1, 1, 1 }  -- event insert + 2 deltas + cycle delete + machine update

            local ok, err = CyclesRepo.complete({
                cycle_id = "cycle-1",
                machine_uuid = "machine-1",
                bill_id = "bill-1",
                completion_deltas = {
                    { item_name = "steel", quantity_delta = 1, reserved_delta = 0 },
                    { item_name = "iron", quantity_delta = 0, reserved_delta = -2 },
                },
                idempotency_key = "idem-1",
                event_id = "event-1",
                cycles_completed = 1,
                inputs_json = "[]",
                outputs_json = "[]",
                cost = 10,
                started_at = 1000,
                ended_at = 1030,
            })

            assertTrue(ok, "should succeed")
            assertEqual(err, nil, "no error")
            assertEqual(#updateCalls, 5, "5 update calls: event + 2 deltas + cycle delete + machine update")
            assertTrue(countUpdatesContaining("czcraft_production_events") == 1, "one production event insert")
            assertTrue(countUpdatesContaining("czcraft_machine_stock") == 2, "two stock delta updates")
            assertTrue(countUpdatesContaining("DELETE FROM `czcraft_active_cycles`") == 1, "one cycle delete")
            assertTrue(countUpdatesContaining("operational_status` = 'STOPPED'") == 1, "one machine update")
        end,
    },
    {
        name = "complete() skips ALL side effects on replay (event INSERT affected=0)",
        test = function()
            resetCalls()
            -- Replay: event INSERT returns 0 (duplicate key no-op).
            -- No subsequent updates should be called.
            nextAffected = { 0 }

            local ok, err = CyclesRepo.complete({
                cycle_id = "cycle-1",
                machine_uuid = "machine-1",
                bill_id = "bill-1",
                completion_deltas = {
                    { item_name = "steel", quantity_delta = 1, reserved_delta = 0 },
                    { item_name = "iron", quantity_delta = 0, reserved_delta = -2 },
                },
                idempotency_key = "idem-1",
                event_id = "event-1",
                cycles_completed = 1,
                inputs_json = "[]",
                outputs_json = "[]",
                cost = 10,
                started_at = 1000,
                ended_at = 1030,
            })

            assertTrue(ok, "should succeed (cached/prior result)")
            assertEqual(err, nil, "no error on replay")
            -- ONLY the event INSERT should have been called. No stock deltas, no cycle delete, no machine update.
            assertEqual(#updateCalls, 1, "only 1 update call (event insert) on replay")
            assertTrue(countUpdatesContaining("czcraft_production_events") == 1, "one production event insert (no-op)")
            assertTrue(countUpdatesContaining("czcraft_machine_stock") == 0, "NO stock delta updates on replay")
            assertTrue(countUpdatesContaining("DELETE FROM `czcraft_active_cycles`") == 0, "NO cycle delete on replay")
            assertTrue(countUpdatesContaining("operational_status` = 'STOPPED'") == 0, "NO machine update on replay")
        end,
    },
    {
        name = "complete() replay with positive-only deltas skips side effects (regression for test 3b double-produce)",
        test = function()
            resetCalls()
            -- This reproduces test 3b exactly: positive-only completion deltas
            -- (no negative reserved release). Before the fix, the replay would
            -- commit the +1 steel delta a second time, double-producing output.
            -- After the fix, affected=0 on the event INSERT skips the delta.
            nextAffected = { 0 }

            local ok, err = CyclesRepo.complete({
                cycle_id = "cycle-2",
                machine_uuid = "machine-2",
                bill_id = "bill-2",
                completion_deltas = {
                    { item_name = "steel", quantity_delta = 1, reserved_delta = 0 },
                },
                idempotency_key = "idem-2",
                event_id = "event-2",
                cycles_completed = 1,
                inputs_json = "[]",
                outputs_json = "[]",
                cost = 10,
                started_at = 1000,
                ended_at = 1030,
            })

            assertTrue(ok, "should succeed (cached/prior result)")
            assertEqual(err, nil, "no error on replay")
            assertEqual(#updateCalls, 1, "only 1 update call (event insert) on replay")
            assertTrue(countUpdatesContaining("czcraft_machine_stock") == 0,
                "NO stock delta on replay — output quantity must NOT increase a second time")
        end,
    },
    {
        name = "complete() with no completion_deltas still gates on event affected count",
        test = function()
            resetCalls()
            -- No deltas, but the guard should still prevent cycle delete + machine update on replay.
            nextAffected = { 0 }

            local ok, err = CyclesRepo.complete({
                cycle_id = "cycle-3",
                machine_uuid = "machine-3",
                bill_id = "bill-3",
                completion_deltas = {},
                idempotency_key = "idem-3",
                event_id = "event-3",
                cycles_completed = 1,
                inputs_json = "[]",
                outputs_json = "[]",
                cost = 0,
                started_at = 1000,
                ended_at = 1030,
            })

            assertTrue(ok, "should succeed")
            assertEqual(#updateCalls, 1, "only event insert on replay with no deltas")
            assertTrue(countUpdatesContaining("DELETE FROM `czcraft_active_cycles`") == 0,
                "NO cycle delete on replay even with no deltas")
            assertTrue(countUpdatesContaining("operational_status` = 'STOPPED'") == 0,
                "NO machine update on replay even with no deltas")
        end,
    },
}
