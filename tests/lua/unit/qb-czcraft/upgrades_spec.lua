-- qb-czcraft upgrades domain tests (pure)
-- Tests server/domain/upgrades.lua with the real config loaded.

dofile("resources/[meus-scripts]/qb-czcraft/shared/constants.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/general.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/balance.lua")

local Upgrades = dofile("resources/[meus-scripts]/qb-czcraft/server/domain/upgrades.lua")

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
    -- validatePurchase
    -- =====================================================================
    {
        name = "validatePurchase: valid purchase at level 0",
        test = function()
            local ok, reason, cost = Upgrades.validatePurchase({
                track = 'speed', currentLevel = 0, budgetUsed = 0,
            })
            assertTrue(ok, "should allow")
            assertEqual(cost.points, 1, "speed costs 1 point/level")
            assertEqual(cost.money, 500, "speed costs $500")
        end,
    },
    {
        name = "validatePurchase: valid purchase at level 4 (one below max)",
        test = function()
            local ok = Upgrades.validatePurchase({
                track = 'speed', currentLevel = 4, budgetUsed = 4,
            })
            assertTrue(ok, "should allow L4 -> L5")
        end,
    },
    {
        name = "validatePurchase: rejects at max level",
        test = function()
            local ok, reason = Upgrades.validatePurchase({
                track = 'speed', currentLevel = 5, budgetUsed = 5,
            })
            assertFalse(ok, "should reject at max")
            assertTrue(reason and string.find(reason, 'max'), "reason mentions max")
        end,
    },
    {
        name = "validatePurchase: rejects insufficient budget",
        test = function()
            local ok, reason = Upgrades.validatePurchase({
                track = 'capacity', currentLevel = 0, budgetUsed = 9,
            })
            assertFalse(ok, "should reject (9 + 2 > 10)")
            assertTrue(reason and string.find(reason, 'budget'), "reason mentions budget")
        end,
    },
    {
        name = "validatePurchase: rejects unknown track",
        test = function()
            local ok, reason = Upgrades.validatePurchase({
                track = 'unknown', currentLevel = 0, budgetUsed = 0,
            })
            assertFalse(ok, "should reject unknown track")
            assertTrue(reason and string.find(reason, 'unknown'), "reason mentions unknown")
        end,
    },
    {
        name = "validatePurchase: capacity track costs 2 points",
        test = function()
            local ok, _, cost = Upgrades.validatePurchase({
                track = 'capacity', currentLevel = 0, budgetUsed = 0,
            })
            assertTrue(ok, "should allow")
            assertEqual(cost.points, 2, "capacity costs 2 points/level")
            assertEqual(cost.money, 1000, "capacity costs $1000")
        end,
    },
    {
        name = "validatePurchase: durability track costs 2 points, max 3",
        test = function()
            local ok = Upgrades.validatePurchase({
                track = 'durability', currentLevel = 2, budgetUsed = 4,
            })
            assertTrue(ok, "should allow L2 -> L3")
            local ok2, reason = Upgrades.validatePurchase({
                track = 'durability', currentLevel = 3, budgetUsed = 6,
            })
            assertFalse(ok2, "should reject at max L3")
        end,
    },
    {
        name = "validatePurchase: full budget allocation (10 points)",
        test = function()
            -- Speed L5 (5pts) + capacity L2 (4pts) = 9pts. One more speed? No, speed maxed.
            -- Efficiency L1 (2pts) would exceed (9+2=11 > 10).
            local ok, _ = Upgrades.validatePurchase({
                track = 'speed', currentLevel = 4, budgetUsed = 4,
            })
            assertTrue(ok, "speed L4 -> L5 with 4 used + 1 = 5 <= 10")
            local ok2, reason = Upgrades.validatePurchase({
                track = 'efficiency', currentLevel = 0, budgetUsed = 9,
            })
            assertFalse(ok2, "9 + 2 = 11 > 10, should reject")
        end,
    },

    -- =====================================================================
    -- durationMultiplier / effectiveDuration
    -- =====================================================================
    {
        name = "durationMultiplier: 1.0 at level 0",
        test = function()
            assertEqual(Upgrades.durationMultiplier(0), 1.0, "no bonus at L0")
        end,
    },
    {
        name = "durationMultiplier: 0.75 at level 5 (max speed)",
        test = function()
            assertEqual(Upgrades.durationMultiplier(5), 0.75, "-25% at L5")
        end,
    },
    {
        name = "effectiveDuration: 60s -> 45s at speed L5",
        test = function()
            assertEqual(Upgrades.effectiveDuration(60, 5), 45, "60 * 0.75 = 45")
        end,
    },
    {
        name = "effectiveDuration: 60s -> 57s at speed L1",
        test = function()
            assertEqual(Upgrades.effectiveDuration(60, 1), 57, "60 * 0.95 = 57")
        end,
    },
    {
        name = "effectiveDuration: minimum 1 second",
        test = function()
            assertEqual(Upgrades.effectiveDuration(1, 5), 1, "min 1s")
        end,
    },

    -- =====================================================================
    -- capacityMultiplier / effectiveCapacity
    -- =====================================================================
    {
        name = "capacityMultiplier: 1.0 at level 0",
        test = function()
            assertEqual(Upgrades.capacityMultiplier(0), 1.0, "no bonus at L0")
        end,
    },
    {
        name = "capacityMultiplier: 1.5 at level 5 (max capacity)",
        test = function()
            assertEqual(Upgrades.capacityMultiplier(5), 1.5, "+50% at L5")
        end,
    },
    {
        name = "effectiveCapacity: 250000 -> 375000 at capacity L5",
        test = function()
            assertEqual(Upgrades.effectiveCapacity(250000, 5), 375000, "250k * 1.5 = 375k")
        end,
    },

    -- =====================================================================
    -- powerConsumptionMultiplier / effectivePowerConsumption
    -- =====================================================================
    {
        name = "powerConsumptionMultiplier: 1.0 at level 0",
        test = function()
            assertEqual(Upgrades.powerConsumptionMultiplier(0), 1.0, "no bonus at L0")
        end,
    },
    {
        name = "powerConsumptionMultiplier: 0.70 at level 3 (max efficiency)",
        test = function()
            assertEqual(Upgrades.powerConsumptionMultiplier(3), 0.70, "-30% at L3")
        end,
    },
    {
        name = "effectivePowerConsumption: 5 -> 4 at efficiency L3",
        test = function()
            -- 5 * 0.70 = 3.5, rounded to 4
            assertEqual(Upgrades.effectivePowerConsumption(5, 3), 4, "5 * 0.70 = 3.5 -> 4")
        end,
    },
    {
        name = "effectivePowerConsumption: 5 -> 5 at efficiency L0",
        test = function()
            assertEqual(Upgrades.effectivePowerConsumption(5, 0), 5, "no reduction at L0")
        end,
    },

    -- =====================================================================
    -- wearMultiplier / effectiveWear
    -- =====================================================================
    {
        name = "wearMultiplier: 1.0 at level 0",
        test = function()
            assertEqual(Upgrades.wearMultiplier(0), 1.0, "no bonus at L0")
        end,
    },
    {
        name = "wearMultiplier: 0.55 at level 3 (max durability)",
        test = function()
            assertEqual(Upgrades.wearMultiplier(3), 0.55, "-45% at L3")
        end,
    },
    {
        name = "effectiveWear: 0.5 -> 0.28 at durability L3",
        test = function()
            -- 0.5 * 0.55 = 0.275, rounded to 0.28
            assertEqual(Upgrades.effectiveWear(0.5, 3), 0.28, "0.5 * 0.55 = 0.275 -> 0.28")
        end,
    },
    {
        name = "effectiveWear: 0.5 -> 0.5 at durability L0",
        test = function()
            assertEqual(Upgrades.effectiveWear(0.5, 0), 0.5, "no reduction at L0")
        end,
    },
    {
        name = "effectiveWear: 0 at durability L3 with 0 base",
        test = function()
            assertEqual(Upgrades.effectiveWear(0, 3), 0, "0 * anything = 0")
        end,
    },

    -- =====================================================================
    -- Combined upgrade effects
    -- =====================================================================
    {
        name = "Combined: max speed + max efficiency + max durability",
        test = function()
            -- Speed L5: duration 60 -> 45
            assertEqual(Upgrades.effectiveDuration(60, 5), 45, "speed L5")
            -- Efficiency L3: power 5 -> 4
            assertEqual(Upgrades.effectivePowerConsumption(5, 3), 4, "efficiency L3")
            -- Durability L3: wear 0.5 -> 0.28
            assertEqual(Upgrades.effectiveWear(0.5, 3), 0.28, "durability L3")
            -- Total cost: 5*1 + 3*2 + 3*2 = 5 + 6 + 6 = 17 > 10 budget
            -- So this combo is NOT achievable with 10 points.
        end,
    },
    {
        name = "Combined: achievable combo (speed L5 + durability L2 = 9pts)",
        test = function()
            -- Speed L5: 5pts. Durability L2: 4pts. Total: 9pts <= 10.
            local ok = Upgrades.validatePurchase({
                track = 'speed', currentLevel = 4, budgetUsed = 4,
            })
            assertTrue(ok, "speed L4 -> L5 with 4 used")
            local ok2 = Upgrades.validatePurchase({
                track = 'durability', currentLevel = 1, budgetUsed = 5,
            })
            assertTrue(ok2, "durability L1 -> L2 with 5 used")
            -- Effects: duration 60 -> 45, wear 0.5 -> 0.5*0.70 = 0.35
            assertEqual(Upgrades.effectiveDuration(60, 5), 45, "speed L5 duration")
            assertEqual(Upgrades.effectiveWear(0.5, 2), 0.35, "durability L2 wear: 0.5 * 0.70 = 0.35")
        end,
    },

    -- =====================================================================
    -- validateDowngrade (capacity downgrade validation)
    -- =====================================================================
    {
        name = "validateDowngrade: rejects unknown track",
        test = function()
            local ok, reason = Upgrades.validateDowngrade({
                track = 'unknown', currentLevel = 1, machineUsedWeight = 0, baseCapacity = 250000,
            })
            assertFalse(ok, "should reject unknown track")
            assertTrue(reason and string.find(reason, 'unknown'), "reason mentions unknown")
        end,
    },
    {
        name = "validateDowngrade: rejects at level 0",
        test = function()
            local ok, reason = Upgrades.validateDowngrade({
                track = 'speed', currentLevel = 0, machineUsedWeight = 0, baseCapacity = 250000,
            })
            assertFalse(ok, "should reject at L0")
            assertTrue(reason and string.find(reason, 'level 0'), "reason mentions level 0")
        end,
    },
    {
        name = "validateDowngrade: speed track always allowed (no stock impact)",
        test = function()
            local ok = Upgrades.validateDowngrade({
                track = 'speed', currentLevel = 3, machineUsedWeight = 999999, baseCapacity = 250000,
            })
            assertTrue(ok, "speed downgrade always allowed")
        end,
    },
    {
        name = "validateDowngrade: capacity allowed when stock fits new cap",
        test = function()
            -- Capacity L3: 250000 * 1.3 = 325000. Downgrade to L2: 250000 * 1.2 = 300000.
            -- Stock at 280000 fits within 300000.
            local ok = Upgrades.validateDowngrade({
                track = 'capacity', currentLevel = 3, machineUsedWeight = 280000, baseCapacity = 250000,
            })
            assertTrue(ok, "should allow: 280000 <= 300000")
        end,
    },
    {
        name = "validateDowngrade: capacity blocked when stock exceeds new cap",
        test = function()
            -- Capacity L3: 250000 * 1.3 = 325000. Downgrade to L2: 250000 * 1.2 = 300000.
            -- Stock at 310000 exceeds 300000.
            local ok, reason = Upgrades.validateDowngrade({
                track = 'capacity', currentLevel = 3, machineUsedWeight = 310000, baseCapacity = 250000,
            })
            assertFalse(ok, "should block: 310000 > 300000")
            assertTrue(reason and string.find(reason, 'exceeds'), "reason mentions exceeds")
            assertTrue(reason and string.find(reason, 'drain'), "reason mentions drain")
        end,
    },
    {
        name = "validateDowngrade: capacity blocked at exact boundary (stock == new cap)",
        test = function()
            -- Downgrade to L2: 250000 * 1.2 = 300000. Stock at 300000 is NOT > 300000.
            -- This is allowed (stock fits exactly).
            local ok = Upgrades.validateDowngrade({
                track = 'capacity', currentLevel = 3, machineUsedWeight = 300000, baseCapacity = 250000,
            })
            assertTrue(ok, "should allow: 300000 == 300000 (not exceeding)")
        end,
    },
    {
        name = "validateDowngrade: capacity from L1 to L0 (base cap)",
        test = function()
            -- Capacity L1: 250000 * 1.1 = 275000. Downgrade to L0: 250000 * 1.0 = 250000.
            -- Stock at 260000 exceeds 250000.
            local ok, reason = Upgrades.validateDowngrade({
                track = 'capacity', currentLevel = 1, machineUsedWeight = 260000, baseCapacity = 250000,
            })
            assertFalse(ok, "should block: 260000 > 250000")
            assertTrue(reason and string.find(reason, 'exceeds'), "reason mentions exceeds")
        end,
    },
    {
        name = "validateDowngrade: efficiency and durability always allowed",
        test = function()
            local ok1 = Upgrades.validateDowngrade({
                track = 'efficiency', currentLevel = 2, machineUsedWeight = 999999, baseCapacity = 250000,
            })
            assertTrue(ok1, "efficiency downgrade allowed")
            local ok2 = Upgrades.validateDowngrade({
                track = 'durability', currentLevel = 2, machineUsedWeight = 999999, baseCapacity = 250000,
            })
            assertTrue(ok2, "durability downgrade allowed")
        end,
    },
}
