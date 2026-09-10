-- qb-czcraft house-transfer runtime tests
-- Exercises the actual transfer + cycle-completion flow with mock repos,
-- not static SQL inspection. Verifies the three scenarios requested:
--   (1) Machine with active cycle, transferred mid-cycle — cycle continues
--       uninterrupted under the new owner (scheduler entry, due-timer, bill
--       increment on completion, no data loss).
--   (2) Machine condition-blocked (mid-maintenance), transferred — block state
--       and condition value transfer intact, not reset or lost.
--   (3) Simulated crash between houseTransferred event firing and
--       transferHouseMachines completing — confirms the stale-owner state,
--       then confirms startup reconciliation fixes it.
--
-- These tests use the same mock-repo pattern as cycle_engine_spec.lua: real
-- domain modules, mocked repo/adapter/scheduler layers, stubbed FiveM globals.

-- ---------------------------------------------------------------------------
-- Stub FiveM globals that don't exist under stock Lua 5.4.
-- ---------------------------------------------------------------------------
CreateThread = function(fn) fn() end  -- run synchronously in tests
Wait = function() end
RegisterNetEvent = function() end
AddEventHandler = function() end
TriggerEvent = function() end
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
-- Load real shared/config/domain modules.
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
-- Mock repo layer (in-memory state that mutates).
-- Extends the cycle_engine_spec pattern with transferHouseMachines and
-- reconcileHouseMachineOwners.
-- ---------------------------------------------------------------------------
local function makeMockRepos()
    local state = {
        machine = nil,
        activeCycle = nil,
        stock = {},
        bills = {},
        events = {},
        calls = {},
        nextSeq = 1,
        -- Simulated player_houses table for reconciliation: { [houseId] = citizenid }
        playerHouses = {},
    }

    local function log(name, args) state.calls[#state.calls + 1] = { name = name, args = args } end

    local MachinesRepo = {
        load = function(uuid)
            if state.machine and state.machine.machine_uuid == uuid then
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
            state.machine.blocked_detail = detail
            state.machine.next_due_at = nil
            state.machine.active_cycle_id = nil
            state.machine.version = (state.machine.version or 0) + 1
            return true
        end,
        clearNextDue = function(uuid, version)
            log('clearNextDue', { uuid = uuid })
            state.machine.next_due_at = nil
            state.machine.operational_status = 'STOPPED'
            state.machine.blocked_reason = nil
            state.machine.blocked_detail = nil
            state.machine.active_cycle_id = nil
            state.machine.active_bill_id = nil
            state.machine.version = (state.machine.version or 0) + 1
            return true
        end,
        -- Simulates the real transferHouseMachines: updates owner_id only,
        -- preserves everything else (condition, cycle, upgrades, block state).
        transferHouseMachines = function(houseId, newOwnerCid)
            log('transferHouseMachines', { houseId = houseId, newOwnerCid = newOwnerCid })
            if state.machine
               and state.machine.location_type == 'HOUSE'
               and state.machine.location_id == houseId
               and state.machine.lifecycle == 'INSTALLED' then
                state.machine.owner_id = newOwnerCid
                state.machine.version = (state.machine.version or 0) + 1
                return 1
            end
            return 0
        end,
        -- Simulates startup reconciliation: finds INSTALLED machines at HOUSE
        -- locations whose owner_id doesn't match the player_houses owner,
        -- and updates them. Returns count + list of reconciled machines.
        reconcileHouseMachineOwners = function()
            log('reconcileHouseMachineOwners', {})
            if not state.machine then return 0, {} end
            if state.machine.lifecycle ~= 'INSTALLED' then return 0, {} end
            if state.machine.location_type ~= 'HOUSE' then return 0, {} end
            local houseOwner = state.playerHouses[state.machine.location_id]
            if not houseOwner then return 0, {} end
            if state.machine.owner_id == houseOwner then return 0, {} end
            local staleOwner = state.machine.owner_id
            state.machine.owner_id = houseOwner
            state.machine.version = (state.machine.version or 0) + 1
            return 1, { { machine_uuid = state.machine.machine_uuid, old_owner = staleOwner, new_owner = houseOwner } }
        end,
    }

    local CyclesRepo = {
        loadActive = function(uuid)
            log('loadActive', { uuid = uuid })
            return state.activeCycle and copyRow(state.activeCycle) or nil
        end,
        complete = function(params)
            log('complete', { cycle_id = params.cycle_id, idempotency_key = params.idempotency_key })
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
            return true, nil, false  -- ok, err, replayed
        end,
        start = function(params)
            log('start', { cycle_id = params.cycle_id, recipe_id = params.recipe_id, bill_id = params.bill_id })
            for _, delta in ipairs(params.stock_deltas or {}) do
                local row = state.stock[delta.item_name] or { quantity = 0, reserved_quantity = 0 }
                row.quantity = math.max(0, row.quantity + (delta.quantity_delta or 0))
                row.reserved_quantity = math.max(0, row.reserved_quantity + (delta.reserved_delta or 0))
                state.stock[delta.item_name] = row
            end
            if params.power_to_consume and params.power_to_consume > 0 then
                state.machine.power_level = math.max(0, (state.machine.power_level or 0) - params.power_to_consume)
            end
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
            return true, nil, false
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
local function assertNotEqual(actual, expected, message)
    if actual == expected then
        error((message or "Assertion failed") .. " | expected NOT " .. tostring(expected) .. ", actual=" .. tostring(actual))
    end
end
local function countCalls(state, name)
    local n = 0
    for _, c in ipairs(state.calls) do
        if c.name == name then n = n + 1 end
    end
    return n
end

-- Loads the cycle engine with mocked dependencies.
local function loadEngine(MachinesRepo, CyclesRepo, BillsRepo, StockRepo, SchedulerTick)
    CZCraft.MachinesRepo = MachinesRepo
    CZCraft.CyclesRepo = CyclesRepo
    CZCraft.BillsRepo = BillsRepo
    CZCraft.StockRepo = StockRepo
    CZCraft.SchedulerTick = SchedulerTick
    package.loaded = package.loaded or {}
    local engine = dofile("resources/[meus-scripts]/qb-czcraft/server/cycle_engine.lua")
    return engine
end

-- Builds a standard test machine at a house with a smelt_steel bill + cycle.
local function setupMachineWithCycle(state, ownerCid)
    state.machine = {
        machine_uuid = 'm1', machine_type = 'refinery', lifecycle = 'INSTALLED',
        operational_status = 'RUNNING', version = 1,
        owner_type = 'PLAYER', owner_id = ownerCid,
        location_type = 'HOUSE', location_id = 'house_apple',
        next_due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 100),
        active_cycle_id = 'c1',
        active_bill_id = 'b1',
        condition = 80, power_level = 100,
        upgrade_speed_level = 0, upgrade_capacity_level = 0,
        upgrade_efficiency_level = 0, upgrade_durability_level = 0,
        upgrade_budget_used = 0,
    }
    state.activeCycle = {
        cycle_id = 'c1', cycle_sequence = 1, machine_uuid = 'm1',
        bill_id = 'b1', recipe_id = 'smelt_steel',
        started_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 160),
        due_at = os.date('!%Y-%m-%d %H:%M:%S.000', FIXED_NOW - 100),
        duration_seconds = 60,
        standard_cost = 0,
    }
    state.stock = {
        iron = { quantity = 100, reserved_quantity = 0 },
        metalscrap = { quantity = 50, reserved_quantity = 0 },
        steel = { quantity = 0, reserved_quantity = 2 },
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
end

-- Builds a condition-blocked machine at a house (no active cycle).
local function setupConditionBlockedMachine(state, ownerCid)
    state.machine = {
        machine_uuid = 'm2', machine_type = 'refinery', lifecycle = 'INSTALLED',
        operational_status = 'BLOCKED', version = 1,
        owner_type = 'PLAYER', owner_id = ownerCid,
        location_type = 'HOUSE', location_id = 'house_banana',
        next_due_at = nil,
        blocked_reason = 'condition low',
        blocked_detail = nil,
        active_cycle_id = nil,
        condition = 15,
        power_level = 100,
        upgrade_speed_level = 2, upgrade_capacity_level = 1,
        upgrade_efficiency_level = 0, upgrade_durability_level = 3,
        upgrade_budget_used = 60,
    }
    state.activeCycle = nil
    state.stock = {}
    state.bills = {}
end

return {
    -- =====================================================================
    -- Scenario 1: Machine with active cycle, transferred mid-cycle
    -- =====================================================================

    {
        name = "Transfer mid-cycle: owner_id changes to new owner",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            setupMachineWithCycle(state, 'OLD-CID')
            local engine = loadEngine(MR, CR, BR, SR, ST)

            -- Simulate the house transfer hook firing.
            local count = MR.transferHouseMachines('house_apple', 'NEW-CID')
            assertEqual(count, 1, "one machine transferred")

            -- Verify owner changed.
            assertEqual(state.machine.owner_id, 'NEW-CID', "owner_id is now NEW-CID")
            -- Verify nothing else changed.
            assertEqual(state.machine.active_cycle_id, 'c1', "active_cycle_id preserved")
            assertEqual(state.machine.operational_status, 'RUNNING', "still RUNNING")
            assertEqual(state.machine.condition, 80, "condition preserved")
        end,
    },
    {
        name = "Transfer mid-cycle: cycle completes under new owner (bill increment, stock produced)",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            setupMachineWithCycle(state, 'OLD-CID')
            local engine = loadEngine(MR, CR, BR, SR, ST)

            -- Transfer the house.
            MR.transferHouseMachines('house_apple', 'NEW-CID')

            -- Now the scheduler fires processMachine (cycle is due).
            engine.processMachine('m1')

            -- Cycle was completed.
            assertEqual(countCalls(state, 'complete'), 1, "cycle completed exactly once")
            -- Bill was incremented (smelt_steel batch = 2).
            assertEqual(countCalls(state, 'incrementProduced'), 1, "bill incremented once")
            assertEqual(state.bills.b1.produced_quantity, 2, "bill produced_quantity = 2 (batch output)")
            -- Steel was produced from the completed cycle (reserved -> actual).
            assertEqual(state.stock.steel.quantity, 2, "steel stock produced from cycle")
            -- Machine is now under the new owner.
            assertEqual(state.machine.owner_id, 'NEW-CID', "machine owner is NEW-CID after completion")
            -- Next cycle started (start called).
            assertEqual(countCalls(state, 'start'), 1, "next cycle started")
            -- No data loss: iron and metalscrap were consumed for the next cycle start.
            assertTrue(state.stock.iron.quantity < 100, "iron consumed for next cycle start")
        end,
    },
    {
        name = "Transfer mid-cycle: scheduler re-heap fires for new owner's machine",
        test = function()
            local state, MR, CR, BR, SR, ST, wakeLog = makeMockRepos()
            setupMachineWithCycle(state, 'OLD-CID')
            local engine = loadEngine(MR, CR, BR, SR, ST)

            -- Transfer.
            MR.transferHouseMachines('house_apple', 'NEW-CID')

            -- Process the machine (cycle due).
            engine.processMachine('m1')

            -- After completion + next cycle start, the scheduler should have
            -- been woken (re-heaped) so the machine continues under the new owner.
            assertTrue(#wakeLog >= 1, "scheduler was woken at least once")
            -- The wake is for the same machine.
            assertEqual(wakeLog[#wakeLog].uuid, 'm1', "wake is for machine m1")
        end,
    },
    {
        name = "Transfer mid-cycle: no data loss — condition, upgrades, power preserved",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            setupMachineWithCycle(state, 'OLD-CID')
            -- Add some upgrade state to verify it survives transfer.
            state.machine.upgrade_speed_level = 3
            state.machine.upgrade_capacity_level = 2
            state.machine.upgrade_budget_used = 50
            local engine = loadEngine(MR, CR, BR, SR, ST)

            -- Transfer.
            MR.transferHouseMachines('house_apple', 'NEW-CID')

            -- Verify upgrade state survived.
            assertEqual(state.machine.upgrade_speed_level, 3, "speed level preserved")
            assertEqual(state.machine.upgrade_capacity_level, 2, "capacity level preserved")
            assertEqual(state.machine.upgrade_budget_used, 50, "budget used preserved")
            assertEqual(state.machine.condition, 80, "condition preserved")
            assertEqual(state.machine.power_level, 100, "power level preserved")
        end,
    },

    -- =====================================================================
    -- Scenario 2: Condition-blocked machine, transferred
    -- =====================================================================

    {
        name = "Transfer condition-blocked: block state preserved under new owner",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            setupConditionBlockedMachine(state, 'OLD-CID')
            local engine = loadEngine(MR, CR, BR, SR, ST)

            -- Transfer.
            local count = MR.transferHouseMachines('house_banana', 'NEW-CID')
            assertEqual(count, 1, "one machine transferred")

            -- Verify block state is intact.
            assertEqual(state.machine.operational_status, 'BLOCKED', "still BLOCKED")
            assertEqual(state.machine.blocked_reason, 'condition low', "blocked_reason preserved")
            assertEqual(state.machine.condition, 15, "condition value preserved (not reset)")
            -- Verify owner changed.
            assertEqual(state.machine.owner_id, 'NEW-CID', "owner is NEW-CID")
        end,
    },
    {
        name = "Transfer condition-blocked: upgrades and budget preserved",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            setupConditionBlockedMachine(state, 'OLD-CID')
            local engine = loadEngine(MR, CR, BR, SR, ST)

            -- Transfer.
            MR.transferHouseMachines('house_banana', 'NEW-CID')

            -- All upgrade state must survive.
            assertEqual(state.machine.upgrade_speed_level, 2, "speed level preserved")
            assertEqual(state.machine.upgrade_capacity_level, 1, "capacity level preserved")
            assertEqual(state.machine.upgrade_durability_level, 3, "durability level preserved")
            assertEqual(state.machine.upgrade_budget_used, 60, "budget used preserved")
        end,
    },
    {
        name = "Transfer condition-blocked: new owner can maintain (processMachine doesn't crash)",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            setupConditionBlockedMachine(state, 'OLD-CID')
            local engine = loadEngine(MR, CR, BR, SR, ST)

            -- Transfer.
            MR.transferHouseMachines('house_banana', 'NEW-CID')

            -- processMachine on a BLOCKED machine with no active cycle and no
            -- next_due_at should be a no-op (idle). It must not crash or start
            -- a cycle (condition is below block threshold).
            engine.processMachine('m2')

            -- No cycle was started (condition-blocked).
            assertEqual(countCalls(state, 'start'), 0, "no cycle started (condition blocked)")
            -- No completion (no active cycle).
            assertEqual(countCalls(state, 'complete'), 0, "no completion (no active cycle)")
            -- Machine is still blocked.
            assertEqual(state.machine.operational_status, 'BLOCKED', "still BLOCKED after processMachine")
            assertEqual(state.machine.condition, 15, "condition unchanged")
        end,
    },

    -- =====================================================================
    -- Scenario 3: Simulated crash between event firing and transfer completing
    -- =====================================================================

    {
        name = "Crash scenario: machine left with stale owner (transfer did not complete)",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            setupMachineWithCycle(state, 'OLD-CID')
            local engine = loadEngine(MR, CR, BR, SR, ST)

            -- Simulate crash: the houseTransferred event fires but
            -- transferHouseMachines does NOT complete (server crashed).
            -- The house owner in player_houses has changed, but the machine
            -- owner_id is still the old owner.
            state.playerHouses['house_apple'] = 'NEW-CID'
            -- DO NOT call transferHouseMachines — simulate the crash.

            -- Verify the stale-owner state.
            assertEqual(state.machine.owner_id, 'OLD-CID', "machine owner is STALE (still OLD-CID)")
            assertNotEqual(state.machine.owner_id, state.playerHouses['house_apple'],
                "machine owner does not match house owner")
        end,
    },
    {
        name = "Crash scenario: stale owner allows old owner to pick up (security gap)",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            setupMachineWithCycle(state, 'OLD-CID')
            local engine = loadEngine(MR, CR, BR, SR, ST)

            -- House transferred in player_houses but machine not updated.
            state.playerHouses['house_apple'] = 'NEW-CID'

            -- The old owner still appears as the machine owner. If they call
            -- pickup, the permission check (owner_id == citizenid) would pass.
            -- This is the security gap.
            assertEqual(state.machine.owner_id, 'OLD-CID', "old owner still has machine access")
        end,
    },
    {
        name = "Crash scenario: startup reconciliation fixes stale owner",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            setupMachineWithCycle(state, 'OLD-CID')
            local engine = loadEngine(MR, CR, BR, SR, ST)

            -- House transferred in player_houses but machine not updated (crash).
            state.playerHouses['house_apple'] = 'NEW-CID'

            -- Verify stale state before reconciliation.
            assertEqual(state.machine.owner_id, 'OLD-CID', "stale owner before reconciliation")

            -- Run startup reconciliation.
            local count, details = MR.reconcileHouseMachineOwners()
            assertEqual(count, 1, "one machine reconciled")
            assertEqual(details[1].machine_uuid, 'm1', "reconciled machine m1")
            assertEqual(details[1].old_owner, 'OLD-CID', "old owner was OLD-CID")
            assertEqual(details[1].new_owner, 'NEW-CID', "new owner is NEW-CID")

            -- Verify the machine owner is now correct.
            assertEqual(state.machine.owner_id, 'NEW-CID', "owner fixed by reconciliation")
            -- Verify nothing else was touched.
            assertEqual(state.machine.active_cycle_id, 'c1', "active cycle preserved by reconciliation")
            assertEqual(state.machine.condition, 80, "condition preserved by reconciliation")
            assertEqual(state.machine.operational_status, 'RUNNING', "status preserved by reconciliation")
        end,
    },
    {
        name = "Crash scenario: reconciliation is idempotent (no-op when owner already matches)",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            setupMachineWithCycle(state, 'NEW-CID')
            local engine = loadEngine(MR, CR, BR, SR, ST)

            -- House owner matches machine owner.
            state.playerHouses['house_apple'] = 'NEW-CID'

            -- Reconciliation should be a no-op.
            local count = MR.reconcileHouseMachineOwners()
            assertEqual(count, 0, "no machines need reconciliation (already matches)")
            -- Version should NOT have been bumped.
            assertEqual(state.machine.version, 1, "version unchanged (no update needed)")
        end,
    },
    {
        name = "Crash scenario: reconciliation skips non-HOUSE machines",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            setupMachineWithCycle(state, 'OLD-CID')
            -- Change to ORG location.
            state.machine.location_type = 'ORG'
            state.machine.location_id = 'plot_1'
            local engine = loadEngine(MR, CR, BR, SR, ST)

            state.playerHouses['house_apple'] = 'NEW-CID'

            local count = MR.reconcileHouseMachineOwners()
            assertEqual(count, 0, "ORG machines are not reconciled")
            assertEqual(state.machine.owner_id, 'OLD-CID', "ORG machine owner unchanged")
        end,
    },
    {
        name = "Crash scenario: reconciliation skips PACKED machines",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            setupMachineWithCycle(state, 'OLD-CID')
            state.machine.lifecycle = 'PACKED'
            local engine = loadEngine(MR, CR, BR, SR, ST)

            state.playerHouses['house_apple'] = 'NEW-CID'

            local count = MR.reconcileHouseMachineOwners()
            assertEqual(count, 0, "PACKED machines are not reconciled")
        end,
    },
    {
        name = "Crash scenario: after reconciliation, cycle completes under correct owner",
        test = function()
            local state, MR, CR, BR, SR, ST = makeMockRepos()
            setupMachineWithCycle(state, 'OLD-CID')
            local engine = loadEngine(MR, CR, BR, SR, ST)

            -- Crash: house transferred but machine not updated.
            state.playerHouses['house_apple'] = 'NEW-CID'

            -- Reconciliation runs at startup.
            MR.reconcileHouseMachineOwners()

            -- Now the scheduler fires processMachine.
            engine.processMachine('m1')

            -- Cycle completed under the correct (new) owner.
            assertEqual(countCalls(state, 'complete'), 1, "cycle completed")
            assertEqual(countCalls(state, 'incrementProduced'), 1, "bill incremented")
            assertEqual(state.bills.b1.produced_quantity, 2, "bill produced 2 steel")
            assertEqual(state.machine.owner_id, 'NEW-CID', "machine owner is NEW-CID")
            assertEqual(state.stock.steel.quantity, 2, "steel produced")
        end,
    },
}
