-- qb-czcraft server NUI API
-- Registers lib.callback handlers for NUI data requests: owner overview, machine
-- details, stock, bills, recipes, and bill mutations (create/pause/resume/remove).
-- All requests validate session + ownership/access before returning data.
-- The NUI never sends recipe data — only intent + IDs (per project constraint).

CZCraft = CZCraft or {}

local NuiApi = {}

-- Maximum distance for NUI interactions (player must be near the machine).
local NUI_MAX_PROXIMITY = 5.0

-- Resolves the player's ped coordinates server-side.
local function getPedCoords(source)
    local ped = GetPlayerPed(source)
    if ped == 0 then return nil end
    local coords = GetEntityCoords(ped)
    return { x = coords.x, y = coords.y, z = coords.z }
end

-- Checks if the player has access to a machine (owner, keyholder, or ORG member).
-- @param source number
-- @param machine table machine row
-- @param playerData table
-- @return boolean hasAccess
local function hasMachineAccess(source, machine, playerData)
    if not machine or not playerData then return false end

    if machine.owner_type == CZCraft.OwnerType.PLAYER then
        if machine.owner_id == playerData.citizenid then
            return true
        end
        if machine.location_type == CZCraft.LocationType.HOUSE then
            local access = CZCraft.QbHousesAdapter.resolveHouseAccess(source, machine.location_id)
            return access.isOwner or access.isKeyholder
        end
    elseif machine.owner_type == CZCraft.OwnerType.JOB or machine.owner_type == CZCraft.OwnerType.GANG then
        local stillMember = CZCraft.Permissions.isStillOrgMember(
            { type = machine.owner_type, id = machine.owner_id }, playerData
        )
        if stillMember then
            local gradeKey
            if machine.owner_type == CZCraft.OwnerType.JOB then
                gradeKey = tostring(playerData.job.grade and playerData.job.grade.level or 0)
            else
                gradeKey = tostring(playerData.gang.grade and playerData.gang.grade.level or 0)
            end
            local granted = CZCraft.Permissions.resolveOrgPermissions(machine.owner_type, gradeKey, CZCraft.Config.Access)
            return CZCraft.Permissions.hasPermission(granted, CZCraft.Permission.VIEW)
        end
    end

    return false
end

-- Checks if the player has production permission on a machine.
-- @param source number
-- @param machine table
-- @param playerData table
-- @return boolean hasProductionAccess
local function hasProductionAccess(source, machine, playerData)
    if not machine or not playerData then return false end

    if machine.owner_type == CZCraft.OwnerType.PLAYER then
        if machine.owner_id == playerData.citizenid then
            return true
        end
        if machine.location_type == CZCraft.LocationType.HOUSE then
            local access = CZCraft.QbHousesAdapter.resolveHouseAccess(source, machine.location_id)
            return access.isOwner or access.isKeyholder
        end
    elseif machine.owner_type == CZCraft.OwnerType.JOB or machine.owner_type == CZCraft.OwnerType.GANG then
        local stillMember = CZCraft.Permissions.isStillOrgMember(
            { type = machine.owner_type, id = machine.owner_id }, playerData
        )
        if stillMember then
            local gradeKey
            if machine.owner_type == CZCraft.OwnerType.JOB then
                gradeKey = tostring(playerData.job.grade and playerData.job.grade.level or 0)
            else
                gradeKey = tostring(playerData.gang.grade and playerData.gang.grade.level or 0)
            end
            local granted = CZCraft.Permissions.resolveOrgPermissions(machine.owner_type, gradeKey, CZCraft.Config.Access)
            return CZCraft.Permissions.hasPermission(granted, CZCraft.Permission.PRODUCTION)
        end
    end

    return false
end

