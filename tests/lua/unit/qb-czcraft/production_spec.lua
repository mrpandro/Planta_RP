-- qb-czcraft production domain tests
-- Pure tests for cycle start validation (input availability, output capacity),
-- start/completion stock deltas, idempotent completion guard, and next-due math.

dofile("resources/[meus-scripts]/qb-czcraft/shared/constants.lua")
local Production = dofile("resources/[meus-scripts]/qb-czcraft/server/domain/production.lua")

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

local function assertContains(haystack, needle, message)
    if type(haystack) ~= 'string' or string.find(haystack, needle, 1, true) == nil then
        error((message or "Expected string to contain needle") .. " | needle=" .. tostring(needle) .. ", haystack=" .. tostring(haystack))
    end
end

local function makeRecipe()
    return {
        id = 'smelt_steel',
        machine = 'refinery',
        duration = 60,
        primaryOutput = 'steel',
        inputs = { { item = 'iron', amount = 5 }, { item = 'metalscrap', amount = 2 } },
        outputs = { { item = 'steel', amount = 2 } },
    }
end

local function makeStockRows()
    return {
        { item_name = 'iron', quantity = 100, reserved_quantity = 0 },
        { item_name = 'metalscrap', quantity = 50, reserved_quantity = 0 },
        { item_name = 'steel', quantity = 10, reserved_quantity = 0 },
    }
end

