-- qb-czcraft condition domain (pure)
-- Deterministic condition/wear calculations for machine cycles. No natives,
-- no SQL, no global state — all inputs are passed in. The cycle engine reads
-- these to gate cycle starts and compute immutable condition snapshots.
--
-- Condition is a 0-100 scale stored on czcraft_machines.condition. Each
-- cycle started applies wear (config.Balance.condition.wearPerCycle, reduced
-- by the durability upgrade track in checkpoint 3). A machine blocks new
-- cycles when condition drops to or below blockThreshold; active cycles
-- always finish. Maintenance restores condition by conditionRestoration and
-- consumes one cz_maintenance_kit + moneyCost via the financial adapter.
--
-- Wear is applied at cycle START (same as inputs and energy) per the
-- invariant in overview.md line 80: "O input e a energia são consumidos ao
-- iniciar ciclo." The condition_before/after snapshot is recorded on the
-- active_cycles row at start; the machine row is updated in the start
-- transaction, not on completion.

CZCraft = CZCraft or {}

local Condition = {}

-- Reads the condition config from CZCraft.Config.Balance.condition with safe
-- defaults so pure unit tests (which may not load the full config) work.
-- @return table { max, start, wearPerCycle, blockThreshold }
local function conditionConfig()
    local cfg = CZCraft.Config and CZCraft.Config.Balance and CZCraft.Config.Balance.condition
    if type(cfg) ~= 'table' then
        return { max = 100, start = 100, wearPerCycle = 0.5, blockThreshold = 20 }
    end
    return {
        max = cfg.max or 100,
        start = cfg.start or 100,
        wearPerCycle = cfg.wearPerCycle or 0.5,
        blockThreshold = cfg.blockThreshold or 20,
    }
end

-- Reads the maintenance config for restoration amount.
-- @return table { conditionRestoration }
local function maintenanceConfig()
    local cfg = CZCraft.Config and CZCraft.Config.Balance and CZCraft.Config.Balance.maintenance
    if type(cfg) ~= 'table' then
        return { conditionRestoration = 40 }
    end
    return {
        conditionRestoration = cfg.conditionRestoration or 40,
    }
end

-- Clamps a condition level to [0, max].
-- @param level number
-- @param max number
-- @return number clamped
local function clampLevel(level, max)
    if level < 0 then return 0 end
    if level > max then return max end
    return level
end

-- Determines whether a machine has enough condition to start a new cycle.
-- A cycle can start only when the current condition is above the block
-- threshold. Active cycles always finish (the block only prevents NEW
-- starts), so the threshold is checked against the pre-start level.
-- @param conditionLevel number current machine condition
-- @return boolean canStart
function Condition.canStartCycle(conditionLevel)
    local cfg = conditionConfig()
    return (conditionLevel or 0) > cfg.blockThreshold
end

-- Computes the wear for one cycle. The base wear comes from config; the
-- durability upgrade track (checkpoint 3) will reduce it via a multiplier.
-- At v0.2 the multiplier is 1.0 (no upgrades wired yet).
-- @param wearMultiplier number|nil (1.0 = no reduction; <1.0 = less wear)
-- @return number wearToApply (>= 0, rounded to 2 decimal places to match
--   the DECIMAL(5,2) column)
function Condition.computeWear(wearMultiplier)
    local cfg = conditionConfig()
    local multiplier = wearMultiplier or 1.0
    if multiplier < 0 then multiplier = 0 end
    local wear = cfg.wearPerCycle * multiplier
    -- Round to 2 decimal places (the column is DECIMAL(5,2)).
    return math.floor(wear * 100 + 0.5) / 100
end

-- Computes the condition level after applying wear for one cycle.
-- Never goes below 0.
-- @param conditionLevel number current level
-- @param wearToApply number (from computeWear)
-- @return number newLevel (clamped to [0, max])
function Condition.applyWear(conditionLevel, wearToApply)
    local cfg = conditionConfig()
    local newLevel = (conditionLevel or 0) - (wearToApply or 0)
    return clampLevel(newLevel, cfg.max)
end

-- Computes the condition level after a maintenance action.
-- Restores conditionRestoration, clamped to max.
-- @param conditionLevel number current level
-- @return number newLevel (clamped to [0, max])
-- @return number actuallyRestored (newLevel - conditionLevel, for accounting)
function Condition.applyMaintenance(conditionLevel)
    local cfg = conditionConfig()
    local mCfg = maintenanceConfig()
    local before = clampLevel(conditionLevel or 0, cfg.max)
    local after = clampLevel(before + mCfg.conditionRestoration, cfg.max)
    return after, after - before
end

-- Computes the immutable condition snapshot for a cycle start: the level
-- before the cycle and the level after wear. The "after" is applied to the
-- machine at cycle START (in the same transaction as input/power consumption)
-- — the invariant is "input and energy are consumed at cycle start." The
-- snapshot is recorded on the active_cycles row for audit; the machine row
-- is updated in the start transaction, not on completion.
-- @param conditionLevel number current machine condition
-- @param wearToApply number (from computeWear)
-- @return table { before, after, wearToApply }
function Condition.computeCycleSnapshot(conditionLevel, wearToApply)
    return {
        before = conditionLevel or 0,
        after = Condition.applyWear(conditionLevel, wearToApply),
        wearToApply = wearToApply or 0,
    }
end

-- Determines whether a machine is condition-blocked (cannot start new cycles).
-- @param conditionLevel number
-- @return boolean blocked
function Condition.isBlocked(conditionLevel)
    return not Condition.canStartCycle(conditionLevel)
end

CZCraft.Condition = Condition
return Condition
