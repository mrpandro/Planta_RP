-- qb-czcraft condition domain tests (pure)
-- Tests server/domain/condition.lua with the real config loaded.

-- Load constants + config so the domain reads CZCraft.Config.Balance.condition.
dofile("resources/[meus-scripts]/qb-czcraft/shared/constants.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/general.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/balance.lua")

local Condition = dofile("resources/[meus-scripts]/qb-czcraft/server/domain/condition.lua")

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

return {
    -- =====================================================================
    -- canStartCycle / isBlocked
    -- =====================================================================
    {
        name = "canStartCycle: true when condition above block threshold",
        test = function()
            assertTrue(Condition.canStartCycle(100), "100 can start")
            assertTrue(Condition.canStartCycle(21), "21 can start (above 20)")
        end,
    },
    {
        name = "canStartCycle: false when condition at or below block threshold",
        test = function()
            assertFalse(Condition.canStartCycle(20), "20 cannot start (at threshold)")
            assertFalse(Condition.canStartCycle(0), "0 cannot start")
        end,
    },
    {
        name = "isBlocked: inverse of canStartCycle",
        test = function()
            assertFalse(Condition.isBlocked(100), "100 not blocked")
            assertTrue(Condition.isBlocked(20), "20 blocked")
            assertTrue(Condition.isBlocked(0), "0 blocked")
        end,
    },
    {
        name = "canStartCycle: nil condition treated as 0 (blocked)",
        test = function()
            assertFalse(Condition.canStartCycle(nil), "nil blocked")
        end,
    },

    -- =====================================================================
    -- computeWear
    -- =====================================================================
    {
        name = "computeWear: returns config wearPerCycle by default",
        test = function()
            assertEqual(Condition.computeWear(), 0.5, "default wear = 0.5")
        end,
    },
    {
        name = "computeWear: applies multiplier (durability upgrade)",
        test = function()
            -- Level 3 durability: -15% per level = -45% total, multiplier = 0.55
            assertEqual(Condition.computeWear(0.55), 0.28, "0.5 * 0.55 = 0.275 -> 0.28")
        end,
    },
    {
        name = "computeWear: zero multiplier produces zero wear",
        test = function()
            assertEqual(Condition.computeWear(0), 0, "0 * 0.5 = 0")
        end,
    },
    {
        name = "computeWear: negative multiplier clamped to zero",
        test = function()
            assertEqual(Condition.computeWear(-1), 0, "negative clamped to 0")
        end,
    },
    {
        name = "computeWear: nil multiplier defaults to 1.0",
        test = function()
            assertEqual(Condition.computeWear(nil), 0.5, "nil -> 1.0 -> 0.5")
        end,
    },

    -- =====================================================================
    -- applyWear
    -- =====================================================================
    {
        name = "applyWear: reduces condition by wear amount",
        test = function()
            assertEqual(Condition.applyWear(100, 0.5), 99.5, "100 - 0.5 = 99.5")
        end,
    },
    {
        name = "applyWear: clamps to 0 (never negative)",
        test = function()
            assertEqual(Condition.applyWear(0.3, 0.5), 0, "0.3 - 0.5 clamped to 0")
        end,
    },
    {
        name = "applyWear: clamps to max (never exceeds)",
        test = function()
            assertEqual(Condition.applyWear(105, 0), 100, "105 clamped to 100")
        end,
    },
    {
        name = "applyWear: nil condition treated as 0",
        test = function()
            assertEqual(Condition.applyWear(nil, 0.5), 0, "nil - 0.5 = 0")
        end,
    },

    -- =====================================================================
    -- applyMaintenance
    -- =====================================================================
    {
        name = "applyMaintenance: restores condition by restoration amount",
        test = function()
            local after, restored = Condition.applyMaintenance(20)
            assertEqual(after, 60, "20 + 40 = 60")
            assertEqual(restored, 40, "restored 40")
        end,
    },
    {
        name = "applyMaintenance: clamps to max (no overfill)",
        test = function()
            local after, restored = Condition.applyMaintenance(80)
            assertEqual(after, 100, "80 + 40 clamped to 100")
            assertEqual(restored, 20, "only 20 actually restored")
        end,
    },
    {
        name = "applyMaintenance: from block threshold reaches mid-range",
        test = function()
            local after = Condition.applyMaintenance(20)
            assertTrue(after > 20, "maintenance lifts above block threshold")
            assertTrue(Condition.canStartCycle(after), "can start after maintenance")
        end,
    },
    {
        name = "applyMaintenance: two maintenances from threshold reach full",
        test = function()
            local after1 = Condition.applyMaintenance(20)
            local after2 = Condition.applyMaintenance(after1)
            assertEqual(after2, 100, "two maintenances from 20 = 100")
        end,
    },
    {
        name = "applyMaintenance: nil condition treated as 0",
        test = function()
            local after, restored = Condition.applyMaintenance(nil)
            assertEqual(after, 40, "0 + 40 = 40")
            assertEqual(restored, 40, "restored 40")
        end,
    },

    -- =====================================================================
    -- computeCycleSnapshot
    -- =====================================================================
    {
        name = "computeCycleSnapshot: records before/after/wear",
        test = function()
            local snap = Condition.computeCycleSnapshot(100, 0.5)
            assertEqual(snap.before, 100, "before = 100")
            assertEqual(snap.after, 99.5, "after = 99.5")
            assertEqual(snap.wearToApply, 0.5, "wear = 0.5")
        end,
    },
    {
        name = "computeCycleSnapshot: near zero clamps to 0",
        test = function()
            local snap = Condition.computeCycleSnapshot(0.3, 0.5)
            assertEqual(snap.before, 0.3, "before = 0.3")
            assertEqual(snap.after, 0, "after clamped to 0")
        end,
    },
    {
        name = "computeCycleSnapshot: nil condition treated as 0",
        test = function()
            local snap = Condition.computeCycleSnapshot(nil, 0.5)
            assertEqual(snap.before, 0, "before = 0")
            assertEqual(snap.after, 0, "after = 0")
        end,
    },
    {
        name = "computeCycleSnapshot: nil wear treated as 0",
        test = function()
            local snap = Condition.computeCycleSnapshot(50, nil)
            assertEqual(snap.before, 50, "before = 50")
            assertEqual(snap.after, 50, "after = 50 (no wear)")
            assertEqual(snap.wearToApply, 0, "wear = 0")
        end,
    },

    -- =====================================================================
    -- Integration-style: wear then block then maintenance
    -- =====================================================================
    {
        name = "Wear cycle: 160 cycles degrades 100 -> 20 (block threshold)",
        test = function()
            local level = 100
            local wear = Condition.computeWear()
            for _ = 1, 160 do
                level = Condition.applyWear(level, wear)
            end
            assertEqual(level, 20, "160 * 0.5 = 80 wear, 100 - 80 = 20")
            assertTrue(Condition.isBlocked(level), "blocked at threshold")
            assertFalse(Condition.canStartCycle(level), "cannot start at threshold")
        end,
    },
    {
        name = "Wear cycle: 200 cycles degrades 100 -> 0 (full degradation)",
        test = function()
            local level = 100
            local wear = Condition.computeWear()
            for _ = 1, 200 do
                level = Condition.applyWear(level, wear)
            end
            assertEqual(level, 0, "200 * 0.5 = 100 wear, 100 - 100 = 0")
        end,
    },
    {
        name = "Maintenance recovers from block to operational",
        test = function()
            local level = 20 -- at block threshold
            assertTrue(Condition.isBlocked(level), "blocked")
            level = Condition.applyMaintenance(level)
            assertFalse(Condition.isBlocked(level), "not blocked after maintenance")
            assertTrue(Condition.canStartCycle(level), "can start after maintenance")
        end,
    },
}
