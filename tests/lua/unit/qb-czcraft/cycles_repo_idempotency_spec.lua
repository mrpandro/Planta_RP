-- Regression test for CyclesRepo.complete() idempotency guard.
-- This is the second replay-safety bug found by hand rather than by test.
-- The fix checks idempotency via MySQL.single.await BEFORE the transaction:
-- if the production event already exists (replay), return success without
-- running the transaction. This replaces the function-based transaction's
-- eventAffected==0 gate, which oxmysql 2.14.1 does not support (it requires
-- a table of queries, not a function callback).
--
-- This test mocks the MySQL global to verify the guard at the code level.
-- The companion DB-level test (TEST 5 in czcraft_repo_integration.py) verifies
-- the same scenario against the real staging DB with positive-only deltas.

-- Mock MySQL: tracks every query in the transaction and every single call.
local txQueries = {}
local singleCalls = {}
local singleReturnQueue = {}  -- queue of return values for MySQL.single.await

local function mockSingleAwait(stmt, args)
    singleCalls[#singleCalls + 1] = { stmt = stmt, args = args }
    if #singleReturnQueue > 0 then
        return table.remove(singleReturnQueue, 1)
    end
    return nil
end

MySQL = {
    transaction = {
        await = function(queries)
            -- Table-based transaction: execute each query's values are
            -- tracked. Return true (success).
            for _, q in ipairs(queries) do
                txQueries[#txQueries + 1] = { stmt = q.query, args = q.values }
            end
            return true
        end,
    },
    update = function(stmt, args)
        -- Should not be called directly anymore (queries go through the
        -- transaction table). Track if it is, for diagnostic purposes.
        txQueries[#txQueries + 1] = { stmt = stmt, args = args }
        return 1
    end,
    single = {
        await = mockSingleAwait,
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
    txQueries = {}
    singleCalls = {}
    singleReturnQueue = {}
end

local function countTxQueriesContaining(fragment)
    local count = 0
    for _, call in ipairs(txQueries) do
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
            -- First call: MySQL.single.await returns nil (no existing event).
            -- The transaction should run with all queries.
            singleReturnQueue = { nil }

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
            -- 1 single call (idempotency check) + 5 transaction queries:
            -- event insert + 2 deltas + cycle delete + machine update.
            assertEqual(#singleCalls, 1, "one idempotency check via MySQL.single.await")
            assertEqual(#txQueries, 5, "5 tx queries: event + 2 deltas + cycle delete + machine update")
            assertTrue(countTxQueriesContaining("czcraft_production_events") == 1, "one production event insert")
            assertTrue(countTxQueriesContaining("czcraft_machine_stock") == 2, "two stock delta updates")
            assertTrue(countTxQueriesContaining("DELETE FROM `czcraft_active_cycles`") == 1, "one cycle delete")
            assertTrue(countTxQueriesContaining("operational_status` = 'STOPPED'") == 1, "one machine update")
        end,
    },
    {
        name = "complete() skips ALL side effects on replay (event INSERT affected=0)",
        test = function()
            resetCalls()
            -- Replay: MySQL.single.await returns an existing event row.
            -- No transaction should run.
            singleReturnQueue = { { event_id = "event-1" } }

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
            -- Only the idempotency check should have run. No transaction queries.
            assertEqual(#singleCalls, 1, "one idempotency check via MySQL.single.await")
            assertEqual(#txQueries, 0, "NO transaction queries on replay")
            assertTrue(countTxQueriesContaining("czcraft_production_events") == 0, "NO production event insert on replay")
            assertTrue(countTxQueriesContaining("czcraft_machine_stock") == 0, "NO stock delta updates on replay")
            assertTrue(countTxQueriesContaining("DELETE FROM `czcraft_active_cycles`") == 0, "NO cycle delete on replay")
            assertTrue(countTxQueriesContaining("operational_status` = 'STOPPED'") == 0, "NO machine update on replay")
        end,
    },
    {
        name = "complete() replay with positive-only deltas skips side effects (regression for test 3b double-produce)",
        test = function()
            resetCalls()
            -- This reproduces test 3b exactly: positive-only completion deltas
            -- (no negative reserved release). Before the fix, the replay would
            -- commit the +1 steel delta a second time, double-producing output.
            -- After the fix, the idempotency check returns an existing event,
            -- so no transaction runs and no deltas are applied.
            singleReturnQueue = { { event_id = "event-2" } }

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
            assertEqual(#txQueries, 0, "NO transaction queries on replay")
            assertTrue(countTxQueriesContaining("czcraft_machine_stock") == 0,
                "NO stock delta on replay — output quantity must NOT increase a second time")
        end,
    },
    {
        name = "complete() with no completion_deltas still gates on event affected count",
        test = function()
            resetCalls()
            -- No deltas, but the guard should still prevent cycle delete + machine update on replay.
            singleReturnQueue = { { event_id = "event-3" } }

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
            assertEqual(#txQueries, 0, "NO transaction queries on replay even with no deltas")
            assertTrue(countTxQueriesContaining("DELETE FROM `czcraft_active_cycles`") == 0,
                "NO cycle delete on replay even with no deltas")
            assertTrue(countTxQueriesContaining("operational_status` = 'STOPPED'") == 0,
                "NO machine update on replay even with no deltas")
        end,
    },
}
