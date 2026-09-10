-- qb-czcraft upgrades service
-- Orchestrates an upgrade purchase: validate preconditions, consume the
-- upgrade module from machine stock, debit the money cost via the financial
-- adapter, and increment the machine's upgrade level.
--
-- The financial debit happens FIRST (via the verified FinanceAdapter path).
-- Only if the debit succeeds does the service consume the item and update
-- the level. If the debit fails, nothing is consumed or changed.
--
-- Upgrade effects (speed, capacity, efficiency, durability) are applied
-- by the cycle engine at runtime via the Upgrades domain module.

CZCraft = CZCraft or {}

local UpgradesService = {}

-- Checks whether the upgrades feature is enabled.
local function upgradesFeatureEnabled()
    return CZCraft.Config and CZCraft.Config.General
        and CZCraft.Config.General.features
        and CZCraft.Config.General.features.upgrades
end

-- Maps a track name to its machine column name.
local function trackColumn(track)
    return 'upgrade_' .. track .. '_level'
end

-- Performs an upgrade purchase for one level of one track.
-- @param params table {
--   machine_uuid string,
--   track string ('speed'|'capacity'|'efficiency'|'durability'),
--   source number (player server id, for the money debit),
--   citizenid string (player citizen id, for bank statement),
-- }
-- @return table { success, reason?, newLevel?, pointsSpent? }
function UpgradesService.purchaseUpgrade(params)
    if not upgradesFeatureEnabled() then
        return { success = false, reason = 'upgrades feature disabled' }
    end

    local machine = CZCraft.MachinesRepo.load(params.machine_uuid)
    if not machine then
        return { success = false, reason = 'machine not found' }
    end
    if machine.lifecycle ~= 'INSTALLED' then
        return { success = false, reason = 'machine not installed' }
    end

    -- Read the current upgrade levels and budget.
    local currentLevel = tonumber(machine[trackColumn(params.track)]) or 0
    local budgetUsed = tonumber(machine.upgrade_budget_used) or 0

    -- Validate the purchase (pure logic).
    local canBuy, reason, cost = CZCraft.Upgrades.validatePurchase({
        track = params.track,
        currentLevel = currentLevel,
        budgetUsed = budgetUsed,
    })
    if not canBuy then
        return { success = false, reason = reason }
    end

    -- Check the upgrade module is in the machine's stock.
    local kitRow = CZCraft.StockRepo.load(params.machine_uuid, cost.item, '')
    if not kitRow or tonumber(kitRow.quantity) < cost.itemAmount then
        return { success = false, reason = 'insufficient upgrade modules in machine stock' }
    end

    -- Debit the money cost via the verified financial path.
    if cost.money > 0 then
        local upgradesCfg = CZCraft.Config.Balance.upgrades
        local account = upgradesCfg and upgradesCfg.moneyAccount or 'bank'
        local exportKey = 'czcraft:upgrade:' .. params.machine_uuid .. ':' .. params.track .. ':' .. tostring(os.time())
        local finResult = CZCraft.FinanceAdapter.applyMovement({
            export_key = exportKey,
            source_type = CZCraft.FinancialSourceType.QB_CORE,
            source_id = params.source,
            direction = CZCraft.FinancialDirection.DEBIT,
            amount = cost.money,
            account = account,
            reason = 'Upgrade purchase: ' .. params.track,
            machine_uuid = params.machine_uuid,
            citizenid = params.citizenid,
        })
        if not finResult.success then
            return { success = false, reason = finResult.reason or 'financial debit failed' }
        end
    end

    -- Money debited: consume the upgrade module.
    local kitOk = CZCraft.StockRepo.applyDelta(
        params.machine_uuid, cost.item, '',
        tonumber(kitRow.version) or 0,
        -cost.itemAmount, 0
    )
    if not kitOk then
        return { success = false, reason = 'failed to consume upgrade module (concurrent modification — retry)' }
    end

    -- Increment the upgrade level.
    local upgradeOk = CZCraft.MachinesRepo.upgradeTrack(
        params.machine_uuid, params.track, cost.points, tonumber(machine.version) or 0
    )
    if not upgradeOk then
        return { success = false, reason = 'failed to update upgrade level (concurrent modification — retry)' }
    end

    return {
        success = true,
        newLevel = currentLevel + 1,
        pointsSpent = cost.points,
    }
end

-- Performs a downgrade (removal of one upgrade level) for one track.
-- Budget points are NOT refunded (per v0.2 design). For the capacity track,
-- the downgrade is blocked if the current stock weight exceeds the new
-- (lower) effective capacity — the player must drain stock first.
--
-- @param params table {
--   machine_uuid string,
--   track string ('speed'|'capacity'|'efficiency'|'durability'),
-- }
-- @return table { success, reason?, newLevel? }
function UpgradesService.downgradeUpgrade(params)
    if not upgradesFeatureEnabled() then
        return { success = false, reason = 'upgrades feature disabled' }
    end

    local machine = CZCraft.MachinesRepo.load(params.machine_uuid)
    if not machine then
        return { success = false, reason = 'machine not found' }
    end
    if machine.lifecycle ~= 'INSTALLED' then
        return { success = false, reason = 'machine not installed' }
    end

    local currentLevel = tonumber(machine[trackColumn(params.track)]) or 0

    -- Load stock to compute used weight for the capacity check.
    local stockRows = CZCraft.StockRepo.loadAll(params.machine_uuid)
    local machineConfig = nil
    for _, cfg in ipairs(CZCraft.Config.Machines) do
        if cfg.type == machine.machine_type then machineConfig = cfg break end
    end
    local baseCapacity = machineConfig and machineConfig.stockCapacity or 0

    -- Build item weights for used-weight computation.
    local itemWeights = {}
    local items = CZCraft.QBCoreAdapter.getItems()
    for _, row in ipairs(stockRows or {}) do
        if row and row.item_name and items[row.item_name] then
            itemWeights[row.item_name] = items[row.item_name].weight or 0
        end
    end
    local usedWeight = CZCraft.Storage.computeUsedWeight(stockRows, itemWeights)

    -- Validate the downgrade (pure logic).
    local canDowngrade, reason = CZCraft.Upgrades.validateDowngrade({
        track = params.track,
        currentLevel = currentLevel,
        machineUsedWeight = usedWeight,
        baseCapacity = baseCapacity,
    })
    if not canDowngrade then
        return { success = false, reason = reason }
    end

    -- No financial refund (points are permanent). Just decrement the level.
    local ok = CZCraft.MachinesRepo.downgradeTrack(
        params.machine_uuid, params.track, tonumber(machine.version) or 0
    )
    if not ok then
        return { success = false, reason = 'failed to update upgrade level (concurrent modification — retry)' }
    end

    return {
        success = true,
        newLevel = currentLevel - 1,
    }
end

CZCraft.UpgradesService = UpgradesService
return UpgradesService
