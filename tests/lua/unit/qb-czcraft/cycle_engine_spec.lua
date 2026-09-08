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
dofile("resources/[meus-scripts]/qb-czcraft/shared/recipe_snapshot.lua")
dofile("resources/[meus-scripts]/qb-czcraft/server/domain/bills.lua")
dofile("resources/[meus-scripts]/qb-czcraft/server/domain/production.lua")
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
            state.activeCycle = {
                cycle_id = params.cycle_id,
                cycle_sequence = params.cycle_sequence,
                machine_uuid = params.machine_uuid,
                bill_id = params.bill_id,
                recipe_id = params.recipe_id,
                started_at = os.date('!%Y-%m-%d %H:%M:%S.000', params.started_at),
                due_at = os.date('!%Y-%m-%d %H:%M:%S.000', params.started_at + params.duration_seconds),
                duration_seconds = params.duration_seconds,
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
}
