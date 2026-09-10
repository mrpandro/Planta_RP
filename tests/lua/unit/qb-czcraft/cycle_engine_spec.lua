-- qb-czcraft cycle engine orchestration tests
-- Tests the processMachine orchestrator (server/cycle_engine.lua) with mock
-- repositories and stubbed FiveM globals. The pure domain modules (bills,
-- production, catch-up, storage, recipe_snapshot) are loaded for real; only
-- the repo/adapter/scheduler layers and FiveM globals are mocked.
--
-- Covers:
--   Mode 1: complete a due active cycle + start the next real-time cycle
--   Mode 1: active cycle not yet due -> re-heap, no completion
--   Mode 2: catch-up to completion -> idle (PRODUCE_X target met)
--   Mode 2: catch-up blocked on insufficient inputs
--   Mode 2: no runnable bill -> clearNextDue (idle)

-- ---------------------------------------------------------------------------
-- Stub FiveM globals that don't exist under stock Lua 5.4.
-- ---------------------------------------------------------------------------
CreateThread = function(fn) fn() end  -- run synchronously in tests
Wait = function() end
RegisterNetEvent = function() end
AddEventHandler = function() end
json = json or {
    encode = function(t)
        if type(t) ~= 'table' then return 'null' end
        local parts = {}
        for k, v in pairs(t) do
            local val
            if type(v) == 'string' then val = '"' .. v .. '"'
            elseif type(v) == 'number' then val = tostring(v)
            elseif type(v) == 'boolean' then val = v and 'true' or 'false'
            else val = 'null' end
            parts[#parts + 1] = '"' .. tostring(k) .. '":' .. val
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end,
    decode = function() return {} end,
}

-- Fixed clock so tests are deterministic.
local FIXED_NOW = 1000000
os.time = function() return FIXED_NOW end

-- ---------------------------------------------------------------------------
-- Load real shared/config/domain modules (these set up the CZCraft global).
-- ---------------------------------------------------------------------------
dofile("resources/[meus-scripts]/qb-czcraft/shared/constants.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/general.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/machines.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/recipes.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/balance.lua")
dofile("resources/[meus-scripts]/qb-czcraft/shared/recipe_snapshot.lua")
dofile("resources/[meus-scripts]/qb-czcraft/server/domain/bills.lua")
dofile("resources/[meus-scripts]/qb-czcraft/server/domain/production.lua")
dofile("resources/[meus-scripts]/qb-czcraft/server/domain/power.lua")
dofile("resources/[meus-scripts]/qb-czcraft/server/domain/condition.lua")
dofile("resources/[meus-scripts]/qb-czcraft/server/domain/upgrades.lua")
dofile("resources/[meus-scripts]/qb-czcraft/server/domain/catchup.lua")
dofile("resources/[meus-scripts]/qb-czcraft/server/domain/storage.lua")

CZCraft.Runtime = { isReady = true }

-- Mock QBCore adapter: returns a minimal item registry with weights.
CZCraft.QBCoreAdapter = {
    getItems = function()
        return {
            iron = { weight = 100 }, steel = { weight = 100 },
            metalscrap = { weight = 50 },
            cz_metal_parts = { weight = 200 }, cz_electronics = { weight = 150 },
            cz_mechanical_parts = { weight = 200 }, cz_components = { weight = 300 },
            repairkit = { weight = 500 },
        }
    end,
}

-- ---------------------------------------------------------------------------
-- Mock repo layer (in-memory state that mutates so the catch-up loop progresses).
-- ---------------------------------------------------------------------------
local function makeMockRepos()
    local state = {
        machine = nil,       -- single machine row
        activeCycle = nil,   -- single active cycle or nil
        stock = {},          -- { [item_name] = { quantity, reserved_quantity } }
        bills = {},          -- { [bill_id] = bill row }
        events = {},         -- production events inserted
        calls = {},          -- call log: { name, args }
        nextSeq = 1,
    }

    local function log(name, args) state.calls[#state.calls + 1] = { name = name, args = args } end

    local MachinesRepo = {
        load = function(uuid)
            if state.machine and state.machine.machine_uuid == uuid then
                -- Return a shallow copy so callers see a stable snapshot.
                local copy = {}
                for k, v in pairs(state.machine) do copy[k] = v end
                return copy
            end
            return nil
        end,
        setBlocked = function(uuid, reason, detail, version)
            log('setBlocked', { uuid = uuid, reason = reason })
            state.machine.operational_status = 'BLOCKED'
            state.machine.blocked_reason = reason
            state.machine.next_due_at = nil
            state.machine.version = (state.machine.version or 0) + 1
            return true
        end,
        clearNextDue = function(uuid, version)
            log('clearNextDue', { uuid = uuid })
            state.machine.next_due_at = nil
            state.machine.operational_status = 'STOPPED'
            state.machine.blocked_reason = nil
            state.machine.version = (state.machine.version or 0) + 1
            return true
        end,
    }

    local CyclesRepo = {
        loadActive = function(uuid)
            log('loadActive', { uuid = uuid })
            return state.activeCycle and copyRow(state.activeCycle) or nil
        end,
        complete = function(params)
            log('complete', { cycle_id = params.cycle_id, idempotency_key = params.idempotency_key })
            -- Apply completion deltas: reserved -> actual.
            for _, delta in ipairs(params.completion_deltas or {}) do
                local row = state.stock[delta.item_name] or { quantity = 0, reserved_quantity = 0 }
                row.quantity = row.quantity + (delta.quantity_delta or 0)
                row.reserved_quantity = math.max(0, row.reserved_quantity + (delta.reserved_delta or 0))
                state.stock[delta.item_name] = row
            end
            -- Power was consumed at START, not here.
            state.activeCycle = nil
            state.machine.operational_status = 'STOPPED'
            state.machine.active_cycle_id = nil
            state.machine.version = (state.machine.version or 0) + 1
            return true, nil
        end,
        start = function(params)
            log('start', { cycle_id = params.cycle_id, recipe_id = params.recipe_id, bill_id = params.bill_id })
            -- Apply start deltas: inputs consumed, outputs reserved.
            for _, delta in ipairs(params.stock_deltas or {}) do
                local row = state.stock[delta.item_name] or { quantity = 0, reserved_quantity = 0 }
                row.quantity = math.max(0, row.quantity + (delta.quantity_delta or 0))
                row.reserved_quantity = math.max(0, row.reserved_quantity + (delta.reserved_delta or 0))
                state.stock[delta.item_name] = row
            end
            -- Power is consumed at START (invariant: energy consumed at cycle
            -- start, same transaction as inputs).
            if params.power_to_consume and params.power_to_consume > 0 then
                state.machine.power_level = math.max(0, (state.machine.power_level or 0) - params.power_to_consume)
            end
            -- Condition wear is applied at START (same invariant).
            if params.wear_to_apply and params.wear_to_apply > 0 then
                state.machine.condition = math.max(0, (state.machine.condition or 0) - params.wear_to_apply)
            end
            state.activeCycle = {
                cycle_id = params.cycle_id,
                cycle_sequence = params.cycle_sequence,
                machine_uuid = params.machine_uuid,
                bill_id = params.bill_id,
                recipe_id = params.recipe_id,
                started_at = os.date('!%Y-%m-%d %H:%M:%S.000', params.started_at),
                due_at = os.date('!%Y-%m-%d %H:%M:%S.000', params.started_at + params.duration_seconds),
                duration_seconds = params.duration_seconds,
                power_level_before = params.power_level_before,
                power_level_after = params.power_level_after,
                power_to_consume = params.power_to_consume,
                condition_before = params.condition_before,
                condition_after = params.condition_after,
                wear_to_apply = params.wear_to_apply,
            }
            state.machine.operational_status = 'RUNNING'
            state.machine.active_cycle_id = params.cycle_id
            state.machine.next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', params.started_at + params.duration_seconds)
            state.machine.version = (state.machine.version or 0) + 1
            return true, nil
        end,
        deleteActive = function(uuid, cycleId)
            state.activeCycle = nil
            return true
        end,
        nextSequence = function()
            state.nextSeq = state.nextSeq + 1
            return state.nextSeq
        end,
        applyCatchUpChunk = function(params)
            log('applyCatchUpChunk', { cycles = params.cycles_to_run, idempotency_key = params.idempotency_key })
            -- Apply net deltas: inputs consumed, outputs produced.
            local recipe = params.recipe
            for _, line in ipairs(recipe.inputs or {}) do
                local row = state.stock[line.item] or { quantity = 0, reserved_quantity = 0 }
                row.quantity = math.max(0, row.quantity - (line.amount * params.cycles_to_run))
                state.stock[line.item] = row
            end
            for _, line in ipairs(recipe.outputs or {}) do
                local row = state.stock[line.item] or { quantity = 0, reserved_quantity = 0 }
                row.quantity = row.quantity + (line.amount * params.cycles_to_run)
                state.stock[line.item] = row
            end
            state.machine.next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', params.next_due_at)
            state.machine.operational_status = 'STOPPED'
            state.machine.active_cycle_id = nil
            -- Apply power consumption for the chunk.
            if params.power_to_consume and params.power_to_consume > 0 then
                state.machine.power_level = math.max(0, (state.machine.power_level or 0) - params.power_to_consume)
            end
            -- Apply condition wear for the chunk.
            if params.wear_to_apply and params.wear_to_apply > 0 then
                state.machine.condition = math.max(0, (state.machine.condition or 0) - params.wear_to_apply)
            end
            state.machine.version = (state.machine.version or 0) + 1
            state.events[#state.events + 1] = { cycles = params.cycles_to_run, key = params.idempotency_key }
            return true, nil
        end,
    }

    local BillsRepo = {
        listActiveForMachine = function(uuid)
            local list = {}
            for _, bill in pairs(state.bills) do
                list[#list + 1] = bill
            end
            table.sort(list, function(a, b) return (a.created_sequence or 0) < (b.created_sequence or 0) end)
            return list
        end,
        load = function(billId) return state.bills[billId] and copyRow(state.bills[billId]) or nil end,
        incrementProduced = function(billId, version, amount, mode, target)
            log('incrementProduced', { bill_id = billId, amount = amount })
            local bill = state.bills[billId]
            if not bill then return false, 'not found' end
            bill.produced_quantity = (bill.produced_quantity or 0) + amount
            if mode == 'PRODUCE_X' and bill.produced_quantity >= target then
                bill.status = 'COMPLETED'
            end
            bill.version = (bill.version or 0) + 1
            return true, nil
        end,
    }

    local StockRepo = {
        loadAll = function(uuid)
            local rows = {}
            for item, row in pairs(state.stock) do
                rows[#rows + 1] = { item_name = item, quantity = row.quantity, reserved_quantity = row.reserved_quantity }
            end
            return rows
        end,
    }

    local wakeLog = {}
    local SchedulerTick = {
        wake = function(uuid, dueAt) wakeLog[#wakeLog + 1] = { uuid = uuid, dueAt = dueAt } end,
    }

    return state, MachinesRepo, CyclesRepo, BillsRepo, StockRepo, SchedulerTick, wakeLog
end

-- Shallow copy helper for rows.
function copyRow(row)
    local copy = {}
    for k, v in pairs(row) do copy[k] = v end
    return copy
end

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------
local failures = 0
local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "Assertion failed") .. " | expected=" .. tostring(expected) .. ", actual=" .. tostring(actual))
    end
end
local function assertTrue(value, message)
    if not value then error(message or "Expected truthy") end
end
local function assertFalse(value, message)
    if value then error(message or "Expected falsy") end
end
local function assertContains(haystack, needle, message)
    if type(haystack) ~= 'string' or string.find(haystack, needle, 1, true) == nil then
        error((message or "Expected string to contain needle") .. " | needle=" .. tostring(needle))
    end
end
local function countCalls(state, name)
    local n = 0
    for _, c in ipairs(state.calls) do
        if c.name == name then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Load the cycle engine with mocked dependencies.
-- ---------------------------------------------------------------------------
local function loadEngine(state, MachinesRepo, CyclesRepo, BillsRepo, StockRepo, SchedulerTick)
    CZCraft.MachinesRepo = MachinesRepo
    CZCraft.CyclesRepo = CyclesRepo
    CZCraft.BillsRepo = BillsRepo
    CZCraft.StockRepo = StockRepo
    CZCraft.SchedulerTick = SchedulerTick
    -- Reload the engine so it captures the mocked CZCraft.* references.
    package.loaded = package.loaded or {}
    local engine = dofile("resources/[meus-scripts]/qb-czcraft/server/cycle_engine.lua")
    return engine
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------
return {
    {
        name = "Mode 1: due active cycle is completed and next cycle started",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            state.machine = {
                machine_uuid = 'm1', machine_type = 'refinery', lifecycle = 'INSTALLED',
                operational_status = 'RUNNING', version = 1,
                next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 100),
            }
            state.activeCycle = {
                cycle_id = 'c1', cycle_sequence = 1, machine_uuid = 'm1',
                bill_id = 'b1', recipe_id = 'smelt_steel',
                started_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 160),
                due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 100),
                duration_seconds = 60,
            }
            state.stock = {
                iron = { quantity = 100, reserved_quantity = 0 },
                metalscrap = { quantity = 50, reserved_quantity = 0 },
                steel = { quantity = 0, reserved_quantity = 2 },  -- reserved from the in-flight cycle
            }
            state.bills = {
                b1 = {
                    bill_id = 'b1', machine_uuid = 'm1', recipe_id = 'smelt_steel',
                    mode = 'PRODUCE_X', primary_output = 'steel',
                    target_quantity = 100, produced_quantity = 0,
                    enabled = true, status = 'ACTIVE', priority = 'NORMAL',
                    created_sequence = 1, version = 1,
                },
            }
            local engine = loadEngine(state, MR, CR, BR, SR, ST)
            engine.processMachine('m1')

            -- Cycle completed.
            assertTrue(countCalls(state, 'complete') == 1, "complete called once")
            -- Bill incremented.
            assertTrue(countCalls(state, 'incrementProduced') >= 1, "bill incremented")
            -- Next cycle started.
            assertTrue(countCalls(state, 'start') == 1, "start called for next cycle")
            -- Steel reserved was converted to actual on completion.
            assertEqual(state.stock.steel.quantity, 2, "steel produced from completed cycle")
        end,
    },
    {
        name = "Mode 1: active cycle not yet due -> re-heap, no completion",
        test = function()
            local state, MR, CR, BR, SR, ST, wakeLog = makeMockRepos()
            state.machine = {
                machine_uuid = 'm2', machine_type = 'refinery', lifecycle = 'INSTALLED',
                operational_status = 'RUNNING', version = 1,
                next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW + 500),
            }
            state.activeCycle = {
                cycle_id = 'c2', cycle_sequence = 2, machine_uuid = 'm2',
                bill_id = nil, recipe_id = 'smelt_steel',
                started_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 100),
                due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW + 500),
                duration_seconds = 60,
            }
            local engine = loadEngine(state, MR, CR, BR, SR, ST)
            engine.processMachine('m2')

            assertEqual(countCalls(state, 'complete'), 0, "no completion (not due)")
            assertTrue(#wakeLog == 1, "re-heaped once")
            assertTrue(wakeLog[1].dueAt == FIXED_NOW + 500, "re-heaped with the cycle due time")
        end,
    },
    {
        name = "Mode 2: catch-up to completion then idle (PRODUCE_X target met)",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            -- Machine stopped 600s ago (10 cycles of 60s), with a PRODUCE_X
            -- target of 20 steel (batch=2 -> 10 cycles).
            state.machine = {
                machine_uuid = 'm3', machine_type = 'refinery', lifecycle = 'INSTALLED',
                operational_status = 'STOPPED', version = 1,
                next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 600),
            }
            state.stock = {
                iron = { quantity = 1000, reserved_quantity = 0 },
                metalscrap = { quantity = 500, reserved_quantity = 0 },
                steel = { quantity = 0, reserved_quantity = 0 },
            }
            state.bills = {
                b3 = {
                    bill_id = 'b3', machine_uuid = 'm3', recipe_id = 'smelt_steel',
                    mode = 'PRODUCE_X', primary_output = 'steel',
                    target_quantity = 20, produced_quantity = 0,
                    enabled = true, status = 'ACTIVE', priority = 'NORMAL',
                    created_sequence = 1, version = 1,
                },
            }
            local engine = loadEngine(state, MR, CR, BR, SR, ST)
            engine.processMachine('m3')

            -- Catch-up ran chunks (applyCatchUpChunk called).
            local chunks = countCalls(state, 'applyCatchUpChunk')
            assertTrue(chunks >= 1, "at least one catch-up chunk applied")
            -- Bill produced_quantity reached target (20).
            assertEqual(state.bills.b3.produced_quantity, 20, "PRODUCE_X target met")
            assertEqual(state.bills.b3.status, 'COMPLETED', "bill marked COMPLETED")
            -- Steel produced: 10 cycles * 2 = 20.
            assertEqual(state.stock.steel.quantity, 20, "20 steel produced")
            -- Iron consumed: 10 cycles * 5 = 50.
            assertEqual(state.stock.iron.quantity, 950, "50 iron consumed")
            -- After catch-up, the bill is complete -> no next cycle -> idle (clearNextDue).
            assertTrue(countCalls(state, 'clearNextDue') >= 1, "machine goes idle after bill completes")
        end,
    },
    {
        name = "Mode 2: catch-up blocked on insufficient inputs",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            state.machine = {
                machine_uuid = 'm4', machine_type = 'refinery', lifecycle = 'INSTALLED',
                operational_status = 'STOPPED', version = 1,
                next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 600),
            }
            -- No iron at all -> immediate block.
            state.stock = {
                iron = { quantity = 0, reserved_quantity = 0 },
                metalscrap = { quantity = 0, reserved_quantity = 0 },
            }
            state.bills = {
                b4 = {
                    bill_id = 'b4', machine_uuid = 'm4', recipe_id = 'smelt_steel',
                    mode = 'MAINTAIN_X', primary_output = 'steel',
                    target_quantity = 20, produced_quantity = 0,
                    enabled = true, status = 'ACTIVE', priority = 'NORMAL',
                    created_sequence = 1, version = 1,
                },
            }
            local engine = loadEngine(state, MR, CR, BR, SR, ST)
            engine.processMachine('m4')

            assertTrue(countCalls(state, 'applyCatchUpChunk') == 0, "no chunks applied (blocked)")
            assertTrue(countCalls(state, 'setBlocked') >= 1, "machine set blocked")
            local blockCall = nil
            for _, c in ipairs(state.calls) do
                if c.name == 'setBlocked' then blockCall = c break end
            end
            assertContains(blockCall.args.reason, 'insufficient', "block reason mentions inputs")
        end,
    },
    {
        name = "Mode 2: no runnable bill -> clearNextDue (idle)",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            state.machine = {
                machine_uuid = 'm5', machine_type = 'refinery', lifecycle = 'INSTALLED',
                operational_status = 'STOPPED', version = 1,
                next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 600),
            }
            state.stock = {
                iron = { quantity = 1000, reserved_quantity = 0 },
            }
            -- No bills at all.
            state.bills = {}
            local engine = loadEngine(state, MR, CR, BR, SR, ST)
            engine.processMachine('m5')

            assertEqual(countCalls(state, 'applyCatchUpChunk'), 0, "no chunks (no bill)")
            assertTrue(countCalls(state, 'clearNextDue') >= 1, "machine goes idle")
        end,
    },
    -- =========================================================================
    -- v0.2: power gating and consumption
    -- =========================================================================
    {
        name = "Power: Mode 1 completion does NOT consume power (already consumed at start)",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            -- Power was already consumed at START: 100 - 5 = 95. The machine
            -- is at 95 while the cycle is active.
            state.machine = {
                machine_uuid = 'p1', machine_type = 'refinery', lifecycle = 'INSTALLED',
                operational_status = 'RUNNING', version = 1, power_level = 95,
                next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 100),
            }
            state.activeCycle = {
                cycle_id = 'pc1', cycle_sequence = 1, machine_uuid = 'p1',
                bill_id = 'pb1', recipe_id = 'smelt_steel',
                started_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 160),
                due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 100),
                duration_seconds = 60,
                power_level_before = 100, power_level_after = 95, power_to_consume = 5,
            }
            state.stock = {
                iron = { quantity = 100, reserved_quantity = 0 },
                metalscrap = { quantity = 50, reserved_quantity = 0 },
                steel = { quantity = 0, reserved_quantity = 2 },
            }
            state.bills = {
                pb1 = {
                    bill_id = 'pb1', machine_uuid = 'p1', recipe_id = 'smelt_steel',
                    mode = 'PRODUCE_X', primary_output = 'steel',
                    target_quantity = 100, produced_quantity = 0,
                    enabled = true, status = 'ACTIVE', priority = 'NORMAL',
                    created_sequence = 1, version = 1,
                },
            }
            local engine = loadEngine(state, MR, CR, BR, SR, ST)
            engine.processMachine('p1')

            -- Completion does NOT touch power (stays 95). The next cycle
            -- start consumes 5 more: 95 - 5 = 90.
            assertEqual(state.machine.power_level, 90, "power consumed at next start (95 -> 90), not at completion")
            assertTrue(countCalls(state, 'start') == 1, "next cycle started")
        end,
    },
    {
        name = "Power: low power blocks new cycle start after completion",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            -- Power was already consumed at START: 6 - 5 = 1. The machine
            -- is at 1 while the cycle is active (below blockThreshold 5).
            state.machine = {
                machine_uuid = 'p2', machine_type = 'refinery', lifecycle = 'INSTALLED',
                operational_status = 'RUNNING', version = 1, power_level = 1,
                next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 100),
            }
            state.activeCycle = {
                cycle_id = 'pc2', cycle_sequence = 2, machine_uuid = 'p2',
                bill_id = 'pb2', recipe_id = 'smelt_steel',
                started_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 160),
                due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 100),
                duration_seconds = 60,
                power_level_before = 6, power_level_after = 1, power_to_consume = 5,
            }
            state.stock = {
                iron = { quantity = 100, reserved_quantity = 0 },
                metalscrap = { quantity = 50, reserved_quantity = 0 },
                steel = { quantity = 0, reserved_quantity = 2 },
            }
            state.bills = {
                pb2 = {
                    bill_id = 'pb2', machine_uuid = 'p2', recipe_id = 'smelt_steel',
                    mode = 'PRODUCE_X', primary_output = 'steel',
                    target_quantity = 100, produced_quantity = 0,
                    enabled = true, status = 'ACTIVE', priority = 'NORMAL',
                    created_sequence = 1, version = 1,
                },
            }
            local engine = loadEngine(state, MR, CR, BR, SR, ST)
            engine.processMachine('p2')

            -- Completion does NOT touch power (stays 1). Next cycle start
            -- is blocked (1 < blockThreshold 5).
            assertEqual(state.machine.power_level, 1, "power unchanged by completion (stays 1)")
            assertEqual(countCalls(state, 'start'), 0, "no next cycle (power blocked)")
            assertTrue(countCalls(state, 'setBlocked') >= 1, "machine set blocked")
            local blockCall = nil
            for _, c in ipairs(state.calls) do
                if c.name == 'setBlocked' then blockCall = c break end
            end
            assertContains(blockCall.args.reason, 'power', "block reason mentions power")
        end,
    },
    {
        name = "Power: Mode 2 catch-up consumes power per cycle",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            state.machine = {
                machine_uuid = 'p3', machine_type = 'refinery', lifecycle = 'INSTALLED',
                operational_status = 'STOPPED', version = 1, power_level = 100,
                next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 600),
            }
            state.stock = {
                iron = { quantity = 1000, reserved_quantity = 0 },
                metalscrap = { quantity = 500, reserved_quantity = 0 },
                steel = { quantity = 0, reserved_quantity = 0 },
            }
            state.bills = {
                pb3 = {
                    bill_id = 'pb3', machine_uuid = 'p3', recipe_id = 'smelt_steel',
                    mode = 'PRODUCE_X', primary_output = 'steel',
                    target_quantity = 20, produced_quantity = 0,
                    enabled = true, status = 'ACTIVE', priority = 'NORMAL',
                    created_sequence = 1, version = 1,
                },
            }
            local engine = loadEngine(state, MR, CR, BR, SR, ST)
            engine.processMachine('p3')

            -- 10 cycles * 5 power = 50 consumed. 100 - 50 = 50.
            assertEqual(state.machine.power_level, 50, "10 cycles consumed 50 power (100 -> 50)")
        end,
    },
    {
        name = "Power: Mode 2 catch-up bounded by available power",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            -- Only 12 power -> floor(12/5) = 2 cycles max (10s elapsed allows 10).
            state.machine = {
                machine_uuid = 'p4', machine_type = 'refinery', lifecycle = 'INSTALLED',
                operational_status = 'STOPPED', version = 1, power_level = 12,
                next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 600),
            }
            state.stock = {
                iron = { quantity = 1000, reserved_quantity = 0 },
                metalscrap = { quantity = 500, reserved_quantity = 0 },
                steel = { quantity = 0, reserved_quantity = 0 },
            }
            state.bills = {
                pb4 = {
                    bill_id = 'pb4', machine_uuid = 'p4', recipe_id = 'smelt_steel',
                    mode = 'MAINTAIN_X', primary_output = 'steel',
                    target_quantity = 100, produced_quantity = 0,
                    enabled = true, status = 'ACTIVE', priority = 'NORMAL',
                    created_sequence = 1, version = 1,
                },
            }
            local engine = loadEngine(state, MR, CR, BR, SR, ST)
            engine.processMachine('p4')

            -- Only 2 cycles ran (12 power / 5 per cycle = 2.4 -> floor 2).
            -- Power after: 12 - (2 * 5) = 2.
            assertEqual(state.machine.power_level, 2, "2 cycles consumed 10 power (12 -> 2)")
            -- Steel produced: 2 cycles * 2 = 4.
            assertEqual(state.stock.steel.quantity, 4, "only 4 steel produced (power-bounded)")
        end,
    },
    {
        name = "Power: catch-up blocked when power below threshold",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            -- Power = 3 (below blockThreshold 5) -> no catch-up cycles.
            state.machine = {
                machine_uuid = 'p5', machine_type = 'refinery', lifecycle = 'INSTALLED',
                operational_status = 'STOPPED', version = 1, power_level = 3,
                next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 600),
            }
            state.stock = {
                iron = { quantity = 1000, reserved_quantity = 0 },
                metalscrap = { quantity = 500, reserved_quantity = 0 },
            }
            state.bills = {
                pb5 = {
                    bill_id = 'pb5', machine_uuid = 'p5', recipe_id = 'smelt_steel',
                    mode = 'MAINTAIN_X', primary_output = 'steel',
                    target_quantity = 100, produced_quantity = 0,
                    enabled = true, status = 'ACTIVE', priority = 'NORMAL',
                    created_sequence = 1, version = 1,
                },
            }
            local engine = loadEngine(state, MR, CR, BR, SR, ST)
            engine.processMachine('p5')

            assertEqual(countCalls(state, 'applyCatchUpChunk'), 0, "no chunks (power blocked)")
            assertTrue(countCalls(state, 'setBlocked') >= 1, "machine set blocked")
            local blockCall = nil
            for _, c in ipairs(state.calls) do
                if c.name == 'setBlocked' then blockCall = c break end
            end
            assertContains(blockCall.args.reason, 'power', "block reason mentions power")
        end,
    },
    {
        name = "Power: no power_level (nil) skips power gate (backward compat)",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            -- No power_level on the machine (schema v1 / old test mocks).
            state.machine = {
                machine_uuid = 'p6', machine_type = 'refinery', lifecycle = 'INSTALLED',
                operational_status = 'STOPPED', version = 1,
                next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 600),
            }
            state.stock = {
                iron = { quantity = 1000, reserved_quantity = 0 },
                metalscrap = { quantity = 500, reserved_quantity = 0 },
                steel = { quantity = 0, reserved_quantity = 0 },
            }
            state.bills = {
                pb6 = {
                    bill_id = 'pb6', machine_uuid = 'p6', recipe_id = 'smelt_steel',
                    mode = 'PRODUCE_X', primary_output = 'steel',
                    target_quantity = 20, produced_quantity = 0,
                    enabled = true, status = 'ACTIVE', priority = 'NORMAL',
                    created_sequence = 1, version = 1,
                },
            }
            local engine = loadEngine(state, MR, CR, BR, SR, ST)
            engine.processMachine('p6')

            -- Catch-up runs normally (no power gating when power_level is nil).
            assertTrue(countCalls(state, 'applyCatchUpChunk') >= 1, "catch-up runs without power_level")
            -- No power-related block.
            local hasPowerBlock = false
            for _, c in ipairs(state.calls) do
                if c.name == 'setBlocked' and string.find(c.args.reason, 'power', 1, true) then
                    hasPowerBlock = true
                    break
                end
            end
            assertFalse(hasPowerBlock, "no power block when power_level is nil")
        end,
    },

    -- =========================================================================
    -- v0.2: condition gating and wear
    -- =========================================================================
    {
        name = "Condition: catch-up + real-time start applies wear (100 -> 99.0)",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            state.machine = {
                machine_uuid = 'c1', machine_type = 'refinery', lifecycle = 'INSTALLED',
                operational_status = 'STOPPED', version = 1, power_level = 100,
                condition = 100,
                next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 100),
            }
            state.stock = {
                iron = { quantity = 100, reserved_quantity = 0 },
                metalscrap = { quantity = 50, reserved_quantity = 0 },
            }
            state.bills = {
                cb1 = {
                    bill_id = 'cb1', machine_uuid = 'c1', recipe_id = 'smelt_steel',
                    mode = 'PRODUCE_X', primary_output = 'steel',
                    target_quantity = 100, produced_quantity = 0,
                    enabled = true, status = 'ACTIVE', priority = 'NORMAL',
                    created_sequence = 1, version = 1,
                },
            }
            local engine = loadEngine(state, MR, CR, BR, SR, ST)
            engine.processMachine('c1')

            -- Catch-up runs 1 cycle (100s / 60s = 1), applying 0.5 wear.
            -- Then a real-time cycle starts, applying another 0.5 wear.
            -- Total: 100 - 1.0 = 99.0. Wear is applied at START, not completion.
            assertEqual(state.machine.condition, 99.0, "wear applied at start (catch-up + real-time = 100 -> 99.0)")
            assertTrue(countCalls(state, 'start') == 1, "real-time cycle started")
        end,
    },
    {
        name = "Condition: low condition blocks new cycle start",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            state.machine = {
                machine_uuid = 'c2', machine_type = 'refinery', lifecycle = 'INSTALLED',
                operational_status = 'STOPPED', version = 1, power_level = 100,
                condition = 20, -- at block threshold
                next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 100),
            }
            state.stock = {
                iron = { quantity = 100, reserved_quantity = 0 },
                metalscrap = { quantity = 50, reserved_quantity = 0 },
            }
            state.bills = {
                cb2 = {
                    bill_id = 'cb2', machine_uuid = 'c2', recipe_id = 'smelt_steel',
                    mode = 'PRODUCE_X', primary_output = 'steel',
                    target_quantity = 100, produced_quantity = 0,
                    enabled = true, status = 'ACTIVE', priority = 'NORMAL',
                    created_sequence = 1, version = 1,
                },
            }
            local engine = loadEngine(state, MR, CR, BR, SR, ST)
            engine.processMachine('c2')

            -- No cycle started (condition at block threshold).
            assertEqual(countCalls(state, 'start'), 0, "no cycle (condition blocked)")
            assertTrue(countCalls(state, 'setBlocked') >= 1, "machine set blocked")
            local blockCall = nil
            for _, c in ipairs(state.calls) do
                if c.name == 'setBlocked' then blockCall = c break end
            end
            assertContains(blockCall.args.reason, 'condition', "block reason mentions condition")
            -- Condition unchanged (no wear applied).
            assertEqual(state.machine.condition, 20, "condition unchanged (no wear)")
        end,
    },
    {
        name = "Condition: Mode 2 catch-up applies wear per cycle",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            state.machine = {
                machine_uuid = 'c3', machine_type = 'refinery', lifecycle = 'INSTALLED',
                operational_status = 'STOPPED', version = 1, power_level = 100,
                condition = 100,
                next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 600),
            }
            state.stock = {
                iron = { quantity = 1000, reserved_quantity = 0 },
                metalscrap = { quantity = 500, reserved_quantity = 0 },
                steel = { quantity = 0, reserved_quantity = 0 },
            }
            state.bills = {
                cb3 = {
                    bill_id = 'cb3', machine_uuid = 'c3', recipe_id = 'smelt_steel',
                    mode = 'PRODUCE_X', primary_output = 'steel',
                    target_quantity = 20, produced_quantity = 0,
                    enabled = true, status = 'ACTIVE', priority = 'NORMAL',
                    created_sequence = 1, version = 1,
                },
            }
            local engine = loadEngine(state, MR, CR, BR, SR, ST)
            engine.processMachine('c3')

            -- 10 cycles * 0.5 wear = 5. 100 - 5 = 95.
            assertEqual(state.machine.condition, 95, "10 cycles consumed 5 condition (100 -> 95)")
        end,
    },
    {
        name = "Condition: catch-up bounded by available condition",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            -- Condition at 25, blockThreshold 20. Available: (25 - 20) / 0.5 = 10 cycles.
            state.machine = {
                machine_uuid = 'c4', machine_type = 'refinery', lifecycle = 'INSTALLED',
                operational_status = 'STOPPED', version = 1, power_level = 100,
                condition = 25,
                next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 6000),
            }
            -- Keep stock within the refinery's 250kg capacity. Iron at 100g/ea:
            -- 200 iron = 20kg, 100 metalscrap = 5kg. Total 25kg << 250kg.
            state.stock = {
                iron = { quantity = 200, reserved_quantity = 0 },
                metalscrap = { quantity = 100, reserved_quantity = 0 },
                steel = { quantity = 0, reserved_quantity = 0 },
            }
            state.bills = {
                cb4 = {
                    bill_id = 'cb4', machine_uuid = 'c4', recipe_id = 'smelt_steel',
                    mode = 'PRODUCE_X', primary_output = 'steel',
                    target_quantity = 200, produced_quantity = 0,
                    enabled = true, status = 'ACTIVE', priority = 'NORMAL',
                    created_sequence = 1, version = 1,
                },
            }
            local engine = loadEngine(state, MR, CR, BR, SR, ST)
            engine.processMachine('c4')

            -- Only 10 cycles of wear before hitting block threshold.
            -- 25 - (10 * 0.5) = 20 (at block threshold).
            assertEqual(state.machine.condition, 20, "condition bounded at block threshold (25 -> 20)")
            -- The machine should be blocked after catch-up (condition low).
            local hasConditionBlock = false
            for _, c in ipairs(state.calls) do
                if c.name == 'setBlocked' and string.find(c.args.reason, 'condition', 1, true) then
                    hasConditionBlock = true
                    break
                end
            end
            assertTrue(hasConditionBlock, "machine blocked on condition after catch-up")
        end,
    },
    {
        name = "Condition: nil condition skips condition gate (schema v1 compat)",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            state.machine = {
                machine_uuid = 'c5', machine_type = 'refinery', lifecycle = 'INSTALLED',
                operational_status = 'STOPPED', version = 1, power_level = 100,
                -- No condition field (schema v1 / test mock).
                next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 100),
            }
            state.stock = {
                iron = { quantity = 100, reserved_quantity = 0 },
                metalscrap = { quantity = 50, reserved_quantity = 0 },
            }
            state.bills = {
                cb5 = {
                    bill_id = 'cb5', machine_uuid = 'c5', recipe_id = 'smelt_steel',
                    mode = 'PRODUCE_X', primary_output = 'steel',
                    target_quantity = 100, produced_quantity = 0,
                    enabled = true, status = 'ACTIVE', priority = 'NORMAL',
                    created_sequence = 1, version = 1,
                },
            }
            local engine = loadEngine(state, MR, CR, BR, SR, ST)
            engine.processMachine('c5')

            -- Cycle starts normally (no condition gating when condition is nil).
            assertTrue(countCalls(state, 'start') == 1, "cycle starts without condition")
            local hasConditionBlock = false
            for _, c in ipairs(state.calls) do
                if c.name == 'setBlocked' and string.find(c.args.reason, 'condition', 1, true) then
                    hasConditionBlock = true
                    break
                end
            end
            assertFalse(hasConditionBlock, "no condition block when condition is nil")
        end,
    },
}
