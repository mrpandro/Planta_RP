-- qb-czcraft power domain tests (pure)
-- Tests server/domain/power.lua with the real config loaded.

-- Load constants + config so the domain reads CZCraft.Config.Balance.power.
dofile("resources/[meus-scripts]/qb-czcraft/shared/constants.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/general.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/balance.lua")

local Power = dofile("resources/[meus-scripts]/qb-czcraft/server/domain/power.lua")

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

return {
    {
        name = "canStartCycle: true when power >= blockThreshold (default 5)",
        test = function()
            assertTrue(Power.canStartCycle(100), "full power")
            assertTrue(Power.canStartCycle(5), "at threshold")
        end,
    },
    {
        name = "canStartCycle: false when power < blockThreshold (default 5)",
        test = function()
            assertFalse(Power.canStartCycle(4), "below threshold")
            assertFalse(Power.canStartCycle(0), "zero power")
        end,
    },
    {
        name = "isBlocked: inverse of canStartCycle",
        test = function()
            assertFalse(Power.isBlocked(100), "full power not blocked")
            assertTrue(Power.isBlocked(0), "zero power blocked")
            assertTrue(Power.isBlocked(4), "below threshold blocked")
        end,
    },
    {
        name = "computePowerConsumption: returns config consumptionPerCycle (default 5)",
        test = function()
            assertEqual(Power.computePowerConsumption(), 5, "default consumption")
        end,
    },
    {
        name = "computePowerConsumption: efficiency multiplier reduces consumption",
        test = function()
            -- 5 * 0.9 = 4.5 -> rounds to 5 (round half up)
            assertEqual(Power.computePowerConsumption(0.9), 5, "0.9 multiplier rounds to 5")
            -- 5 * 0.8 = 4.0 -> rounds to 4
            assertEqual(Power.computePowerConsumption(0.8), 4, "0.8 multiplier = 4")
            -- 5 * 0.5 = 2.5 -> rounds to 3 (round half up, no free cycles)
            assertEqual(Power.computePowerConsumption(0.5), 3, "0.5 multiplier rounds up to 3")
        end,
    },
    {
        name = "computePowerConsumption: negative multiplier clamped to 0",
        test = function()
            assertEqual(Power.computePowerConsumption(-1), 0, "negative clamped to 0")
        end,
    },
    {
        name = "applyConsumption: decrements power level",
        test = function()
            assertEqual(Power.applyConsumption(100, 5), 95, "100 - 5 = 95")
            assertEqual(Power.applyConsumption(50, 5), 45, "50 - 5 = 45")
        end,
    },
    {
        name = "applyConsumption: clamps to 0 (no negative power)",
        test = function()
            assertEqual(Power.applyConsumption(3, 5), 0, "3 - 5 clamps to 0")
            assertEqual(Power.applyConsumption(0, 5), 0, "0 - 5 stays 0")
        end,
    },
    {
        name = "applyConsumption: clamps to capacity (no overflow above 100)",
        test = function()
            -- If somehow power_level > capacity, the result still clamps to
            -- capacity. 105 - 5 = 100, which is at capacity.
            assertEqual(Power.applyConsumption(105, 5), 100, "105 - 5 = 100 (at capacity)")
        end,
    },
    {
        name = "applyRecharge: adds cell charge (default 50), clamps to capacity",
        test = function()
            local newLevel, added = Power.applyRecharge(50)
            assertEqual(newLevel, 100, "50 + 50 = 100 (at capacity)")
            assertEqual(added, 50, "50 actually added")
        end,
    },
    {
        name = "applyRecharge: clamps to capacity (no overflow)",
        test = function()
            local newLevel, added = Power.applyRecharge(80)
            assertEqual(newLevel, 100, "80 + 50 clamps to 100")
            assertEqual(added, 20, "only 20 actually added (clamped)")
        end,
    },
    {
        name = "applyRecharge: from 0 adds full cell charge",
        test = function()
            local newLevel, added = Power.applyRecharge(0)
            assertEqual(newLevel, 50, "0 + 50 = 50")
            assertEqual(added, 50, "50 added")
        end,
    },
    {
        name = "computeCycleSnapshot: records before/after/consume",
        test = function()
            local snap = Power.computeCycleSnapshot(100, 5)
            assertEqual(snap.before, 100, "before = 100")
            assertEqual(snap.after, 95, "after = 95")
            assertEqual(snap.powerToConsume, 5, "consume = 5")
        end,
    },
    {
        name = "computeCycleSnapshot: after clamps to 0 when consumption exceeds level",
        test = function()
            local snap = Power.computeCycleSnapshot(3, 5)
            assertEqual(snap.before, 3, "before = 3")
            assertEqual(snap.after, 0, "after clamps to 0")
            assertEqual(snap.powerToConsume, 5, "consume = 5")
        end,
    },
    {
        name = "canStartCycle: nil power level treated as 0 (blocked)",
        test = function()
            assertFalse(Power.canStartCycle(nil), "nil -> 0 -> blocked")
        end,
    },
}
