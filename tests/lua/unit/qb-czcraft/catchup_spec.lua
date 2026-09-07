-- qb-czcraft catch-up domain tests
-- Pure tests for chunked catch-up: zero/negative elapsed, insufficient inputs,
-- output cap, disabled recipe, long downtime (multi-chunk), and MAINTAIN_X
-- overshoot behavior during recovery.

dofile("resources/[meus-scripts]/qb-czcraft/shared/constants.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/recipes.lua")
local Bills = dofile("resources/[meus-scripts]/qb-czcraft/server/domain/bills.lua")
local CatchUp = dofile("resources/[meus-scripts]/qb-czcraft/server/domain/catchup.lua")

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
        enabled = true,
        primaryOutput = 'steel',
        inputs = { { item = 'iron', amount = 5 } },
        outputs = { { item = 'steel', amount = 2 } },
    }
end

local function makeStockRows(ironQty)
    return {
        { item_name = 'iron', quantity = ironQty or 1000, reserved_quantity = 0 },
        { item_name = 'steel', quantity = 0, reserved_quantity = 0 },
    }
end

local function makeParams(opts)
    opts = opts or {}
    return {
        lastCompletedAt = opts.lastCompletedAt or 0,
        now = opts.now or 3600,
        recipe = opts.recipe or makeRecipe(),
        bill = opts.bill,
        stockRows = opts.stockRows or makeStockRows(),
        machineUsedWeight = opts.machineUsedWeight or 0,
        machineReservedWeight = opts.machineReservedWeight or 0,
        machineCapacity = opts.machineCapacity or 1000000,
        itemWeights = opts.itemWeights or { iron = 100, steel = 100 },
        batchOutputAmount = opts.batchOutputAmount or 2,
        maxCyclesPerChunk = opts.maxCyclesPerChunk or 100,
        maxChunks = opts.maxChunks or 100,
        stockPlusReservedByItem = opts.stockPlusReservedByItem or { steel = 0 },
    }
end