-- Checks if the player has manager permission on a machine (required for
-- maintenance and upgrades per v0.2 plan: "MANAGER necessário para
-- upgrade/maintenance").
-- @param source number
-- @param machine table
-- @param playerData table
-- @return boolean hasManagerAccess
local function hasManagerAccess(source, machine, playerData)
    if not machine or not playerData then return false end

    if machine.owner_type == CZCraft.OwnerType.PLAYER then
        if machine.owner_id == playerData.citizenid then
            return true
        end
        if machine.location_type == CZCraft.LocationType.HOUSE then
            local access = CZCraft.QbHousesAdapter.resolveHouseAccess(source, machine.location_id)
            return access.isOwner or access.isKeyholder
        end
    elseif machine.owner_type == CZCraft.OwnerType.JOB or machine.owner_type == CZCraft.OwnerType.GANG then
        local stillMember = CZCraft.Permissions.isStillOrgMember(
            { type = machine.owner_type, id = machine.owner_id }, playerData
        )
        if stillMember then
            local gradeKey
            if machine.owner_type == CZCraft.OwnerType.JOB then
                gradeKey = tostring(playerData.job.grade and playerData.job.grade.level or 0)
            else
                gradeKey = tostring(playerData.gang.grade and playerData.gang.grade.level or 0)
            end
            local granted = CZCraft.Permissions.resolveOrgPermissions(machine.owner_type, gradeKey, CZCraft.Config.Access)
            return CZCraft.Permissions.hasPermission(granted, CZCraft.Permission.MANAGER)
        end
    end

    return false
end

-- Validates that the player is near the machine.
-- @param source number
-- @param machine table
-- @return boolean isNear
local function isNearMachine(source, machine)
    if not machine or not machine.pos_x then return false end
    local pedCoords = getPedCoords(source)
    if not pedCoords then return false end
    local dist = CZCraft.Machines.distance3D(pedCoords.x, pedCoords.y, pedCoords.z, machine.pos_x, machine.pos_y, machine.pos_z)
    return dist <= NUI_MAX_PROXIMITY
end

-- Finds recipes available for a machine type.
-- @param machineType string
-- @return table list of recipe configs
local function recipesForMachineType(machineType)
    local result = {}
    for _, recipe in ipairs(CZCraft.Config.Recipes) do
        if recipe.machine == machineType and recipe.enabled then
            result[#result + 1] = recipe
        end
    end
    return result
end

-- ===========================================================================
-- NUI callback handlers (via lib.callback — called from client/nui.lua)
-- ===========================================================================

-- Returns the owner overview: list of machines, active bills count, stock totals.
-- @param source number
-- @return table { success, data?, reason? }
local function getOwnerOverview(source)
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        return { success = false, reason = 'qb-czcraft is not ready' }
    end
    if not CZCraft.Config.General.features.nui then
        return { success = false, reason = 'NUI is disabled' }
    end

    local playerData = CZCraft.QBCoreAdapter.getPlayerData(source)
    if not playerData then
        return { success = false, reason = 'player not found' }
    end

    -- List machines owned by this player.
    local machines = MySQL.query.await([[
        SELECT `machine_uuid`, `machine_type`, `operational_status`, `owner_type`,
               `owner_id`, `location_type`, `location_id`, `serial`
        FROM `czcraft_machines`
        WHERE `lifecycle` = 'INSTALLED'
          AND `owner_type` = 'PLAYER'
          AND `owner_id` = ?
        ORDER BY `machine_type` ASC
    ]], { playerData.citizenid }) or {}

    -- Count active bills across all owned machines.
    local billCount = 0
    if #machines > 0 then
        for _, m in ipairs(machines) do
            local row = MySQL.single.await([[
                SELECT COUNT(*) AS cnt FROM `czcraft_bills`
                WHERE `machine_uuid` = ? AND `status` IN ('PENDING', 'ACTIVE', 'PAUSED')
            ]], { m.machine_uuid })
            if row and row.cnt then
                billCount = billCount + tonumber(row.cnt)
            end
        end
    end

    -- Sum stock items across all owned machines.
    local totalStockItems = 0
    for _, m in ipairs(machines) do
        local row = MySQL.single.await([[
            SELECT COALESCE(SUM(`quantity`), 0) AS total FROM `czcraft_machine_stock`
            WHERE `machine_uuid` = ?
        ]], { m.machine_uuid })
        if row and row.total then
            totalStockItems = totalStockItems + tonumber(row.total)
        end
    end

    return {
        success = true,
        data = {
            machines = machines,
            totalMachines = #machines,
            activeBills = billCount,
            totalStockItems = totalStockItems,
        },
    }
end

-- Returns machine details for the NUI dashboard.
-- @param source number
-- @param params table { machineUuid }
-- @return table { success, data?, reason? }
local function getMachineData(source, params)
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        return { success = false, reason = 'qb-czcraft is not ready' }
    end
    if not CZCraft.Config.General.features.nui then
        return { success = false, reason = 'NUI is disabled' }
    end
    if type(params) ~= 'table' or type(params.machineUuid) ~= 'string' then
        return { success = false, reason = 'machineUuid required' }
    end

    local playerData = CZCraft.QBCoreAdapter.getPlayerData(source)
    if not playerData then
        return { success = false, reason = 'player not found' }
    end

    local machine = CZCraft.MachinesRepo.load(params.machineUuid)
    if not machine then
        return { success = false, reason = 'machine not found' }
    end

    if not hasMachineAccess(source, machine, playerData) then
        return { success = false, reason = 'no access to this machine' }
    end

    return {
        success = true,
        data = {
            machineUuid = machine.machine_uuid,
            machineType = machine.machine_type,
            serial = machine.serial,
            operationalStatus = machine.operational_status,
            blockedReason = machine.blocked_reason,
            blockedDetail = machine.blocked_detail,
            stockCapacity = tonumber(machine.stock_capacity) or 0,
            usedWeight = tonumber(machine.used_weight) or 0,
            reservedWeight = tonumber(machine.reserved_weight) or 0,
            activeBillId = machine.active_bill_id,
            activeCycleId = machine.active_cycle_id,
            nextDueAt = machine.next_due_at and tostring(machine.next_due_at) or nil,
            ownerType = machine.owner_type,
            ownerId = machine.owner_id,
            locationType = machine.location_type,
            locationId = machine.location_id,
            version = tonumber(machine.version) or 0,
            condition = tonumber(machine.condition),
            powerLevel = tonumber(machine.power_level),
            upgradeSpeedLevel = tonumber(machine.upgrade_speed_level) or 0,
            upgradeCapacityLevel = tonumber(machine.upgrade_capacity_level) or 0,
            upgradeEfficiencyLevel = tonumber(machine.upgrade_efficiency_level) or 0,
            upgradeDurabilityLevel = tonumber(machine.upgrade_durability_level) or 0,
            upgradeBudgetUsed = tonumber(machine.upgrade_budget_used) or 0,
        },
    }
end

-- Returns stock rows for a machine.
-- @param source number
-- @param params table { machineUuid }
-- @return table { success, data?, reason? }
local function getStock(source, params)
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        return { success = false, reason = 'qb-czcraft is not ready' }
    end
    if type(params) ~= 'table' or type(params.machineUuid) ~= 'string' then
        return { success = false, reason = 'machineUuid required' }
    end

    local playerData = CZCraft.QBCoreAdapter.getPlayerData(source)
    if not playerData then
        return { success = false, reason = 'player not found' }
    end

    local machine = CZCraft.MachinesRepo.load(params.machineUuid)
    if not machine then
        return { success = false, reason = 'machine not found' }
    end

    if not hasMachineAccess(source, machine, playerData) then
        return { success = false, reason = 'no access to this machine' }
    end

    local rows = CZCraft.StockRepo.loadAll(params.machineUuid)
    local stock = {}
    for _, row in ipairs(rows) do
        stock[#stock + 1] = {
            itemName = row.item_name,
            metadataKey = row.metadata_key,
            quantity = tonumber(row.quantity) or 0,
            reservedQuantity = tonumber(row.reserved_quantity) or 0,
            standardUnitCost = tonumber(row.standard_unit_cost) or 0,
            version = tonumber(row.version) or 0,
        }
    end

    return { success = true, data = stock }
end

-- Returns bills for a machine.
-- @param source number
-- @param params table { machineUuid }
-- @return table { success, data?, reason? }
local function getBills(source, params)
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        return { success = false, reason = 'qb-czcraft is not ready' }
    end
    if type(params) ~= 'table' or type(params.machineUuid) ~= 'string' then
        return { success = false, reason = 'machineUuid required' }
    end

    local playerData = CZCraft.QBCoreAdapter.getPlayerData(source)
    if not playerData then
        return { success = false, reason = 'player not found' }
    end

    local machine = CZCraft.MachinesRepo.load(params.machineUuid)
    if not machine then
        return { success = false, reason = 'machine not found' }
    end

    if not hasMachineAccess(source, machine, playerData) then
        return { success = false, reason = 'no access to this machine' }
    end

    local rows = CZCraft.BillsRepo.listForMachine(params.machineUuid)
    local bills = {}
    for _, row in ipairs(rows) do
        bills[#bills + 1] = {
            billId = row.bill_id,
            machineUuid = row.machine_uuid,
            recipeId = row.recipe_id,
            mode = row.mode,
            primaryOutput = row.primary_output,
            targetQuantity = tonumber(row.target_quantity) or 0,
            producedQuantity = tonumber(row.produced_quantity) or 0,
            enabled = row.enabled == 1 or row.enabled == true,
            status = row.status,
            blockReason = row.block_reason,
            priority = row.priority,
            version = tonumber(row.version) or 0,
        }
    end

    return { success = true, data = bills }
end

-- Returns available recipes for a machine type.
-- @param source number
-- @param params table { machineUuid }
-- @return table { success, data?, reason? }
local function getRecipes(source, params)
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        return { success = false, reason = 'qb-czcraft is not ready' }
    end
    if type(params) ~= 'table' or type(params.machineUuid) ~= 'string' then
        return { success = false, reason = 'machineUuid required' }
    end

    local playerData = CZCraft.QBCoreAdapter.getPlayerData(source)
    if not playerData then
        return { success = false, reason = 'player not found' }
    end

    local machine = CZCraft.MachinesRepo.load(params.machineUuid)
    if not machine then
        return { success = false, reason = 'machine not found' }
    end

    if not hasMachineAccess(source, machine, playerData) then
        return { success = false, reason = 'no access to this machine' }
    end

    local recipes = recipesForMachineType(machine.machine_type)
    return { success = true, data = recipes }
end

-- Creates a new bill.
-- @param source number
-- @param params table { machineUuid, recipeId, mode, targetQuantity }
-- @return table { success, reason? }
local function createBill(source, params)
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        return { success = false, reason = 'qb-czcraft is not ready' }
    end
    if not CZCraft.Config.General.features.bills then
        return { success = false, reason = 'bills are disabled' }
    end
    if type(params) ~= 'table' then
        return { success = false, reason = 'params required' }
    end
    if type(params.machineUuid) ~= 'string' then
        return { success = false, reason = 'machineUuid required' }
    end
    if type(params.recipeId) ~= 'string' then
        return { success = false, reason = 'recipeId required' }
    end
    if params.mode ~= 'PRODUCE_X' and params.mode ~= 'MAINTAIN_X' then
        return { success = false, reason = 'mode must be PRODUCE_X or MAINTAIN_X' }
    end
    local targetQuantity = tonumber(params.targetQuantity)
    if not targetQuantity or targetQuantity <= 0 or targetQuantity ~= math.floor(targetQuantity) then
        return { success = false, reason = 'targetQuantity must be a positive integer' }
    end

    local playerData = CZCraft.QBCoreAdapter.getPlayerData(source)
    if not playerData then
        return { success = false, reason = 'player not found' }
    end

    local machine = CZCraft.MachinesRepo.load(params.machineUuid)
    if not machine then
        return { success = false, reason = 'machine not found' }
    end

    if not hasProductionAccess(source, machine, playerData) then
        return { success = false, reason = 'no production permission on this machine' }
    end

    if not isNearMachine(source, machine) then
        return { success = false, reason = 'too far from the machine' }
    end

    -- Find the recipe config.
    local recipe = nil
    for _, r in ipairs(CZCraft.Config.Recipes) do
        if r.id == params.recipeId and r.machine == machine.machine_type then
            recipe = r
            break
        end
    end
    if not recipe then
        return { success = false, reason = 'recipe not found for this machine type' }
    end
    if not recipe.enabled then
        return { success = false, reason = 'recipe is disabled' }
    end

    -- Check bill count limit.
    local activeCount = CZCraft.BillsRepo.countActiveForMachine(params.machineUuid)
    if activeCount >= (CZCraft.Config.General.maxBillsPerMachine or 5) then
        return { success = false, reason = 'max bills per machine reached' }
    end

    -- Validate PRODUCE_X target is a multiple of batch output.
    if params.mode == 'PRODUCE_X' then
        local batchOutput = 0
        for _, out in ipairs(recipe.outputs) do
            if out.item == recipe.primaryOutput then
                batchOutput = out.amount
                break
            end
        end
        if batchOutput > 0 and targetQuantity % batchOutput ~= 0 then
            return { success = false, reason = 'target must be a multiple of ' .. batchOutput }
        end
    end

    -- Generate a bill UUID.
    local billId = string.gsub('xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx', '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)

    local ok, err = CZCraft.BillsRepo.create({
        bill_id = billId,
        machine_uuid = params.machineUuid,
        recipe_id = params.recipeId,
        mode = params.mode,
        primary_output = recipe.primaryOutput,
        target_quantity = targetQuantity,
        priority = 'NORMAL',
        created_by_type = 'PLAYER',
        created_by_id = playerData.citizenid,
    })

    if not ok then
        return { success = false, reason = err or 'failed to create bill' }
    end

    -- Wake the scheduler for this machine.
    TriggerEvent('qb-czcraft:internal:wake', params.machineUuid)

    return { success = true }
end

-- Pauses a bill.
-- @param source number
-- @param params table { machineUuid, billId, version }
-- @return table { success, reason? }
local function pauseBill(source, params)
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        return { success = false, reason = 'qb-czcraft is not ready' }
    end
    if type(params) ~= 'table' or type(params.billId) ~= 'string' then
        return { success = false, reason = 'billId required' }
    end

    local playerData = CZCraft.QBCoreAdapter.getPlayerData(source)
    if not playerData then
        return { success = false, reason = 'player not found' }
    end

    local bill = CZCraft.BillsRepo.load(params.billId)
    if not bill then
        return { success = false, reason = 'bill not found' }
    end

    local machine = CZCraft.MachinesRepo.load(bill.machine_uuid)
    if not machine then
        return { success = false, reason = 'machine not found' }
    end

    if not hasProductionAccess(source, machine, playerData) then
        return { success = false, reason = 'no production permission' }
    end

    local ok, err = CZCraft.BillsRepo.pause(params.billId, tonumber(params.version) or 0)
    if not ok then
        return { success = false, reason = err or 'failed to pause bill' }
    end

    return { success = true }
end

-- Resumes a bill.
local function resumeBill(source, params)
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        return { success = false, reason = 'qb-czcraft is not ready' }
    end
    if type(params) ~= 'table' or type(params.billId) ~= 'string' then
        return { success = false, reason = 'billId required' }
    end

    local playerData = CZCraft.QBCoreAdapter.getPlayerData(source)
    if not playerData then
        return { success = false, reason = 'player not found' }
    end

    local bill = CZCraft.BillsRepo.load(params.billId)
    if not bill then
        return { success = false, reason = 'bill not found' }
    end

    local machine = CZCraft.MachinesRepo.load(bill.machine_uuid)
    if not machine then
        return { success = false, reason = 'machine not found' }
    end

    if not hasProductionAccess(source, machine, playerData) then
        return { success = false, reason = 'no production permission' }
    end

    local ok, err = CZCraft.BillsRepo.resume(params.billId, tonumber(params.version) or 0)
    if not ok then
        return { success = false, reason = err or 'failed to resume bill' }
    end

    TriggerEvent('qb-czcraft:internal:wake', bill.machine_uuid)
    return { success = true }
end

-- Removes a bill.
local function removeBill(source, params)
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        return { success = false, reason = 'qb-czcraft is not ready' }
    end
    if type(params) ~= 'table' or type(params.billId) ~= 'string' then
        return { success = false, reason = 'billId required' }
    end

    local playerData = CZCraft.QBCoreAdapter.getPlayerData(source)
    if not playerData then
        return { success = false, reason = 'player not found' }
    end

    local bill = CZCraft.BillsRepo.load(params.billId)
    if not bill then
        return { success = false, reason = 'bill not found' }
    end

    local machine = CZCraft.MachinesRepo.load(bill.machine_uuid)
    if not machine then
        return { success = false, reason = 'machine not found' }
    end

    if not hasProductionAccess(source, machine, playerData) then
        return { success = false, reason = 'no production permission' }
    end

    local ok, err = CZCraft.BillsRepo.remove(params.billId, tonumber(params.version) or 0)
    if not ok then
        return { success = false, reason = err or 'failed to remove bill' }
    end

    return { success = true }
end

-- Performs maintenance on a machine (restore condition, consume kit, debit $200).
-- Requires MANAGER permission per v0.2 plan.
-- @param source number
-- @param params table { machineUuid }
-- @return table { success, reason?, conditionBefore?, conditionAfter?, restored? }
local function performMaintenance(source, params)
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        return { success = false, reason = 'qb-czcraft is not ready' }
    end
    if type(params) ~= 'table' or type(params.machineUuid) ~= 'string' then
        return { success = false, reason = 'machineUuid required' }
    end

    local playerData = CZCraft.QBCoreAdapter.getPlayerData(source)
    if not playerData then
        return { success = false, reason = 'player not found' }
    end

    local machine = CZCraft.MachinesRepo.load(params.machineUuid)
    if not machine then
        return { success = false, reason = 'machine not found' }
    end

    if not hasManagerAccess(source, machine, playerData) then
        return { success = false, reason = 'no manager permission on this machine' }
    end

    if not isNearMachine(source, machine) then
        return { success = false, reason = 'too far from the machine' }
    end

    return CZCraft.MaintenanceService.performMaintenance({
        machine_uuid = params.machineUuid,
        source = source,
        citizenid = playerData.citizenid,
    })
end

-- Purchases one level of an upgrade track for a machine.
-- Requires MANAGER permission per v0.2 plan.
-- @param source number
-- @param params table { machineUuid, track }
-- @return table { success, reason?, newLevel?, pointsSpent? }
local function purchaseUpgrade(source, params)
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        return { success = false, reason = 'qb-czcraft is not ready' }
    end
    if type(params) ~= 'table' or type(params.machineUuid) ~= 'string' then
        return { success = false, reason = 'machineUuid required' }
    end
    if type(params.track) ~= 'string' then
        return { success = false, reason = 'track required' }
    end

    local playerData = CZCraft.QBCoreAdapter.getPlayerData(source)
    if not playerData then
        return { success = false, reason = 'player not found' }
    end

    local machine = CZCraft.MachinesRepo.load(params.machineUuid)
    if not machine then
        return { success = false, reason = 'machine not found' }
    end

    if not hasManagerAccess(source, machine, playerData) then
        return { success = false, reason = 'no manager permission on this machine' }
    end

    if not isNearMachine(source, machine) then
        return { success = false, reason = 'too far from the machine' }
    end

    return CZCraft.UpgradesService.purchaseUpgrade({
        machine_uuid = params.machineUuid,
        track = params.track,
        source = source,
        citizenid = playerData.citizenid,
    })
end

-- Downgrades (removes) one level of an upgrade track for a machine.
-- Requires MANAGER permission per v0.2 plan. Budget points are NOT refunded.
-- @param source number
-- @param params table { machineUuid, track }
-- @return table { success, reason?, newLevel? }
local function downgradeUpgrade(source, params)
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        return { success = false, reason = 'qb-czcraft is not ready' }
    end
    if type(params) ~= 'table' or type(params.machineUuid) ~= 'string' then
        return { success = false, reason = 'machineUuid required' }
    end
    if type(params.track) ~= 'string' then
        return { success = false, reason = 'track required' }
    end

    local playerData = CZCraft.QBCoreAdapter.getPlayerData(source)
    if not playerData then
        return { success = false, reason = 'player not found' }
    end

    local machine = CZCraft.MachinesRepo.load(params.machineUuid)
    if not machine then
        return { success = false, reason = 'machine not found' }
    end

    if not hasManagerAccess(source, machine, playerData) then
        return { success = false, reason = 'no manager permission on this machine' }
    end

    if not isNearMachine(source, machine) then
        return { success = false, reason = 'too far from the machine' }
    end

    return CZCraft.UpgradesService.downgradeUpgrade({
        machine_uuid = params.machineUuid,
        track = params.track,
    })
end

-- Register all lib.callback handlers.
lib.callback.register('qb-czcraft:server:nui:getOwnerOverview', getOwnerOverview)
lib.callback.register('qb-czcraft:server:nui:getMachineData', getMachineData)
lib.callback.register('qb-czcraft:server:nui:getStock', getStock)
lib.callback.register('qb-czcraft:server:nui:getBills', getBills)
lib.callback.register('qb-czcraft:server:nui:getRecipes', getRecipes)
lib.callback.register('qb-czcraft:server:nui:createBill', createBill)
lib.callback.register('qb-czcraft:server:nui:pauseBill', pauseBill)
lib.callback.register('qb-czcraft:server:nui:resumeBill', resumeBill)
lib.callback.register('qb-czcraft:server:nui:removeBill', removeBill)
lib.callback.register('qb-czcraft:server:nui:performMaintenance', performMaintenance)
lib.callback.register('qb-czcraft:server:nui:purchaseUpgrade', purchaseUpgrade)
lib.callback.register('qb-czcraft:server:nui:downgradeUpgrade', downgradeUpgrade)

NuiApi.getOwnerOverview = getOwnerOverview
NuiApi.getMachineData = getMachineData
NuiApi.getStock = getStock
NuiApi.getBills = getBills
NuiApi.getRecipes = getRecipes
NuiApi.createBill = createBill
NuiApi.pauseBill = pauseBill
NuiApi.resumeBill = resumeBill
NuiApi.removeBill = removeBill
NuiApi.performMaintenance = performMaintenance
NuiApi.purchaseUpgrade = purchaseUpgrade
NuiApi.downgradeUpgrade = downgradeUpgrade

CZCraft.NuiApi = NuiApi
return NuiApi
