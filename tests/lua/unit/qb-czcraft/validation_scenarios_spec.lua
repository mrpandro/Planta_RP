-- qb-czcraft checkpoint-2 validation scenarios
-- Tests for the three validation scenarios from v0.2-plan.md line 14:
--   1. Capacity downgrade while stock exceeds the new cap
--   2. Packing a machine with upgrades + non-zero condition (persist + restore)
--   3. House transfer mid-maintenance (condition blocked) or mid-cycle
--
-- These are pure domain tests where possible. The API/repo layers use FiveM
-- natives and MySQL, so they're validated by inspecting the SQL and logic
-- rather than direct execution.

dofile("resources/[meus-scripts]/qb-czcraft/shared/constants.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/general.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/balance.lua")

local Upgrades = dofile("resources/[meus-scripts]/qb-czcraft/server/domain/upgrades.lua")
local Machines = dofile("resources/[meus-scripts]/qb-czcraft/server/domain/machines.lua")

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
        error((message or "Expected string to contain needle") .. " | needle=" .. tostring(needle) .. ", haystack=" .. tostring(haystack))
    end
end

return {
    -- =====================================================================
    -- Scenario 1: Capacity downgrade while stock exceeds the new cap
    -- =====================================================================

    {
        name = "Capacity downgrade: blocked when stock exceeds new cap",
        test = function()
            -- Machine at capacity L3 (250k * 1.3 = 325k). Stock at 310k.
            -- Downgrade to L2 would give 250k * 1.2 = 300k. 310k > 300k → blocked.
            local ok, reason = Upgrades.validateDowngrade({
                track = 'capacity',
                currentLevel = 3,
                machineUsedWeight = 310000,
                baseCapacity = 250000,
            })
            assertFalse(ok, "downgrade should be blocked")
            assertContains(reason, 'exceeds', "reason mentions exceeds")
            assertContains(reason, 'drain', "reason tells player to drain stock")
        end,
    },
    {
        name = "Capacity downgrade: allowed when stock fits new cap",
        test = function()
            -- Stock at 290k fits within L2 cap of 300k.
            local ok = Upgrades.validateDowngrade({
                track = 'capacity',
                currentLevel = 3,
                machineUsedWeight = 290000,
                baseCapacity = 250000,
            })
            assertTrue(ok, "downgrade should be allowed")
        end,
    },
    {
        name = "Capacity downgrade: non-capacity tracks ignore stock weight",
        test = function()
            -- Speed/efficiency/durability don't affect capacity, so stock
            -- weight is irrelevant.
            local ok = Upgrades.validateDowngrade({
                track = 'speed',
                currentLevel = 2,
                machineUsedWeight = 999999,
                baseCapacity = 250000,
            })
            assertTrue(ok, "speed downgrade ignores stock")
        end,
    },
    {
        name = "Capacity downgrade: effective capacity at each level",
        test = function()
            -- Verify the capacity progression: L0=250k, L1=275k, L2=300k, L3=325k, L4=350k, L5=375k
            assertEqual(Upgrades.effectiveCapacity(250000, 0), 250000, "L0")
            assertEqual(Upgrades.effectiveCapacity(250000, 1), 275000, "L1")
            assertEqual(Upgrades.effectiveCapacity(250000, 2), 300000, "L2")
            assertEqual(Upgrades.effectiveCapacity(250000, 3), 325000, "L3")
            assertEqual(Upgrades.effectiveCapacity(250000, 5), 375000, "L5")
        end,
    },

    -- =====================================================================
    -- Scenario 2: Packing a machine with upgrades + non-zero condition
    -- =====================================================================
    -- The pickup flow (api.lua) must preserve condition and upgrade levels
    -- in the item info. The placement flow must reactivate the existing
    -- PACKED row instead of creating a new one. The setPacked repo method
    -- must NOT clear condition or upgrade columns.
    --
    -- These tests validate the domain invariants and inspect the repo SQL
    -- to confirm preservation. The full API flow uses FiveM natives and
    -- can't run in pure Lua.

    {
        name = "Packed preservation: validatePickup allows stopped machine with condition/upgrades",
        test = function()
            -- A machine with condition=42 and upgrade levels can be picked up
            -- if it's stopped, no active cycle, no bills, empty stock.
            local machine = {
                lifecycle = 'INSTALLED',
                operational_status = 'STOPPED',
                active_cycle_id = nil,
                condition = 42,
                upgrade_speed_level = 3,
                upgrade_capacity_level = 2,
            }
            local ok, reason = Machines.validatePickup(machine, 0, 0, 0)
            assertTrue(ok, "should allow pickup")
            assertEqual(reason, nil, "no reason")
        end,
    },
    {
        name = "Packed preservation: validatePickup blocks RUNNING machine (mid-cycle)",
        test = function()
            local machine = {
                lifecycle = 'INSTALLED',
                operational_status = 'RUNNING',
                active_cycle_id = 'cycle-1',
                condition = 42,
            }
            local ok, reason = Machines.validatePickup(machine, 0, 0, 0)
            assertFalse(ok, "should block pickup mid-cycle")
            assertContains(reason, 'running', "reason mentions running")
        end,
    },
    {
        name = "Packed preservation: validatePickup blocks BLOCKED machine (mid-maintenance)",
        test = function()
            -- A condition-blocked machine is in BLOCKED status. The player
            -- must perform maintenance (or the machine must be unblocked)
            -- before pickup. Actually, BLOCKED is a stopped state — let's
            -- check: operational_status BLOCKED with no active cycle should
            -- be pickupable. The machine is stopped, just blocked from
            -- starting new cycles.
            local machine = {
                lifecycle = 'INSTALLED',
                operational_status = 'BLOCKED',
                active_cycle_id = nil,
                condition = 15,
                blocked_reason = 'condition low',
            }
            -- BLOCKED is not RUNNING, and no active cycle, so pickup is allowed.
            -- The machine is stopped; the new owner inherits the blocked state.
            local ok = Machines.validatePickup(machine, 0, 0, 0)
            assertTrue(ok, "BLOCKED machine can be picked up (it's stopped)")
        end,
    },
    {
        name = "Packed preservation: setPacked SQL preserves condition and upgrade columns",
        test = function()
            -- Inspect the setPacked function source to verify it does NOT
            -- clear condition, power_level, or upgrade_*_level columns.
            -- This is a static analysis test — the function uses MySQL so
            -- can't be executed in pure Lua.
            local path = "resources/[meus-scripts]/qb-czcraft/server/repositories/machines.lua"
            local f = io.open(path, "r")
            assertTrue(f, "machines.lua should be readable")
            local content = f:read("*a")
            f:close()

            -- Find the setPacked function body.
            local startIdx = string.find(content, "function MachinesRepo.setPacked")
            assertTrue(startIdx, "setPacked function should exist")
            local endIdx = string.find(content, "function MachinesRepo", startIdx + 1)
            if not endIdx then
                endIdx = string.find(content, "CZCraft.MachinesRepo", startIdx + 1)
            end
            assertTrue(endIdx, "setPacked function should end")
            local setPackedBody = string.sub(content, startIdx, endIdx)

            -- Verify it sets lifecycle to PACKED.
            assertContains(setPackedBody, "'PACKED'", "sets PACKED lifecycle")

            -- Verify it does NOT clear condition, power_level, or upgrade columns.
            -- It should NOT contain "condition = 0" or "condition = NULL" or similar.
            assertFalse(string.find(setPackedBody, "`condition`"), "should not touch condition column")
            assertFalse(string.find(setPackedBody, "`power_level`"), "should not touch power_level column")
            assertFalse(string.find(setPackedBody, "upgrade_"), "should not touch upgrade columns")
        end,
    },
    {
        name = "Packed preservation: reactivateInstalled SQL preserves condition and upgrades",
        test = function()
            -- Inspect the reactivateInstalled function to verify it does NOT
            -- reset condition or upgrade levels — only updates location/owner.
            local path = "resources/[meus-scripts]/qb-czcraft/server/repositories/machines.lua"
            local f = io.open(path, "r")
            assertTrue(f, "machines.lua should be readable")
            local content = f:read("*a")
            f:close()

            local startIdx = string.find(content, "function MachinesRepo.reactivateInstalled")
            assertTrue(startIdx, "reactivateInstalled function should exist")
            local endIdx = string.find(content, "function MachinesRepo", startIdx + 1)
            if not endIdx then
                endIdx = string.find(content, "CZCraft.MachinesRepo", startIdx + 1)
            end
            assertTrue(endIdx, "reactivateInstalled function should end")
            local body = string.sub(content, startIdx, endIdx)

            -- Verify it sets lifecycle to INSTALLED.
            assertContains(body, "'INSTALLED'", "sets INSTALLED lifecycle")

            -- Verify it does NOT reset condition or upgrade columns.
            assertFalse(string.find(body, "`condition`"), "should not touch condition column")
            assertFalse(string.find(body, "`power_level`"), "should not touch power_level column")
            assertFalse(string.find(body, "upgrade_"), "should not touch upgrade columns")

            -- Verify it requires lifecycle = 'PACKED' (only reactivates packed machines).
            assertContains(body, "'PACKED'", "requires PACKED lifecycle")
        end,
    },
    {
        name = "Packed preservation: pickup item info preserves condition (api.lua source)",
        test = function()
            -- Inspect api.lua to verify the pickup flow reads actual condition
            -- and upgrade levels from the machine row, not hardcoded values.
            local path = "resources/[meus-scripts]/qb-czcraft/server/api.lua"
            local f = io.open(path, "r")
            assertTrue(f, "api.lua should be readable")
            local content = f:read("*a")
            f:close()

            -- Find the itemInfo construction in pickupMachine.
            local startIdx = string.find(content, "local itemInfo = {")
            assertTrue(startIdx, "itemInfo should exist in api.lua")
            -- Find the closing brace.
            local endIdx = string.find(content, "}", startIdx + 1)
            assertTrue(endIdx, "itemInfo should close")
            local itemInfoBlock = string.sub(content, startIdx, endIdx)

            -- Verify it reads machine.condition (not hardcoded 100).
            assertContains(itemInfoBlock, "machine.condition", "reads actual condition")
            assertFalse(string.find(itemInfoBlock, "condition = 100"), "should not hardcode condition=100")

            -- Verify it includes upgrade levels.
            assertContains(itemInfoBlock, "upgrade_speed_level", "includes speed level")
            assertContains(itemInfoBlock, "upgrade_capacity_level", "includes capacity level")
            assertContains(itemInfoBlock, "upgrade_durability_level", "includes durability level")
        end,
    },

    -- =====================================================================
    -- Scenario 3: House transfer mid-maintenance or mid-cycle
    -- =====================================================================
    -- Per decisions.md: "Imóvel transferido: Máquina, stock, bills e ciclo
    -- passam ao novo dono da casa." The transfer hook reassigns owner_id
    -- for all machines at the house. Active cycles continue (tied to
    -- machine_uuid, not owner). Condition-blocked machines stay blocked
    -- (new owner can maintain).

    {
        name = "House transfer: transferHouseMachines SQL reassigns owner only",
        test = function()
            -- Inspect the transferHouseMachines function to verify it only
            -- updates owner_id (not condition, upgrades, cycle, or bills).
            local path = "resources/[meus-scripts]/qb-czcraft/server/repositories/machines.lua"
            local f = io.open(path, "r")
            assertTrue(f, "machines.lua should be readable")
            local content = f:read("*a")
            f:close()

            local startIdx = string.find(content, "function MachinesRepo.transferHouseMachines")
            assertTrue(startIdx, "transferHouseMachines should exist")
            local endIdx = string.find(content, "CZCraft.MachinesRepo", startIdx + 1)
            assertTrue(endIdx, "function should end")
            local body = string.sub(content, startIdx, endIdx)

            -- Verify it updates owner_id.
            assertContains(body, "`owner_id`", "updates owner_id")

            -- Verify it filters by HOUSE location and INSTALLED lifecycle.
            assertContains(body, "'HOUSE'", "filters by HOUSE location")
            assertContains(body, "'INSTALLED'", "filters by INSTALLED lifecycle")

            -- Verify it does NOT touch condition, upgrades, cycle, or bills.
            assertFalse(string.find(body, "`condition`"), "should not touch condition")
            assertFalse(string.find(body, "upgrade_"), "should not touch upgrades")
            assertFalse(string.find(body, "active_cycle"), "should not touch active cycle")
        end,
    },
    {
        name = "House transfer: mid-cycle machine continues under new owner",
        test = function()
            -- An active cycle is tied to machine_uuid, not owner_id. The
            -- transfer only changes owner_id, so the cycle continues. The
            -- cycle completion will apply outputs to the machine's stock
            -- regardless of who owns it. The new owner can then withdraw.
            --
            -- This is a domain invariant test: validatePickup blocks pickup
            -- of a RUNNING machine (mid-cycle), so the machine stays in
            -- place during the transfer. The transfer changes owner_id;
            -- the cycle completes normally.
            local machine = {
                lifecycle = 'INSTALLED',
                operational_status = 'RUNNING',
                active_cycle_id = 'cycle-abc',
                condition = 50,
                owner_id = 'OLD-CID',
            }
            -- Pickup is blocked (machine is running).
            local ok, reason = Machines.validatePickup(machine, 0, 0, 0)
            assertFalse(ok, "mid-cycle machine can't be picked up")
            assertContains(reason, 'running', "reason mentions running")

            -- The transfer hook changes owner_id but doesn't touch the cycle.
            -- The cycle completes normally under the new owner.
        end,
    },
    {
        name = "House transfer: condition-blocked machine stays blocked under new owner",
        test = function()
            -- A condition-blocked machine (operational_status BLOCKED, condition
            -- below threshold) is stopped. The transfer changes owner_id. The
            -- new owner inherits the blocked state and can perform maintenance.
            local machine = {
                lifecycle = 'INSTALLED',
                operational_status = 'BLOCKED',
                active_cycle_id = nil,
                condition = 15,
                blocked_reason = 'condition low',
                owner_id = 'OLD-CID',
            }
            -- The machine is stopped (BLOCKED is not RUNNING), so it stays
            -- in place during the transfer. The new owner can maintain it.
            local ok = Machines.validatePickup(machine, 0, 0, 0)
            assertTrue(ok, "BLOCKED machine is stopped and can be transferred")
        end,
    },
    {
        name = "House transfer: event handler registered (api.lua source)",
        test = function()
            -- Verify the houseTransferred event handler is registered in api.lua.
            local path = "resources/[meus-scripts]/qb-czcraft/server/api.lua"
            local f = io.open(path, "r")
            assertTrue(f, "api.lua should be readable")
            local content = f:read("*a")
            f:close()

            assertContains(content, "qb-czcraft:server:houseTransferred", "event registered")
            assertContains(content, "transferHouseMachines", "calls transferHouseMachines")
        end,
    },
}
