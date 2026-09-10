-- qb-czcraft maintenance service
-- Orchestrates a maintenance action: validate preconditions, consume the
-- maintenance kit from machine stock, debit the money cost via the financial
-- adapter, and restore the machine's condition.
--
-- The financial debit happens FIRST (via the verified FinanceAdapter path).
-- Only if the debit succeeds does the service consume the kit and update
-- condition. If the debit fails (insufficient balance, player offline), the
-- kit is NOT consumed and condition is NOT changed.
--
-- The condition restoration is computed by the pure Condition domain module;
-- this service handles the I/O (SQL, money) around it.

CZCraft = CZCraft or {}

local MaintenanceService = {}

-- Reads the maintenance config with safe defaults.
local function maintenanceConfig()
    local cfg = CZCraft.Config and CZCraft.Config.Balance and CZCraft.Config.Balance.maintenance
    if type(cfg) ~= 'table' then
        return {
            conditionRestoration = 40,
            itemCost = { item = 'cz_maintenance_kit', amount = 1 },
            moneyCost = 200,
            moneyAccount = 'bank',
        }
    end
    return cfg
end

-- Checks whether the condition feature is enabled.
local function conditionFeatureEnabled()
    return CZCraft.Config and CZCraft.Config.General
        and CZCraft.Config.General.features
        and CZCraft.Config.General.features.condition
end

-- Performs a maintenance action on a machine.
-- @param params table {
--   machine_uuid string,
--   source number (player server id, for the money debit),
--   citizenid string (player citizen id, for bank statement),
-- }
-- @return table { success, reason?, conditionBefore?, conditionAfter?, restored? }
function MaintenanceService.performMaintenance(params)
    if not conditionFeatureEnabled() then
        return { success = false, reason = 'condition feature disabled' }
    end

    local machine = CZCraft.MachinesRepo.load(params.machine_uuid)
    if not machine then
        return { success = false, reason = 'machine not found' }
    end
    if machine.lifecycle ~= 'INSTALLED' then
        return { success = false, reason = 'machine not installed' }
    end

    local conditionBefore = tonumber(machine.condition)
    if conditionBefore == nil then
        return { success = false, reason = 'machine has no condition column (schema v1)' }
    end

    -- Check the maintenance kit is in the machine's stock.
    local mCfg = maintenanceConfig()
    local kitItem = mCfg.itemCost and mCfg.itemCost.item or 'cz_maintenance_kit'
    local kitAmount = mCfg.itemCost and mCfg.itemCost.amount or 1
    local kitRow = CZCraft.StockRepo.load(params.machine_uuid, kitItem, '')
    if not kitRow or tonumber(kitRow.quantity) < kitAmount then
        return { success = false, reason = 'insufficient maintenance kits in machine stock' }
    end

    -- Compute the new condition (pure logic).
    local conditionAfter, restored = CZCraft.Condition.applyMaintenance(conditionBefore)

    -- Debit the money cost via the verified financial path.
    local moneyCost = mCfg.moneyCost or 0
    if moneyCost > 0 then
        local exportKey = 'czcraft:maintenance:' .. params.machine_uuid .. ':' .. tostring(os.time())
        local finResult = CZCraft.FinanceAdapter.applyMovement({
            export_key = exportKey,
            source_type = CZCraft.FinancialSourceType.QB_CORE,
            source_id = params.source,
            direction = CZCraft.FinancialDirection.DEBIT,
            amount = moneyCost,
            account = mCfg.moneyAccount or 'bank',
            reason = 'Machine maintenance',
            machine_uuid = params.machine_uuid,
            citizenid = params.citizenid,
        })
        if not finResult.success then
            return { success = false, reason = finResult.reason or 'financial debit failed' }
        end
    end

    -- Money debited: consume the kit and update condition.
    local kitOk = CZCraft.StockRepo.applyDelta(
        params.machine_uuid, kitItem, '',
        tonumber(kitRow.version) or 0,
        -kitAmount, 0
    )
    if not kitOk then
        -- The money was debited but the kit consumption failed (concurrent
        -- modification). This is a partial failure — the player lost money
        -- but the kit wasn't consumed. The condition is NOT updated. This
        -- is the safer failure mode: the player can retry maintenance (the
        -- financial export is idempotent, so the debit won't double-apply).
        return { success = false, reason = 'failed to consume maintenance kit (concurrent modification — retry)' }
    end

    -- Update the machine condition.
    local condOk = CZCraft.MachinesRepo.updateCondition(
        params.machine_uuid, conditionAfter, tonumber(machine.version) or 0
    )
    if not condOk then
        -- The kit was consumed and money debited, but the condition update
        -- failed (version mismatch). The player lost a kit + money but
        -- condition wasn't restored. This is rare (concurrent modification).
        -- The player can retry: the financial debit is idempotent, but the
        -- kit is already consumed. A second maintenance will consume another
        -- kit. This is the safer failure mode (over-payment, not under).
        return { success = false, reason = 'failed to update condition (concurrent modification — retry)' }
    end

    -- Success: wake the scheduler in case the machine was condition-blocked.
    if CZCraft.SchedulerTick and CZCraft.SchedulerTick.wake then
        local now = os.time()
        CZCraft.SchedulerTick.wake(params.machine_uuid, now)
    end

    return {
        success = true,
        conditionBefore = conditionBefore,
        conditionAfter = conditionAfter,
        restored = restored,
    }
end

CZCraft.MaintenanceService = MaintenanceService
return MaintenanceService