return {
    {
        name = "catch-up: zero elapsed returns 0 cycles, no block",
        test = function()
            local r = CatchUp.computeCatchUpChunk(makeParams({ lastCompletedAt = 1000, now = 1000 }))
            assertEqual(r.cyclesToRun, 0, "zero cycles")
            assertEqual(r.blockReason, nil, "no block reason")
            assertFalse(r.shouldContinue, "should not continue")
        end,
    },
    {
        name = "catch-up: negative elapsed returns 0 cycles, no block",
        test = function()
            local r = CatchUp.computeCatchUpChunk(makeParams({ lastCompletedAt = 2000, now = 1000 }))
            assertEqual(r.cyclesToRun, 0, "zero cycles")
            assertEqual(r.blockReason, nil, "no block reason")
            assertFalse(r.shouldContinue, "should not continue")
        end,
    },
    {
        name = "catch-up: disabled recipe blocks immediately",
        test = function()
            local recipe = makeRecipe()
            recipe.enabled = false
            local r = CatchUp.computeCatchUpChunk(makeParams({ recipe = recipe }))
            assertEqual(r.cyclesToRun, 0, "zero cycles")
            assertContains(r.blockReason, "recipe disabled", "reason mentions disabled")
            assertFalse(r.shouldContinue, "should not continue")
        end,
    },
    {
        name = "catch-up: insufficient inputs blocks with reason",
        test = function()
            local r = CatchUp.computeCatchUpChunk(makeParams({
                stockRows = makeStockRows(0),
            }))
            assertEqual(r.cyclesToRun, 0, "zero cycles")
            assertContains(r.blockReason, "insufficient inputs", "reason mentions inputs")
            assertFalse(r.shouldContinue, "should not continue")
        end,
    },
    {
        name = "catch-up: output cap blocks with reason",
        test = function()
            local r = CatchUp.computeCatchUpChunk(makeParams({
                machineUsedWeight = 999900,
                machineCapacity = 1000000,
            }))
            assertEqual(r.cyclesToRun, 0, "zero cycles")
            assertContains(r.blockReason, "output cap", "reason mentions output cap")
            assertFalse(r.shouldContinue, "should not continue")
        end,
    },
    {
        name = "catch-up: single chunk runs time-bounded cycles",
        test = function()
            -- 3600s elapsed, 60s duration -> 60 cycles, but capped at 100.
            local r = CatchUp.computeCatchUpChunk(makeParams({ now = 3600, lastCompletedAt = 0 }))
            assertEqual(r.cyclesToRun, 60, "3600/60 = 60 cycles")
            assertTrue(r.shouldContinue == false, "no remaining time after 60 cycles")
        end,
    },
    {
        name = "catch-up: chunked with maxCyclesPerChunk continues across chunks",
        test = function()
            -- 600s elapsed, 60s duration -> 10 cycles total, max 3 per chunk.
            local result = CatchUp.simulateFullCatchUp(makeParams({
                now = 600,
                lastCompletedAt = 0,
                maxCyclesPerChunk = 3,
                stockRows = makeStockRows(1000),
            }))
            assertEqual(result.totalCycles, 10, "10 total cycles")
            assertTrue(#result.chunks >= 3, "at least 3 chunks (10/3)")
            assertEqual(result.finalBlockReason, nil, "no block — ran to completion")
        end,
    },
    {
        name = "catch-up: long downtime (24h) runs to completion with enough inputs",
        test = function()
            -- 24h = 86400s, 60s duration -> 1440 cycles.
            local result = CatchUp.simulateFullCatchUp(makeParams({
                now = 86400,
                lastCompletedAt = 0,
                maxCyclesPerChunk = 100,
                stockRows = makeStockRows(100000),
            }))
            assertEqual(result.totalCycles, 1440, "1440 cycles in 24h")
            assertEqual(result.finalBlockReason, nil, "no block")
        end,
    },
    {
        name = "catch-up: long downtime stops when inputs run out",
        test = function()
            -- 86400s elapsed, 60s duration, but only 50 iron (10 cycles).
            local result = CatchUp.simulateFullCatchUp(makeParams({
                now = 86400,
                lastCompletedAt = 0,
                maxCyclesPerChunk = 100,
                stockRows = makeStockRows(50),
            }))
            assertEqual(result.totalCycles, 10, "10 cycles before inputs run out")
            assertContains(result.finalBlockReason, "insufficient inputs", "block on inputs")
        end,
    },
    {
        name = "catch-up: PRODUCE_X bill stops at target",
        test = function()
            -- 3600s elapsed -> 60 cycles, 2 per cycle = 120 output.
            -- Bill target = 20, so 10 cycles.
            local result = CatchUp.simulateFullCatchUp(makeParams({
                now = 3600,
                lastCompletedAt = 0,
                bill = { mode = Bills.Mode.PRODUCE_X, target_quantity = 20, produced_quantity = 0 },
                stockRows = makeStockRows(1000),
            }))
            assertEqual(result.totalCycles, 10, "10 cycles to produce 20 (2 per cycle)")
        end,
    },
    {
        name = "catch-up: MAINTAIN_X bill stops when target reached",
        test = function()
            -- Target = 20 steel, batch = 2, start at 0.
            -- Need 10 cycles to reach 20, then MAINTAIN_X is satisfied.
            local result = CatchUp.simulateFullCatchUp(makeParams({
                now = 3600,
                lastCompletedAt = 0,
                bill = { mode = Bills.Mode.MAINTAIN_X, target_quantity = 20 },
                stockRows = makeStockRows(1000),
                stockPlusReservedByItem = { steel = 0 },
            }))
            assertEqual(result.totalCycles, 10, "10 cycles to reach maintain target of 20")
        end,
    },
    {
        name = "catch-up: MAINTAIN_X allows overshoot by at most one batch",
        test = function()
            -- Target = 21, batch = 2, start at 0.
            -- ceil(21/2) = 11 cycles -> 22 output (overshoot by 1, within one batch of 2).
            local result = CatchUp.simulateFullCatchUp(makeParams({
                now = 3600,
                lastCompletedAt = 0,
                bill = { mode = Bills.Mode.MAINTAIN_X, target_quantity = 21 },
                stockRows = makeStockRows(1000),
                stockPlusReservedByItem = { steel = 0 },
            }))
            assertEqual(result.totalCycles, 11, "11 cycles -> 22 output (overshoot 1, within batch of 2)")
        end,
    },
}
