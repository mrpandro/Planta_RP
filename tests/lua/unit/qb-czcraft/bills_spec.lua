-- qb-czcraft bills domain tests
-- Pure tests for PRODUCE_X/MAINTAIN_X validation, completion, cycle-start
-- decisions, stable bill selection, and multi-cycle chunk computation.

dofile("resources/[meus-scripts]/qb-czcraft/shared/constants.lua")
local Bills = dofile("resources/[meus-scripts]/qb-czcraft/server/domain/bills.lua")

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

return {
    {
        name = "PRODUCE_X bill creation passes when target is a multiple of batch",
        test = function()
            local ok, reason = Bills.validateBillCreation({
                mode = Bills.Mode.PRODUCE_X,
                recipeId = 'smelt_steel',
                primaryOutput = 'steel',
                targetQuantity = 100,
                batchOutputAmount = 2,
            })
            assertTrue(ok, "should pass")
            assertEqual(reason, nil, "no reason")
        end,
    },
    {
        name = "PRODUCE_X bill creation fails when target is not a multiple of batch",
        test = function()
            local ok, reason = Bills.validateBillCreation({
                mode = Bills.Mode.PRODUCE_X,
                recipeId = 'smelt_steel',
                primaryOutput = 'steel',
                targetQuantity = 101,
                batchOutputAmount = 2,
            })
            assertFalse(ok, "should fail")
            assertContains(reason, "multiple", "reason mentions multiple")
        end,
    },
    {
        name = "MAINTAIN_X bill creation passes (no multiple constraint)",
        test = function()
            local ok = Bills.validateBillCreation({
                mode = Bills.Mode.MAINTAIN_X,
                recipeId = 'make_components',
                primaryOutput = 'cz_components',
                targetQuantity = 501,
                batchOutputAmount = 10,
            })
            assertTrue(ok, "MAINTAIN_X should pass with non-multiple target")
        end,
    },
    {
        name = "bill creation fails for unknown mode",
        test = function()
            local ok, reason = Bills.validateBillCreation({
                mode = 'DELETE_EVERYTHING',
                recipeId = 'smelt_steel',
                primaryOutput = 'steel',
                targetQuantity = 100,
                batchOutputAmount = 2,
            })
            assertFalse(ok, "should fail")
            assertContains(reason, "UNTIL_X", "reason mentions valid modes including UNTIL_X")
        end,
    },
    {
        name = "bill creation fails for non-positive target",
        test = function()
            local ok = Bills.validateBillCreation({
                mode = Bills.Mode.PRODUCE_X,
                recipeId = 'smelt_steel',
                primaryOutput = 'steel',
                targetQuantity = 0,
                batchOutputAmount = 2,
            })
            assertFalse(ok, "zero target should fail")
        end,
    },
    {
        name = "bill creation fails for non-integer target",
        test = function()
            local ok = Bills.validateBillCreation({
                mode = Bills.Mode.PRODUCE_X,
                recipeId = 'smelt_steel',
                primaryOutput = 'steel',
                targetQuantity = 10.5,
                batchOutputAmount = 2,
            })
            assertFalse(ok, "fractional target should fail")
        end,
    },
    {
        name = "PRODUCE_X is complete when produced >= target",
        test = function()
            local bill = { mode = Bills.Mode.PRODUCE_X, target_quantity = 100, produced_quantity = 100 }
            assertTrue(Bills.isProduceXComplete(bill), "should be complete")
        end,
    },
    {
        name = "PRODUCE_X is not complete when produced < target",
        test = function()
            local bill = { mode = Bills.Mode.PRODUCE_X, target_quantity = 100, produced_quantity = 99 }
            assertFalse(Bills.isProduceXComplete(bill), "should not be complete")
        end,
    },
    {
        name = "MAINTAIN_X is satisfied when stock+reserved >= target",
        test = function()
            local bill = { mode = Bills.Mode.MAINTAIN_X, target_quantity = 500 }
            assertTrue(Bills.isMaintainXSatisfied(bill, 500, 10), "should be satisfied")
            assertTrue(Bills.isMaintainXSatisfied(bill, 600, 10), "overshoot is satisfied")
        end,
    },
    {
        name = "MAINTAIN_X is not satisfied when stock+reserved < target",
        test = function()
            local bill = { mode = Bills.Mode.MAINTAIN_X, target_quantity = 500 }
            assertFalse(Bills.isMaintainXSatisfied(bill, 499, 10), "should not be satisfied")
        end,
    },
    {
        name = "shouldStartCycle: PRODUCE_X not complete starts",
        test = function()
            local bill = { mode = Bills.Mode.PRODUCE_X, enabled = true, status = 'ACTIVE', target_quantity = 100, produced_quantity = 50 }
            assertTrue(Bills.shouldStartCycle(bill, 0, 2), "should start")
        end,
    },
    {
        name = "shouldStartCycle: PRODUCE_X complete does not start",
        test = function()
            local bill = { mode = Bills.Mode.PRODUCE_X, enabled = true, status = 'ACTIVE', target_quantity = 100, produced_quantity = 100 }
            assertFalse(Bills.shouldStartCycle(bill, 0, 2), "should not start when complete")
        end,
    },
    {
        name = "shouldStartCycle: MAINTAIN_X below target starts",
        test = function()
            local bill = { mode = Bills.Mode.MAINTAIN_X, enabled = true, status = 'ACTIVE', target_quantity = 500 }
            assertTrue(Bills.shouldStartCycle(bill, 490, 10), "should start when below target")
        end,
    },
    {
        name = "shouldStartCycle: MAINTAIN_X at target does not start",
        test = function()
            local bill = { mode = Bills.Mode.MAINTAIN_X, enabled = true, status = 'ACTIVE', target_quantity = 500 }
            assertFalse(Bills.shouldStartCycle(bill, 500, 10), "should not start when at target")
        end,
    },
    {
        name = "shouldStartCycle: paused bill does not start",
        test = function()
            local bill = { mode = Bills.Mode.PRODUCE_X, enabled = true, status = 'PAUSED', target_quantity = 100, produced_quantity = 0 }
            assertFalse(Bills.shouldStartCycle(bill, 0, 2), "paused should not start")
        end,
    },
    {
        name = "shouldStartCycle: disabled bill does not start",
        test = function()
            local bill = { mode = Bills.Mode.PRODUCE_X, enabled = false, status = 'ACTIVE', target_quantity = 100, produced_quantity = 0 }
            assertFalse(Bills.shouldStartCycle(bill, 0, 2), "disabled should not start")
        end,
    },
    {
        name = "selectNextBill: picks the earliest-created enabled bill",
        test = function()
            local bills = {
                { bill_id = 'b3', enabled = true, status = 'ACTIVE', mode = 'PRODUCE_X', priority = 'NORMAL', created_sequence = 30, target_quantity = 100, produced_quantity = 0, primary_output = 'steel' },
                { bill_id = 'b1', enabled = true, status = 'ACTIVE', mode = 'PRODUCE_X', priority = 'NORMAL', created_sequence = 10, target_quantity = 100, produced_quantity = 0, primary_output = 'steel' },
                { bill_id = 'b2', enabled = true, status = 'ACTIVE', mode = 'PRODUCE_X', priority = 'NORMAL', created_sequence = 20, target_quantity = 100, produced_quantity = 0, primary_output = 'steel' },
            }
            local selected = Bills.selectNextBill(bills, {}, { b1 = 2, b2 = 2, b3 = 2 })
            assertEqual(selected.bill_id, 'b1', "should pick earliest created")
        end,
    },
    {
        name = "selectNextBill: skips paused and removed bills",
        test = function()
            local bills = {
                { bill_id = 'b1', enabled = true, status = 'PAUSED', mode = 'PRODUCE_X', priority = 'NORMAL', created_sequence = 10, target_quantity = 100, produced_quantity = 0, primary_output = 'steel' },
                { bill_id = 'b2', enabled = true, status = 'REMOVED', mode = 'PRODUCE_X', priority = 'NORMAL', created_sequence = 20, target_quantity = 100, produced_quantity = 0, primary_output = 'steel' },
                { bill_id = 'b3', enabled = true, status = 'ACTIVE', mode = 'PRODUCE_X', priority = 'NORMAL', created_sequence = 30, target_quantity = 100, produced_quantity = 0, primary_output = 'steel' },
            }
            local selected = Bills.selectNextBill(bills, {}, { b1 = 2, b2 = 2, b3 = 2 })
            assertEqual(selected.bill_id, 'b3', "should skip paused/removed")
        end,
    },
    {
        name = "selectNextBill: returns nil when no bills can start",
        test = function()
            local bills = {
                { bill_id = 'b1', enabled = true, status = 'ACTIVE', mode = 'PRODUCE_X', priority = 'NORMAL', created_sequence = 10, target_quantity = 100, produced_quantity = 100, primary_output = 'steel' },
            }
            local selected = Bills.selectNextBill(bills, {}, { b1 = 2 })
            assertEqual(selected, nil, "should return nil when all complete")
        end,
    },
    {
        name = "applyCycleCompletion adds batch output to produced",
        test = function()
            local bill = { produced_quantity = 50 }
            assertEqual(Bills.applyCycleCompletion(bill, 2), 52, "50 + 2 = 52")
        end,
    },
    {
        name = "applyCycleCompletion handles nil produced_quantity",
        test = function()
            local bill = {}
            assertEqual(Bills.applyCycleCompletion(bill, 5), 5, "nil -> 5")
        end,
    },
    {
        name = "computeCyclesForChunk: zero elapsed returns 0",
        test = function()
            local cycles, reason = Bills.computeCyclesForChunk({
                recipeDurationSeconds = 60,
                elapsedSeconds = 0,
                maxCyclesPerChunk = 100,
                inputAvailability = { iron = 1000 },
                recipeInputs = { { item = 'iron', amount = 5 } },
                outputCapacityRemaining = 100000,
                outputWeightPerCycle = 200,
            })
            assertEqual(cycles, 0, "zero cycles")
            assertEqual(reason, nil, "no block reason for zero elapsed")
        end,
    },
    {
        name = "computeCyclesForChunk: negative elapsed returns 0",
        test = function()
            local cycles = Bills.computeCyclesForChunk({
                recipeDurationSeconds = 60,
                elapsedSeconds = -100,
                maxCyclesPerChunk = 100,
                inputAvailability = { iron = 1000 },
                recipeInputs = { { item = 'iron', amount = 5 } },
                outputCapacityRemaining = 100000,
                outputWeightPerCycle = 200,
            })
            assertEqual(cycles, 0, "zero cycles for negative elapsed")
        end,
    },
    {
        name = "computeCyclesForChunk: time-bounded cycles",
        test = function()
            local cycles = Bills.computeCyclesForChunk({
                recipeDurationSeconds = 60,
                elapsedSeconds = 300,
                maxCyclesPerChunk = 100,
                inputAvailability = { iron = 1000 },
                recipeInputs = { { item = 'iron', amount = 5 } },
                outputCapacityRemaining = 100000,
                outputWeightPerCycle = 200,
            })
            assertEqual(cycles, 5, "300/60 = 5 cycles")
        end,
    },
    {
        name = "computeCyclesForChunk: input-bounded cycles",
        test = function()
            local cycles, reason = Bills.computeCyclesForChunk({
                recipeDurationSeconds = 60,
                elapsedSeconds = 600,
                maxCyclesPerChunk = 100,
                inputAvailability = { iron = 12 },
                recipeInputs = { { item = 'iron', amount = 5 } },
                outputCapacityRemaining = 100000,
                outputWeightPerCycle = 200,
            })
            assertEqual(cycles, 2, "12/5 = 2 cycles (input-bounded)")
            assertEqual(reason, nil, "no block reason")
        end,
    },
    {
        name = "computeCyclesForChunk: insufficient inputs returns 0 with reason",
        test = function()
            local cycles, reason = Bills.computeCyclesForChunk({
                recipeDurationSeconds = 60,
                elapsedSeconds = 300,
                maxCyclesPerChunk = 100,
                inputAvailability = { iron = 0 },
                recipeInputs = { { item = 'iron', amount = 5 } },
                outputCapacityRemaining = 100000,
                outputWeightPerCycle = 200,
            })
            assertEqual(cycles, 0, "zero cycles")
            assertContains(reason, "insufficient inputs", "reason mentions inputs")
        end,
    },
    {
        name = "computeCyclesForChunk: output cap returns 0 with reason",
        test = function()
            local cycles, reason = Bills.computeCyclesForChunk({
                recipeDurationSeconds = 60,
                elapsedSeconds = 300,
                maxCyclesPerChunk = 100,
                inputAvailability = { iron = 1000 },
                recipeInputs = { { item = 'iron', amount = 5 } },
                outputCapacityRemaining = 100,
                outputWeightPerCycle = 200,
            })
            assertEqual(cycles, 0, "zero cycles")
            assertContains(reason, "output cap", "reason mentions output cap")
        end,
    },
    {
        name = "computeCyclesForChunk: maxCyclesPerChunk caps the result",
        test = function()
            local cycles = Bills.computeCyclesForChunk({
                recipeDurationSeconds = 60,
                elapsedSeconds = 600,
                maxCyclesPerChunk = 3,
                inputAvailability = { iron = 1000 },
                recipeInputs = { { item = 'iron', amount = 5 } },
                outputCapacityRemaining = 100000,
                outputWeightPerCycle = 200,
            })
            assertEqual(cycles, 3, "capped at 3")
        end,
    },
    {
        name = "computeCyclesForChunk: PRODUCE_X bill bounds cycles to target",
        test = function()
            local cycles = Bills.computeCyclesForChunk({
                recipeDurationSeconds = 60,
                elapsedSeconds = 600,
                maxCyclesPerChunk = 100,
                inputAvailability = { iron = 1000 },
                recipeInputs = { { item = 'iron', amount = 5 } },
                outputCapacityRemaining = 100000,
                outputWeightPerCycle = 200,
                bill = { mode = 'PRODUCE_X', target_quantity = 6, produced_quantity = 0 },
                batchOutputAmount = 2,
            })
            assertEqual(cycles, 3, "6/2 = 3 cycles to reach target")
        end,
    },
    {
        name = "computeCyclesForChunk: MAINTAIN_X allows overshoot by at most one batch",
        test = function()
            -- target=500, stock+reserved=495, batch=10: need 5 more, one cycle
            -- of 10 overshoots to 505 (overshoot by 5, within one batch).
            local cycles = Bills.computeCyclesForChunk({
                recipeDurationSeconds = 60,
                elapsedSeconds = 600,
                maxCyclesPerChunk = 100,
                inputAvailability = { iron = 1000 },
                recipeInputs = { { item = 'iron', amount = 5 } },
                outputCapacityRemaining = 100000,
                outputWeightPerCycle = 200,
                bill = { mode = 'MAINTAIN_X', target_quantity = 500 },
                batchOutputAmount = 10,
                stockPlusReserved = 495,
            })
            assertEqual(cycles, 1, "one cycle to overshoot target by at most one batch")
        end,
    },
    {
        name = "computeCyclesForChunk: MAINTAIN_X at target returns 0",
        test = function()
            local cycles, reason = Bills.computeCyclesForChunk({
                recipeDurationSeconds = 60,
                elapsedSeconds = 600,
                maxCyclesPerChunk = 100,
                inputAvailability = { iron = 1000 },
                recipeInputs = { { item = 'iron', amount = 5 } },
                outputCapacityRemaining = 100000,
                outputWeightPerCycle = 200,
                bill = { mode = 'MAINTAIN_X', target_quantity = 500 },
                batchOutputAmount = 10,
                stockPlusReserved = 500,
            })
            assertEqual(cycles, 0, "no cycles when target met")
            assertContains(reason, "maintain target", "reason mentions maintain target")
        end,
    },
    -- =========================================================================
    -- v0.2: priority ordering (HIGH/NORMAL/LOW)
    -- =========================================================================
    {
        name = "BillPriority exposes HIGH, NORMAL, and LOW",
        test = function()
            assertEqual(Bills.Priority.HIGH, 'HIGH', "HIGH")
            assertEqual(Bills.Priority.NORMAL, 'NORMAL', "NORMAL")
            assertEqual(Bills.Priority.LOW, 'LOW', "LOW")
        end,
    },
    {
        name = "validateBillCreation accepts HIGH priority",
        test = function()
            local ok, reason = Bills.validateBillCreation({
                mode = Bills.Mode.PRODUCE_X,
                recipeId = 'smelt_steel',
                primaryOutput = 'steel',
                targetQuantity = 100,
                batchOutputAmount = 2,
                priority = 'HIGH',
            })
            assertTrue(ok, "HIGH priority should pass")
            assertEqual(reason, nil, "no reason")
        end,
    },
    {
        name = "validateBillCreation rejects unknown priority",
        test = function()
            local ok, reason = Bills.validateBillCreation({
                mode = Bills.Mode.PRODUCE_X,
                recipeId = 'smelt_steel',
                primaryOutput = 'steel',
                targetQuantity = 100,
                batchOutputAmount = 2,
                priority = 'URGENT',
            })
            assertFalse(ok, "unknown priority should fail")
            assertContains(reason, "priority", "reason mentions priority")
        end,
    },
    {
        name = "validateBillCreation defaults priority to NORMAL when omitted",
        test = function()
            local ok = Bills.validateBillCreation({
                mode = Bills.Mode.PRODUCE_X,
                recipeId = 'smelt_steel',
                primaryOutput = 'steel',
                targetQuantity = 100,
                batchOutputAmount = 2,
            })
            assertTrue(ok, "omitted priority defaults to NORMAL and passes")
        end,
    },
    {
        name = "selectNextBill: HIGH priority preempts NORMAL (default sort map)",
        test = function()
            local bills = {
                { bill_id = 'b1', enabled = true, status = 'ACTIVE', mode = 'PRODUCE_X', priority = 'NORMAL', created_sequence = 10, target_quantity = 100, produced_quantity = 0, primary_output = 'steel' },
                { bill_id = 'b2', enabled = true, status = 'ACTIVE', mode = 'PRODUCE_X', priority = 'HIGH', created_sequence = 20, target_quantity = 100, produced_quantity = 0, primary_output = 'steel' },
            }
            local selected = Bills.selectNextBill(bills, {}, { b1 = 2, b2 = 2 })
            assertEqual(selected.bill_id, 'b2', "HIGH preempts NORMAL even though b1 was created first")
        end,
    },
    {
        name = "selectNextBill: NORMAL preempts LOW (default sort map)",
        test = function()
            local bills = {
                { bill_id = 'b1', enabled = true, status = 'ACTIVE', mode = 'PRODUCE_X', priority = 'LOW', created_sequence = 10, target_quantity = 100, produced_quantity = 0, primary_output = 'steel' },
                { bill_id = 'b2', enabled = true, status = 'ACTIVE', mode = 'PRODUCE_X', priority = 'NORMAL', created_sequence = 20, target_quantity = 100, produced_quantity = 0, primary_output = 'steel' },
            }
            local selected = Bills.selectNextBill(bills, {}, { b1 = 2, b2 = 2 })
            assertEqual(selected.bill_id, 'b2', "NORMAL preempts LOW")
        end,
    },
    {
        name = "selectNextBill: equal priority falls back to created_sequence",
        test = function()
            local bills = {
                { bill_id = 'b2', enabled = true, status = 'ACTIVE', mode = 'PRODUCE_X', priority = 'HIGH', created_sequence = 20, target_quantity = 100, produced_quantity = 0, primary_output = 'steel' },
                { bill_id = 'b1', enabled = true, status = 'ACTIVE', mode = 'PRODUCE_X', priority = 'HIGH', created_sequence = 10, target_quantity = 100, produced_quantity = 0, primary_output = 'steel' },
            }
            local selected = Bills.selectNextBill(bills, {}, { b1 = 2, b2 = 2 })
            assertEqual(selected.bill_id, 'b1', "equal priority -> earliest created_sequence")
        end,
    },
    {
        name = "selectNextBill: injected sort map overrides default order",
        test = function()
            -- Inverted sort map: LOW is highest priority.
            local sortMap = { LOW = 1, NORMAL = 2, HIGH = 3 }
            local bills = {
                { bill_id = 'b1', enabled = true, status = 'ACTIVE', mode = 'PRODUCE_X', priority = 'HIGH', created_sequence = 10, target_quantity = 100, produced_quantity = 0, primary_output = 'steel' },
                { bill_id = 'b2', enabled = true, status = 'ACTIVE', mode = 'PRODUCE_X', priority = 'LOW', created_sequence = 20, target_quantity = 100, produced_quantity = 0, primary_output = 'steel' },
            }
            local selected = Bills.selectNextBill(bills, {}, { b1 = 2, b2 = 2 }, sortMap)
            assertEqual(selected.bill_id, 'b2', "injected sort map makes LOW highest")
        end,
    },
    {
        name = "selectNextBill: unknown priority sorts last",
        test = function()
            local bills = {
                { bill_id = 'b1', enabled = true, status = 'ACTIVE', mode = 'PRODUCE_X', priority = 'WEIRD', created_sequence = 10, target_quantity = 100, produced_quantity = 0, primary_output = 'steel' },
                { bill_id = 'b2', enabled = true, status = 'ACTIVE', mode = 'PRODUCE_X', priority = 'LOW', created_sequence = 20, target_quantity = 100, produced_quantity = 0, primary_output = 'steel' },
            }
            local selected = Bills.selectNextBill(bills, {}, { b1 = 2, b2 = 2 })
            assertEqual(selected.bill_id, 'b2', "unknown priority sorts after LOW")
        end,
    },
    -- =========================================================================
    -- v0.2: UNTIL_X bill mode
    -- =========================================================================
    {
        name = "BillMode exposes UNTIL_X",
        test = function()
            assertEqual(Bills.Mode.UNTIL_X, 'UNTIL_X', "UNTIL_X mode")
        end,
    },
    {
        name = "UNTIL_X bill creation passes when threshold is a multiple of batch",
        test = function()
            local ok, reason = Bills.validateBillCreation({
                mode = Bills.Mode.UNTIL_X,
                recipeId = 'smelt_steel',
                primaryOutput = 'steel',
                targetQuantity = 20,
                batchOutputAmount = 5,
                untilThreshold = 20,
            })
            assertTrue(ok, "should pass")
            assertEqual(reason, nil, "no reason")
        end,
    },
    {
        name = "UNTIL_X bill creation fails when threshold is not a multiple of batch",
        test = function()
            local ok, reason = Bills.validateBillCreation({
                mode = Bills.Mode.UNTIL_X,
                recipeId = 'smelt_steel',
                primaryOutput = 'steel',
                targetQuantity = 21,
                batchOutputAmount = 5,
                untilThreshold = 21,
            })
            assertFalse(ok, "non-multiple threshold should fail")
            assertContains(reason, "multiple of batch", "reason mentions batch multiple")
        end,
    },
    {
        name = "UNTIL_X bill creation fails when untilThreshold is missing",
        test = function()
            local ok, reason = Bills.validateBillCreation({
                mode = Bills.Mode.UNTIL_X,
                recipeId = 'smelt_steel',
                primaryOutput = 'steel',
                targetQuantity = 20,
                batchOutputAmount = 5,
            })
            assertFalse(ok, "missing untilThreshold should fail")
            assertContains(reason, "untilThreshold", "reason mentions untilThreshold")
        end,
    },
    {
        name = "UNTIL_X bill creation fails when untilThreshold is non-positive",
        test = function()
            local ok = Bills.validateBillCreation({
                mode = Bills.Mode.UNTIL_X,
                recipeId = 'smelt_steel',
                primaryOutput = 'steel',
                targetQuantity = 20,
                batchOutputAmount = 5,
                untilThreshold = 0,
            })
            assertFalse(ok, "zero untilThreshold should fail")
        end,
    },
    {
        name = "non-UNTIL_X bill creation fails when untilThreshold is set",
        test = function()
            local ok, reason = Bills.validateBillCreation({
                mode = Bills.Mode.PRODUCE_X,
                recipeId = 'smelt_steel',
                primaryOutput = 'steel',
                targetQuantity = 20,
                batchOutputAmount = 5,
                untilThreshold = 20,
            })
            assertFalse(ok, "untilThreshold on PRODUCE_X should fail")
            assertContains(reason, "UNTIL_X", "reason mentions UNTIL_X")
        end,
    },
    {
        name = "isUntilXSatisfied: true when stock+reserved >= threshold",
        test = function()
            local bill = { until_threshold = 20 }
            assertTrue(Bills.isUntilXSatisfied(bill, 20), "at threshold")
            assertTrue(Bills.isUntilXSatisfied(bill, 25), "above threshold")
        end,
    },
    {
        name = "isUntilXSatisfied: false when stock+reserved < threshold",
        test = function()
            local bill = { until_threshold = 20 }
            assertFalse(Bills.isUntilXSatisfied(bill, 19), "below threshold")
        end,
    },
    {
        name = "shouldStartCycle: UNTIL_X starts when a full batch fits without overshoot",
        test = function()
            local bill = { mode = Bills.Mode.UNTIL_X, enabled = true, status = 'ACTIVE', until_threshold = 20 }
            -- stock=15, batch=5: 15+5=20 <= 20 -> start (lands exactly on threshold)
            assertTrue(Bills.shouldStartCycle(bill, 15, 5), "should start when batch fits exactly")
            -- stock=10, batch=5: 10+5=15 <= 20 -> start
            assertTrue(Bills.shouldStartCycle(bill, 10, 5), "should start with room to spare")
        end,
    },
    {
        name = "shouldStartCycle: UNTIL_X does not start when batch would overshoot",
        test = function()
            local bill = { mode = Bills.Mode.UNTIL_X, enabled = true, status = 'ACTIVE', until_threshold = 20 }
            -- stock=17, batch=5: 17+5=22 > 20 -> no start (no overshoot; misaligned)
            assertFalse(Bills.shouldStartCycle(bill, 17, 5), "should not start when batch would overshoot")
        end,
    },
    {
        name = "shouldStartCycle: UNTIL_X does not start when threshold already met",
        test = function()
            local bill = { mode = Bills.Mode.UNTIL_X, enabled = true, status = 'ACTIVE', until_threshold = 20 }
            assertFalse(Bills.shouldStartCycle(bill, 20, 5), "should not start at threshold")
            assertFalse(Bills.shouldStartCycle(bill, 25, 5), "should not start above threshold")
        end,
    },
    {
        name = "computeCyclesForChunk: UNTIL_X bounds to threshold without overshoot (floor)",
        test = function()
            -- threshold=20, batch=5, stock=0 -> floor(20/5)=4 cycles -> exactly 20
            local cycles = Bills.computeCyclesForChunk({
                recipeDurationSeconds = 60,
                elapsedSeconds = 600,
                maxCyclesPerChunk = 100,
                inputAvailability = { iron = 1000 },
                recipeInputs = { { item = 'iron', amount = 5 } },
                outputCapacityRemaining = 100000,
                outputWeightPerCycle = 200,
                bill = { mode = 'UNTIL_X', until_threshold = 20 },
                batchOutputAmount = 5,
                stockPlusReserved = 0,
            })
            assertEqual(cycles, 4, "4 cycles to reach exactly 20 (no overshoot)")
        end,
    },
    {
        name = "computeCyclesForChunk: UNTIL_X partial progress does not overshoot",
        test = function()
            -- threshold=20, batch=5, stock=12 -> floor((20-12)/5)=floor(1.6)=1 cycle -> 17 (no overshoot)
            local cycles = Bills.computeCyclesForChunk({
                recipeDurationSeconds = 60,
                elapsedSeconds = 600,
                maxCyclesPerChunk = 100,
                inputAvailability = { iron = 1000 },
                recipeInputs = { { item = 'iron', amount = 5 } },
                outputCapacityRemaining = 100000,
                outputWeightPerCycle = 200,
                bill = { mode = 'UNTIL_X', until_threshold = 20 },
                batchOutputAmount = 5,
                stockPlusReserved = 12,
            })
            assertEqual(cycles, 1, "1 cycle (floor, no overshoot to 17)")
        end,
    },
    {
        name = "computeCyclesForChunk: UNTIL_X at threshold returns 0",
        test = function()
            local cycles, reason = Bills.computeCyclesForChunk({
                recipeDurationSeconds = 60,
                elapsedSeconds = 600,
                maxCyclesPerChunk = 100,
                inputAvailability = { iron = 1000 },
                recipeInputs = { { item = 'iron', amount = 5 } },
                outputCapacityRemaining = 100000,
                outputWeightPerCycle = 200,
                bill = { mode = 'UNTIL_X', until_threshold = 20 },
                batchOutputAmount = 5,
                stockPlusReserved = 20,
            })
            assertEqual(cycles, 0, "no cycles when threshold met")
            assertContains(reason, "until_x", "reason mentions until_x")
        end,
    },
    {
        name = "computeCyclesForChunk: UNTIL_X never overshoots even with huge elapsed",
        test = function()
            -- threshold=20, batch=5, stock=0, but elapsed allows 100 cycles.
            -- floor(20/5)=4 -> capped at 4 (never overshoots to 25).
            local cycles = Bills.computeCyclesForChunk({
                recipeDurationSeconds = 60,
                elapsedSeconds = 6000,
                maxCyclesPerChunk = 100,
                inputAvailability = { iron = 10000 },
                recipeInputs = { { item = 'iron', amount = 5 } },
                outputCapacityRemaining = 100000,
                outputWeightPerCycle = 200,
                bill = { mode = 'UNTIL_X', until_threshold = 20 },
                batchOutputAmount = 5,
                stockPlusReserved = 0,
            })
            assertEqual(cycles, 4, "capped at 4 even with huge elapsed (no overshoot)")
        end,
    },
}
