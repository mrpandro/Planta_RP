-- qb-czcraft upgrades domain (pure)
-- Validation and effect computation for the 4-track upgrade system. No
-- natives, no SQL, no global state — all inputs are passed in.
--
-- Tracks:
--   speed      — reduces cycle duration by 5% per level (max -25% at L5)
--   capacity   — increases stock capacity by 10% per level (max +50% at L5)
--   efficiency — reduces power consumption by 10% per level (max -30% at L3)
--   durability — reduces condition wear by 15% per level (max -45% at L3)
--
-- Each track has a per-level point cost. The total budget is 10 points, so
-- the player must choose 2-3 tracks (max-out costs 27 points). Points are
-- spent permanently (no recovery until checkpoint 3's downgrade).
--
-- The cycle engine reads the effect functions to apply upgrade bonuses to
-- cycle duration, power consumption, wear, and stock capacity.

CZCraft = CZCraft or {}

local Upgrades = {}

-- Reads the upgrades config from CZCraft.Config.Balance.upgrades with safe
-- defaults so pure unit tests work without the full config.
-- @return table { totalBudget, tracks = { speed, capacity, efficiency, durability } }
local function upgradesConfig()
    local cfg = CZCraft.Config and CZCraft.Config.Balance and CZCraft.Config.Balance.upgrades
    if type(cfg) ~= 'table' then
        return {
            totalBudget = 10,
            tracks = {
                speed = { maxLevel = 5, pointsPerLevel = 1, durationMultiplierPerLevel = -0.05 },
                capacity = { maxLevel = 5, pointsPerLevel = 2, capacityBonusPerLevel = 0.10 },
                efficiency = { maxLevel = 3, pointsPerLevel = 2, powerConsumptionMultiplierPerLevel = -0.10 },
                durability = { maxLevel = 3, pointsPerLevel = 2, wearMultiplierPerLevel = -0.15 },
            },
        }
    end
    return cfg
end

-- Validates a purchase attempt for one level of one track.
-- @param params table {
--   track string ('speed'|'capacity'|'efficiency'|'durability'),
--   currentLevel number (the track's current level),
--   budgetUsed number (total points already spent across all tracks),
-- }
-- @return boolean canPurchase
-- @return string|nil reason (why not, if false)
-- @return table|nil cost { points, item, itemAmount, money }
function Upgrades.validatePurchase(params)
    local cfg = upgradesConfig()
    local track = cfg.tracks and cfg.tracks[params.track]
    if not track then
        return false, 'unknown track: ' .. tostring(params.track)
    end

    local currentLevel = params.currentLevel or 0
    local maxLevel = track.maxLevel or 0
    if currentLevel >= maxLevel then
        return false, 'track at max level'
    end

    local pointsPerLevel = track.pointsPerLevel or 1
    local budgetUsed = params.budgetUsed or 0
    local totalBudget = cfg.totalBudget or 0
    if budgetUsed + pointsPerLevel > totalBudget then
        return false, 'insufficient upgrade budget'
    end

    return true, nil, {
        points = pointsPerLevel,
        item = track.itemCost and track.itemCost.item or 'cz_upgrade_module',
        itemAmount = track.itemCost and track.itemCost.amount or 1,
        money = track.moneyCost or 0,
    }
end

-- Computes the cycle duration multiplier for a given speed level.
-- @param speedLevel number
-- @return number multiplier (1.0 = no bonus; 0.75 = max speed L5)
function Upgrades.durationMultiplier(speedLevel)
    local cfg = upgradesConfig()
    local track = cfg.tracks and cfg.tracks.speed
    if not track then return 1.0 end
    local perLevel = track.durationMultiplierPerLevel or 0
    local level = speedLevel or 0
    return 1.0 + (perLevel * level)
end

-- Computes the stock capacity bonus multiplier for a given capacity level.
-- @param capacityLevel number
-- @return number multiplier (1.0 = no bonus; 1.5 = max capacity L5)
function Upgrades.capacityMultiplier(capacityLevel)
    local cfg = upgradesConfig()
    local track = cfg.tracks and cfg.tracks.capacity
    if not track then return 1.0 end
    local perLevel = track.capacityBonusPerLevel or 0
    local level = capacityLevel or 0
    return 1.0 + (perLevel * level)
end

-- Computes the power consumption multiplier for a given efficiency level.
-- @param efficiencyLevel number
-- @return number multiplier (1.0 = no bonus; 0.70 = max efficiency L3)
function Upgrades.powerConsumptionMultiplier(efficiencyLevel)
    local cfg = upgradesConfig()
    local track = cfg.tracks and cfg.tracks.efficiency
    if not track then return 1.0 end
    local perLevel = track.powerConsumptionMultiplierPerLevel or 0
    local level = efficiencyLevel or 0
    return 1.0 + (perLevel * level)
end

-- Computes the wear multiplier for a given durability level.
-- @param durabilityLevel number
-- @return number multiplier (1.0 = no bonus; 0.55 = max durability L3)
function Upgrades.wearMultiplier(durabilityLevel)
    local cfg = upgradesConfig()
    local track = cfg.tracks and cfg.tracks.durability
    if not track then return 1.0 end
    local perLevel = track.wearMultiplierPerLevel or 0
    local level = durabilityLevel or 0
    return 1.0 + (perLevel * level)
end

-- Computes the effective stock capacity given the base capacity and the
-- machine's capacity upgrade level.
-- @param baseCapacity number (from machine config)
-- @param capacityLevel number
-- @return number effectiveCapacity
function Upgrades.effectiveCapacity(baseCapacity, capacityLevel)
    return math.floor((baseCapacity or 0) * Upgrades.capacityMultiplier(capacityLevel))
end

-- Computes the effective cycle duration given the base duration and the
-- machine's speed upgrade level.
-- @param baseDuration number (seconds, from recipe)
-- @param speedLevel number
-- @return number effectiveDuration (seconds, rounded up to 1)
function Upgrades.effectiveDuration(baseDuration, speedLevel)
    local mult = Upgrades.durationMultiplier(speedLevel)
    return math.max(1, math.floor((baseDuration or 0) * mult + 0.5))
end

-- Computes the effective power consumption per cycle given the base
-- consumption and the machine's efficiency upgrade level.
-- @param baseConsumption number (from config)
-- @param efficiencyLevel number
-- @return number effectiveConsumption (rounded to nearest integer, min 0)
function Upgrades.effectivePowerConsumption(baseConsumption, efficiencyLevel)
    local mult = Upgrades.powerConsumptionMultiplier(efficiencyLevel)
    return math.max(0, math.floor((baseConsumption or 0) * mult + 0.5))
end

-- Computes the effective wear per cycle given the base wear and the
-- machine's durability upgrade level.
-- @param baseWear number (from config)
-- @param durabilityLevel number
-- @return number effectiveWear (rounded to 2 decimal places, min 0)
function Upgrades.effectiveWear(baseWear, durabilityLevel)
    local mult = Upgrades.wearMultiplier(durabilityLevel)
    local wear = (baseWear or 0) * mult
    return math.max(0, math.floor(wear * 100 + 0.5) / 100)
end

-- Validates a downgrade attempt for one level of one track.
-- The player chose "Block downgrade" when stock exceeds the new capacity:
-- if the track is 'capacity' and the current used weight exceeds the
-- effective capacity at (currentLevel - 1), the downgrade is rejected.
-- The player must drain stock below the new cap before downgrading.
--
-- For non-capacity tracks, downgrade is always allowed (no stock impact).
-- Budget points are NOT refunded (per v0.2 design: "Points are spent
-- permanently"). A future checkpoint may add partial refund.
--
-- @param params table {
--   track string,
--   currentLevel number,
--   machineUsedWeight number (current used weight in grams),
--   baseCapacity number (from machine config, in grams),
-- }
-- @return boolean canDowngrade
-- @return string|nil reason (why not, if false)
function Upgrades.validateDowngrade(params)
    local cfg = upgradesConfig()
    local track = cfg.tracks and cfg.tracks[params.track]
    if not track then
        return false, 'unknown track: ' .. tostring(params.track)
    end

    local currentLevel = params.currentLevel or 0
    if currentLevel <= 0 then
        return false, 'track already at level 0'
    end

    -- Capacity track: check that stock fits within the new (lower) cap.
    if params.track == 'capacity' then
        local newLevel = currentLevel - 1
        local newCapacity = Upgrades.effectiveCapacity(params.baseCapacity or 0, newLevel)
        local usedWeight = params.machineUsedWeight or 0
        if usedWeight > newCapacity then
            return false, 'stock exceeds new capacity: used=' .. tostring(usedWeight)
                .. 'g, new cap=' .. tostring(newCapacity) .. 'g; drain stock first'
        end
    end

    return true, nil
end

CZCraft.Upgrades = Upgrades
return Upgrades
