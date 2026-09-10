-- qb-czcraft power domain (pure)
-- Deterministic power-level calculations for machine cycles. No natives, no
-- SQL, no global state — all inputs are passed in. The cycle engine reads
-- these to gate cycle starts and compute immutable power snapshots.
--
-- Power is a 0-100 scale stored on czcraft_machines.power_level. Each completed
-- cycle consumes config.Balance.power.consumptionPerCycle (reduced by the
-- efficiency upgrade track in checkpoint 3). A machine blocks new cycles when
-- power drops below config.Balance.power.blockThreshold; active cycles always
-- finish. Inserting a power cell recharges by config.Balance.power.cellCharge.

CZCraft = CZCraft or {}

local Power = {}

-- Reads the power config from CZCraft.Config.Balance.power with safe defaults
-- so pure unit tests (which may not load the full config) still work.
-- @return table { capacity, start, consumptionPerCycle, blockThreshold, cellCharge }
local function powerConfig()
    local cfg = CZCraft.Config and CZCraft.Config.Balance and CZCraft.Config.Balance.power
    if type(cfg) ~= 'table' then
        return { capacity = 100, start = 100, consumptionPerCycle = 5, blockThreshold = 5, cellCharge = 50 }
    end
    return {
        capacity = cfg.capacity or 100,
        start = cfg.start or 100,
        consumptionPerCycle = cfg.consumptionPerCycle or 5,
        blockThreshold = cfg.blockThreshold or 5,
        cellCharge = cfg.cellCharge or 50,
    }
end

-- Clamps a power level to [0, capacity].
-- @param level number
-- @param capacity number
-- @return number clamped
local function clampLevel(level, capacity)
    if level < 0 then return 0 end
    if level > capacity then return capacity end
    return level
end

-- Determines whether a machine has enough power to start a new cycle.
-- A cycle can start only when the current power level is at or above the
-- block threshold. Active cycles always finish (the block only prevents NEW
-- starts), so the threshold is checked against the pre-start level.
-- @param powerLevel number current machine power_level
-- @return boolean canStart
function Power.canStartCycle(powerLevel)
    local cfg = powerConfig()
    return (powerLevel or 0) >= cfg.blockThreshold
end

-- Computes the power to consume for one cycle. The base consumption comes
-- from config; the efficiency upgrade track (checkpoint 3) will reduce it via
-- a multiplier. At v0.2 the multiplier is 1.0 (no upgrades wired yet).
-- @param efficiencyMultiplier number|nil (1.0 = no reduction; <1.0 = less consumption)
-- @return number powerToConsume (>= 0, integer-rounded to match the SMALLINT column)
function Power.computePowerConsumption(efficiencyMultiplier)
    local cfg = powerConfig()
    local multiplier = efficiencyMultiplier or 1.0
    if multiplier < 0 then multiplier = 0 end
    local consumed = cfg.consumptionPerCycle * multiplier
    -- Round to nearest integer (the column is SMALLINT UNSIGNED). Round half
    -- up so a 0.5 result consumes 1, not 0 (avoids free cycles from rounding).
    return math.floor(consumed + 0.5)
end

-- Computes the power level after consuming one cycle's worth of energy.
-- Never goes below 0.
-- @param powerLevel number current level
-- @param powerToConsume number (from computePowerConsumption)
-- @return number newLevel (clamped to [0, capacity])
function Power.applyConsumption(powerLevel, powerToConsume)
    local cfg = powerConfig()
    local newLevel = (powerLevel or 0) - (powerToConsume or 0)
    return clampLevel(newLevel, cfg.capacity)
end

-- Computes the power level after inserting one power cell.
-- Clamps to capacity (no overflow).
-- @param powerLevel number current level
-- @return number newLevel (clamped to [0, capacity])
-- @return number actuallyAdded (newLevel - powerLevel, for accounting)
function Power.applyRecharge(powerLevel)
    local cfg = powerConfig()
    local before = clampLevel(powerLevel or 0, cfg.capacity)
    local after = clampLevel(before + cfg.cellCharge, cfg.capacity)
    return after, after - before
end

-- Computes the immutable power snapshot for a cycle start: the level before
-- the cycle and the level after consumption. The "after" is applied to the
-- machine at cycle START (in the same transaction as input consumption) —
-- the invariant is "input and energy are consumed at cycle start" (overview.md
-- line 80). The snapshot is recorded on the active_cycles row for audit; the
-- machine row is updated in the start transaction, not on completion.
-- @param powerLevel number current machine power_level
-- @param powerToConsume number (from computePowerConsumption)
-- @return table { before, after, powerToConsume }
function Power.computeCycleSnapshot(powerLevel, powerToConsume)
    return {
        before = powerLevel or 0,
        after = Power.applyConsumption(powerLevel, powerToConsume),
        powerToConsume = powerToConsume or 0,
    }
end

-- Determines whether a machine is power-blocked (cannot start new cycles).
-- @param powerLevel number
-- @return boolean blocked
function Power.isBlocked(powerLevel)
    return not Power.canStartCycle(powerLevel)
end

CZCraft.Power = Power
return Power
