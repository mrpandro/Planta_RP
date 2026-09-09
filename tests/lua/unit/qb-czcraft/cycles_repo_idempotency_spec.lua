-- Regression test for CyclesRepo.complete() and applyCatchUpChunk()
-- replay-safety using MySQL.startTransaction + affected-count gating.
--
-- Bug history: the prior implementation used a preflight SELECT to check
-- idempotency, then executed side effects in a MySQL.transaction.await
-- (query table). Two concurrent callers could both pass the preflight
-- SELECT, then both execute the transaction and both apply stock deltas —
-- a check-then-act replay race. The fix moves the idempotent INSERT IGNORE
-- to the FIRST statement inside a MySQL.startTransaction callback and
-- gates ALL side effects on its affectedRows (1 = new, 0 = replay/race).
--
-- This test mocks MySQL.startTransaction to verify the guard at the code
-- level. The tx function returns a ResultSetHeader with affectedRows for
-- INSERT and an empty table for other statements.

-- Mock MySQL: startTransaction calls the callback with a tx function.
-- txQueries tracks every statement executed inside the transaction.
-- insertAffectedQueue controls the affectedRows returned for INSERT IGNORE.
local txQueries = {}
local insertAffectedQueue = {}

local function mockStartTransaction(cb)
    local function tx(stmt, args)
        txQueries[#txQueries + 1] = { stmt = stmt, args = args }
        if string.find(stmt, 'INSERT', 1, true) then
            local affected = 1
            if #insertAffectedQueue > 0 then
                affected = table.remove(insertAffectedQueue, 1)
            end
            return { affectedRows = affected, insertId = 0 }
        end
        return {}
    end
    local result = cb(tx)
    return result ~= false
end

MySQL = {
    startTransaction = mockStartTransaction,
    update = {
        await = function(stmt, args)
            error('MySQL.update.await should not be called — use startTransaction')
        end,
    },
    single = {
        await = function(stmt, args)
            error('MySQL.single.await should not be called — no preflight SELECT')
        end,
    },
    query = {
        await = function(stmt, args) return {} end,
    },
}

-- Mock json (FiveM global).
json = {
    encode = function(tbl) return '{}' end,
    decode = function(s) return {} end,
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

local function assertFalse(value, message)
    if value then
        error(message or "Expected falsy value")
    end
end

local function resetCalls()
    txQueries = {}
    insertAffectedQueue = {}
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
-- Test cases: complete()
-- ---------------------------------------------------------------------------

local tests = {}

tests[#tests + 1] = {
    name = "complete() applies all side effects on first call (INSERT affected=1)",
    test = function()
        resetCalls()
        insertAffectedQueue = { 1 }

        local ok, err, replayed = CyclesRepo.complete({
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
        assertFalse(replayed, "should not be a replay on first call")
        -- 5 tx queries: event insert + 2 deltas + cycle delete + machine update.
        assertEqual(#txQueries, 5, "5 tx queries: event + 2 deltas + cycle delete + machine update")
        assertTrue(countTxQueriesContaining("INSERT IGNORE INTO `czcraft_production_events`") == 1,
            "first statement is INSERT IGNORE production event")
        assertTrue(countTxQueriesContaining("czcraft_machine_stock") == 2, "two stock delta updates")
        assertTrue(countTxQueriesContaining("DELETE FROM `czcraft_active_cycles`") == 1, "one cycle delete")
        assertTrue(countTxQueriesContaining("operational_status` = 'STOPPED'") == 1, "one machine update")
    end,
}

tests[#tests + 1] = {
    name = "complete() skips ALL side effects on replay (INSERT affected=0)",
    test = function()
        resetCalls()
        insertAffectedQueue = { 0 }

        local ok, err, replayed = CyclesRepo.complete({
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

        assertTrue(ok, "should succeed (no-op commit)")
        assertEqual(err, nil, "no error on replay")
        assertTrue(replayed, "should signal replay so caller skips bill increment + next cycle")
        -- Only the INSERT IGNORE should have run; no side effects.
        assertEqual(#txQueries, 1, "only the INSERT IGNORE — no side effects on replay")
        assertTrue(countTxQueriesContaining("INSERT IGNORE INTO `czcraft_production_events`") == 1,
            "the single query is the idempotent INSERT IGNORE")
        assertTrue(countTxQueriesContaining("czcraft_machine_stock") == 0, "NO stock delta updates on replay")
        assertTrue(countTxQueriesContaining("DELETE FROM `czcraft_active_cycles`") == 0, "NO cycle delete on replay")
        assertTrue(countTxQueriesContaining("operational_status` = 'STOPPED'") == 0, "NO machine update on replay")
    end,
}

tests[#tests + 1] = {
    name = "complete() replay with positive-only deltas skips side effects (no double-produce)",
    test = function()
        resetCalls()
        insertAffectedQueue = { 0 }

        local ok, err, replayed = CyclesRepo.complete({
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

        assertTrue(ok, "should succeed")
        assertTrue(replayed, "should signal replay")
        assertEqual(#txQueries, 1, "only INSERT IGNORE on replay")
        assertTrue(countTxQueriesContaining("czcraft_machine_stock") == 0,
            "NO stock delta on replay — output quantity must NOT increase a second time")
    end,
}

tests[#tests + 1] = {
    name = "complete() with no completion_deltas still gates on INSERT affected count",
    test = function()
        resetCalls()
        insertAffectedQueue = { 0 }

        local ok, err, replayed = CyclesRepo.complete({
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
        assertTrue(replayed, "should signal replay")
        assertEqual(#txQueries, 1, "only INSERT IGNORE on replay even with no deltas")
        assertTrue(countTxQueriesContaining("DELETE FROM `czcraft_active_cycles`") == 0,
            "NO cycle delete on replay even with no deltas")
    end,
}

tests[#tests + 1] = {
    name = "complete() INSERT is the FIRST statement (gates all subsequent side effects)",
    test = function()
        resetCalls()
        insertAffectedQueue = { 1 }

        CyclesRepo.complete({
            cycle_id = "cycle-4",
            machine_uuid = "machine-4",
            bill_id = "bill-4",
            completion_deltas = {
                { item_name = "steel", quantity_delta = 1, reserved_delta = 0 },
            },
            idempotency_key = "idem-4",
            event_id = "event-4",
            cycles_completed = 1,
            inputs_json = "[]",
            outputs_json = "[]",
            cost = 0,
            started_at = 1000,
            ended_at = 1030,
        })

        assertTrue(#txQueries > 0, "at least one query should run")
        assertTrue(string.find(txQueries[1].stmt, "INSERT IGNORE", 1, true) ~= nil,
            "first tx query must be the idempotent INSERT IGNORE — side effects are gated on its affectedRows")
    end,
}

-- ---------------------------------------------------------------------------
-- Test cases: applyCatchUpChunk()
-- ---------------------------------------------------------------------------

tests[#tests + 1] = {
    name = "applyCatchUpChunk() applies side effects on first call (INSERT affected=1)",
    test = function()
        resetCalls()
        insertAffectedQueue = { 1 }

        local ok, err, replayed = CyclesRepo.applyCatchUpChunk({
            machine_uuid = "machine-1",
            bill_id = "bill-1",
            recipe = {
                inputs = { { item = "iron", amount = 2 } },
                outputs = { { item = "steel", amount = 1 } },
            },
            cycles_to_run = 5,
            chunk_sequence = 1,
            chunk_started_at = 1000,
            chunk_ended_at = 1300,
            next_due_at = 1300,
            standard_cost = 10,
            idempotency_key = "catchup-1",
            event_id = "event-c1",
        })

        assertTrue(ok, "should succeed")
        assertFalse(replayed, "should not be a replay")
        -- event insert + 1 input delta + 1 output upsert + machine update = 4
        assertEqual(#txQueries, 4, "4 tx queries: event + input delta + output upsert + machine update")
        assertTrue(string.find(txQueries[1].stmt, "INSERT IGNORE", 1, true) ~= nil,
            "first tx query is INSERT IGNORE")
    end,
}

tests[#tests + 1] = {
    name = "applyCatchUpChunk() skips ALL side effects on replay (INSERT affected=0)",
    test = function()
        resetCalls()
        insertAffectedQueue = { 0 }

        local ok, err, replayed = CyclesRepo.applyCatchUpChunk({
            machine_uuid = "machine-1",
            bill_id = "bill-1",
            recipe = {
                inputs = { { item = "iron", amount = 2 } },
                outputs = { { item = "steel", amount = 1 } },
            },
            cycles_to_run = 5,
            chunk_sequence = 1,
            chunk_started_at = 1000,
            chunk_ended_at = 1300,
            next_due_at = 1300,
            standard_cost = 10,
            idempotency_key = "catchup-1",
            event_id = "event-c1",
        })

        assertTrue(ok, "should succeed (no-op commit)")
        assertTrue(replayed, "should signal replay")
        assertEqual(#txQueries, 1, "only INSERT IGNORE on replay")
        assertTrue(countTxQueriesContaining("czcraft_machine_stock") == 0,
            "NO stock deltas on replay — no double-consume or double-produce")
    end,
}

tests[#tests + 1] = {
    name = "applyCatchUpChunk() with zero cycles returns early without transaction",
    test = function()
        resetCalls()

        local ok, err, replayed = CyclesRepo.applyCatchUpChunk({
            machine_uuid = "machine-1",
            bill_id = "bill-1",
            recipe = { inputs = {}, outputs = {} },
            cycles_to_run = 0,
            chunk_sequence = 1,
            chunk_started_at = 1000,
            chunk_ended_at = 1000,
            next_due_at = 1000,
            standard_cost = 0,
            idempotency_key = "catchup-zero",
            event_id = "event-cz",
        })

        assertTrue(ok, "should succeed")
        assertFalse(replayed, "zero cycles is not a replay")
        assertEqual(#txQueries, 0, "no transaction queries for zero cycles")
    end,
}

return tests