return {
    {
        name = "cycle start happy path passes and computes deltas",
        test = function()
            local ok, reason, computed = Production.validateCycleStart({
                recipe = makeRecipe(),
                stockRows = makeStockRows(),
                machineUsedWeight = 1000,
                machineReservedWeight = 0,
                machineCapacity = 100000,
                itemWeights = { iron = 100, metalscrap = 100, steel = 100 },
            })
            assertTrue(ok, "should pass")
            assertEqual(reason, nil, "no reason")
            assertEqual(#computed.inputsToConsume, 2, "two inputs")
            assertEqual(computed.inputsToConsume[1].item_name, 'iron', "input 1 iron")
            assertEqual(computed.inputsToConsume[1].amount, 5, "input 1 amount 5")
            assertEqual(#computed.outputsToReserve, 1, "one output")
            assertEqual(computed.outputsToReserve[1].item_name, 'steel', "output steel")
            assertEqual(computed.outputsToReserve[1].amount, 2, "output amount 2")
            assertEqual(computed.reservedWeightDelta, 200, "2*100=200 reserved weight")
        end,
    },
    {
        name = "cycle start fails when input is insufficient",
        test = function()
            local stockRows = makeStockRows()
            stockRows[1].quantity = 3  -- only 3 iron, need 5
            local ok, reason = Production.validateCycleStart({
                recipe = makeRecipe(),
                stockRows = stockRows,
                machineUsedWeight = 1000,
                machineReservedWeight = 0,
                machineCapacity = 100000,
                itemWeights = { iron = 100, metalscrap = 100, steel = 100 },
            })
            assertFalse(ok, "should fail")
            assertContains(reason, "insufficient input iron", "reason mentions iron")
        end,
    },
    {
        name = "cycle start fails when input is fully reserved",
        test = function()
            local stockRows = makeStockRows()
            stockRows[1].quantity = 100
            stockRows[1].reserved_quantity = 98  -- only 2 available, need 5
            local ok, reason = Production.validateCycleStart({
                recipe = makeRecipe(),
                stockRows = stockRows,
                machineUsedWeight = 1000,
                machineReservedWeight = 0,
                machineCapacity = 100000,
                itemWeights = { iron = 100, metalscrap = 100, steel = 100 },
            })
            assertFalse(ok, "should fail")
            assertContains(reason, "insufficient input iron", "reason mentions iron")
        end,
    },
    {
        name = "cycle start fails when output capacity exceeded",
        test = function()
            local ok, reason = Production.validateCycleStart({
                recipe = makeRecipe(),
                stockRows = makeStockRows(),
                machineUsedWeight = 99900,
                machineReservedWeight = 0,
                machineCapacity = 100000,
                itemWeights = { iron = 100, metalscrap = 100, steel = 100 },
            })
            assertFalse(ok, "should fail")
            assertContains(reason, "output cap", "reason mentions output cap")
        end,
    },
    {
        name = "computeStartDeltas: inputs decrease, outputs reserved",
        test = function()
            local _, _, computed = Production.validateCycleStart({
                recipe = makeRecipe(),
                stockRows = makeStockRows(),
                machineUsedWeight = 1000,
                machineReservedWeight = 0,
                machineCapacity = 100000,
                itemWeights = { iron = 100, metalscrap = 100, steel = 100 },
            })
            local deltas = Production.computeStartDeltas(computed).stockDeltas
            assertEqual(#deltas, 3, "3 delta rows (2 inputs + 1 output)")
            -- iron: -5 quantity, 0 reserved
            assertEqual(deltas[1].item_name, 'iron', "delta 1 iron")
            assertEqual(deltas[1].quantity_delta, -5, "iron quantity -5")
            assertEqual(deltas[1].reserved_delta, 0, "iron reserved 0")
            -- metalscrap: -2 quantity
            assertEqual(deltas[2].item_name, 'metalscrap', "delta 2 metalscrap")
            assertEqual(deltas[2].quantity_delta, -2, "metalscrap quantity -2")
            -- steel: 0 quantity, +2 reserved
            assertEqual(deltas[3].item_name, 'steel', "delta 3 steel")
            assertEqual(deltas[3].quantity_delta, 0, "steel quantity 0")
            assertEqual(deltas[3].reserved_delta, 2, "steel reserved +2")
        end,
    },
    {
        name = "computeCompletionDeltas: reserved becomes actual stock",
        test = function()
            local _, _, computed = Production.validateCycleStart({
                recipe = makeRecipe(),
                stockRows = makeStockRows(),
                machineUsedWeight = 1000,
                machineReservedWeight = 0,
                machineCapacity = 100000,
                itemWeights = { iron = 100, metalscrap = 100, steel = 100 },
            })
            local deltas = Production.computeCompletionDeltas(computed).stockDeltas
            assertEqual(#deltas, 1, "1 output delta")
            assertEqual(deltas[1].item_name, 'steel', "steel")
            assertEqual(deltas[1].quantity_delta, 2, "quantity +2")
            assertEqual(deltas[1].reserved_delta, -2, "reserved -2")
        end,
    },
    {
        name = "canCompleteCycle: RUNNING cycle can complete",
        test = function()
            local ok = Production.canCompleteCycle({ status = 'RUNNING', cycle_id = 'c1', cycle_sequence = 1 })
            assertTrue(ok, "RUNNING can complete")
        end,
    },
    {
        name = "canCompleteCycle: COMPLETED cycle is idempotent no-op",
        test = function()
            local ok, reason = Production.canCompleteCycle({ status = 'COMPLETED', cycle_id = 'c1', cycle_sequence = 1 })
            assertFalse(ok, "COMPLETED cannot complete again")
            assertContains(reason, "already completed", "reason mentions idempotent")
        end,
    },
    {
        name = "canCompleteCycle: PENDING cycle cannot complete",
        test = function()
            local ok, reason = Production.canCompleteCycle({ status = 'PENDING', cycle_id = 'c1', cycle_sequence = 1 })
            assertFalse(ok, "PENDING cannot complete")
            assertContains(reason, "RUNNING", "reason mentions RUNNING")
        end,
    },
    {
        name = "computeNextDue adds duration to completed time",
        test = function()
            assertEqual(Production.computeNextDue(1000, 60), 1060, "1000 + 60 = 1060")
        end,
    },
    {
        name = "computeNextDue handles nil inputs",
        test = function()
            assertEqual(Production.computeNextDue(nil, 60), 60, "nil + 60 = 60")
            assertEqual(Production.computeNextDue(1000, nil), 1000, "1000 + nil = 1000")
        end,
    },
}
