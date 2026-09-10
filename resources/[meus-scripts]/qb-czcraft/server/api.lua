-- qb-czcraft server api
-- Registers lib.callback handlers for placement/pickup and wires the domain
-- services to adapters + repositories. Validates session, proximity, and rate
-- limit; delegates pure validation to the domain; runs the idempotent saga
-- (inventory mutation via ApplyIdempotentBatch + machine record commit).
--
-- No recipe/state data is accepted from the client — only intent + IDs +
-- transform + item slot + owner context.

CZCraft = CZCraft or {}

local Api = {}

-- Maximum distance (meters) the machine transform may be from the player ped.
local MAX_PROXIMITY = 5.0

-- Builds a deterministic operation key for placement.
local function placementOperationKey(citizenid, itemName, slot)
    return 'placement:' .. tostring(citizenid) .. ':' .. tostring(itemName) .. ':' .. tostring(slot)
end

-- Builds a deterministic operation key for pickup.
local function pickupOperationKey(citizenid, machineUuid)
    return 'pickup:' .. tostring(citizenid) .. ':' .. tostring(machineUuid)
end

-- Builds a stable payload hash placeholder. The full SHA-256 is computed in
-- SQL; here we build a canonical string the journal can compare.
local function payloadHash(parts)
    return table.concat(parts, '|')
end

-- Resolves the player's ped coordinates server-side.
local function getPedCoords(source)
    local ped = GetPlayerPed(source)
    if ped == 0 then return nil end
    local coords = GetEntityCoords(ped)
    return { x = coords.x, y = coords.y, z = coords.z }
end

-- Resolves the machine item from the player's inventory slot.
-- @param playerData table
-- @param slot number
-- @return table|nil item
local function getMachineItemAtSlot(playerData, slot)
    if not playerData or not playerData.items then return nil end
    return playerData.items[tonumber(slot)]
end

-- Finds the machine config for an item name.
local function findMachineConfigByItem(itemName)
    for _, machine in ipairs(CZCraft.Config.Machines) do
        if machine.item == itemName then
            return machine
        end
    end
    return nil
end

-- Finds the machine config entry by machine type.
local function findMachineConfigByType(machineType)
    for _, machine in ipairs(CZCraft.Config.Machines) do
        if machine.type == machineType then
            return machine
        end
    end
    return nil
end

-- Commit placement saga.
-- @param source number
-- @param params table { transform, itemSlot, context }
-- @return table { success, reason?, machineUuid? }
local function commitPlacement(source, params)
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        return { success = false, reason = 'qb-czcraft is not ready' }
    end
    if not CZCraft.Config.General.features.placement then
        return { success = false, reason = 'placement is disabled' }
    end
    if type(params) ~= 'table' then
        return { success = false, reason = 'params must be a table' }
    end

    local playerData = CZCraft.QBCoreAdapter.getPlayerData(source)
    if not playerData then
        return { success = false, reason = 'player not found' }
    end

    local item = getMachineItemAtSlot(playerData, params.itemSlot)
    if not item then
        return { success = false, reason = 'no item at the given slot' }
    end
    local machineConfig = findMachineConfigByItem(item.name)
    if not machineConfig then
        return { success = false, reason = 'item is not a czcraft machine: ' .. tostring(item.name) }
    end

    local pedCoords = getPedCoords(source)
    local context = params.context or 'CIVIL'
    local ownerRef, ownerReason = CZCraft.Owners.resolveOwnerRef(context, playerData)
    if not ownerRef then
        return { success = false, reason = ownerReason }
    end

    local transform = params.transform
    if type(transform) ~= 'table' then
        return { success = false, reason = 'transform required' }
    end

    local existingMachines
    local validationParams
    local validation

    if context == 'CIVIL' then
        -- HOUSE placement.
        local insideHouseId = CZCraft.QBCoreAdapter.getInsideHouse(playerData)
        if not insideHouseId then
            return { success = false, reason = 'player must be inside a house to place a HOUSE machine' }
        end
        local houseAccess = CZCraft.QbHousesAdapter.resolveHouseAccess(source, insideHouseId)
        houseAccess.insideHouseId = insideHouseId

        -- HOUSE owner is always the house owner, even when a keyholder places.
        local houseOwnerCid = CZCraft.QbHousesAdapter.getHouseOwnerCitizenid(insideHouseId)
        if houseOwnerCid then
            ownerRef = { type = CZCraft.OwnerType.PLAYER, id = houseOwnerCid }
        end

        existingMachines = CZCraft.MachinesRepo.listAtLocation(CZCraft.LocationType.HOUSE, insideHouseId)
        validationParams = {
            transform = transform,
            machineType = machineConfig.type,
            machinesConfig = CZCraft.Config.Machines,
            fixtureCaps = CZCraft.Config.General.fixtureCaps,
            houseAccess = houseAccess,
            existingMachines = existingMachines,
            pedCoords = pedCoords,
            maxProximity = MAX_PROXIMITY,
            ownerRef = ownerRef,
        }
        validation = CZCraft.Machines.validateHousePlacement(validationParams)
    else
        -- ORG placement.
        local gradeKey
        if ownerRef.type == CZCraft.OwnerType.JOB then
            gradeKey = tostring(playerData.job.grade and playerData.job.grade.level or 0)
        elseif ownerRef.type == CZCraft.OwnerType.GANG then
            gradeKey = tostring(playerData.gang.grade and playerData.gang.grade.level or 0)
        end
        local stillMember = CZCraft.Permissions.isStillOrgMember(ownerRef, playerData)
        -- The validator resolves the plot from the transform; we pass all ORG
        -- machines and the pure validator filters by the resolved plot id.
        existingMachines = CZCraft.MachinesRepo.listAllByLocationType(CZCraft.LocationType.ORG)
        validationParams = {
            transform = transform,
            machineType = machineConfig.type,
            machinesConfig = CZCraft.Config.Machines,
            plotsConfig = CZCraft.Config.Plots,
            fixtureCaps = CZCraft.Config.General.fixtureCaps,
            ownerRef = ownerRef,
            orgAccess = { gradeKey = gradeKey, isStillMember = stillMember },
            existingMachines = existingMachines,
            pedCoords = pedCoords,
            maxProximity = MAX_PROXIMITY,
        }
        validation = CZCraft.Machines.validateOrgPlacement(validationParams)
    end

    if not validation.ok then
        return { success = false, reason = validation.reason }
    end

    -- Begin the idempotent operation.
    local opKey = placementOperationKey(playerData.citizenid, item.name, params.itemSlot)
    local payload = payloadHash({
        playerData.citizenid, item.name, tostring(params.itemSlot),
        tostring(transform.pos_x), tostring(transform.pos_y), tostring(transform.pos_z), tostring(transform.heading),
        ownerRef.type, ownerRef.id, validation.location.type, validation.location.id,
    })
    local opId, isFresh = CZCraft.OperationsRepo.begin(
        opKey,
        { type = 'PLAYER', id = playerData.citizenid },
        ownerRef,
        nil,
        'PLACEMENT',
        payload
    )
    if not isFresh then
        return { success = false, reason = 'placement operation already in progress or completed' }
    end

    -- Step 1: remove the machine item via ApplyIdempotentBatch.
    local removeMutationId = opKey .. ':remove'
    local removeResult = CZCraft.QbInventoryAdapter.removeMachineItem(
        source, removeMutationId, item.name, tonumber(params.itemSlot), 'czcraft placement commit'
    )
    if not removeResult or not removeResult.success then
        local reason = (removeResult and removeResult.reason) or 'inventory removal failed'
        if removeResult and removeResult.errors then
            reason = reason .. ' (' .. json.encode(removeResult.errors) .. ')'
        end
        CZCraft.OperationsRepo.fail(opId, reason)
        return { success = false, reason = reason }
    end
    CZCraft.OperationsRepo.markStep(opId, 'INVENTORY_APPLIED', 'COMPLETED', { replayed = removeResult.replayed })

    -- Step 2: create or reactivate the machine record.
    -- If the item carries a machine_uuid from a previous pickup, reactivate
    -- the existing PACKED row (preserves condition + upgrade levels). Otherwise,
    -- create a new machine row with defaults.
    local machineUuid, createError
    local existingUuid = item.info and item.info.machine_uuid
    local packedMachine = existingUuid and CZCraft.MachinesRepo.loadPacked(existingUuid) or nil

    if packedMachine then
        local reactivateOk, reactivateErr = CZCraft.MachinesRepo.reactivateInstalled(
            existingUuid,
            {
                owner_type = ownerRef.type,
                owner_id = ownerRef.id,
                location_type = validation.location.type,
                location_id = validation.location.id,
                pos_x = transform.pos_x,
                pos_y = transform.pos_y,
                pos_z = transform.pos_z,
                heading = transform.heading,
                stock_capacity = machineConfig.stockCapacity,
            },
            tonumber(packedMachine.version) or 0
        )
        if not reactivateOk then
            createError = reactivateErr
        else
            machineUuid = existingUuid
        end
    else
        machineUuid, createError = CZCraft.MachinesRepo.createInstalled({
            machine_type = machineConfig.type,
            owner_type = ownerRef.type,
            owner_id = ownerRef.id,
            location_type = validation.location.type,
            location_id = validation.location.id,
            pos_x = transform.pos_x,
            pos_y = transform.pos_y,
            pos_z = transform.pos_z,
            heading = transform.heading,
            stock_capacity = machineConfig.stockCapacity,
        })
    end

    if not machineUuid then
        -- Compensate: restore the item via the journal.
        local restoreMutationId = opKey .. ':restore'
        CZCraft.QbInventoryAdapter.addMachineItem(
            source, restoreMutationId, item.name, item.info or {}, 'czcraft placement rollback'
        )
        CZCraft.OperationsRepo.markStep(opId, 'DOMAIN_COMMITTED', 'FAILED', { error = createError })
        CZCraft.OperationsRepo.fail(opId, 'machine record creation failed: ' .. tostring(createError))
        return { success = false, reason = 'machine record creation failed' }
    end

    CZCraft.OperationsRepo.markStep(opId, 'DOMAIN_COMMITTED', 'COMPLETED', { machineUuid = machineUuid })
    CZCraft.OperationsRepo.complete(opId)

    -- Audit.
    CZCraft.AuditRepo.append({
        actor_type = 'PLAYER', actor_id = playerData.citizenid,
        owner_type = ownerRef.type, owner_id = ownerRef.id,
        machine_uuid = machineUuid,
        action = 'PLACEMENT_COMMIT',
        next_state = {
            machine_type = machineConfig.type,
            location_type = validation.location.type,
            location_id = validation.location.id,
            transform = transform,
        },
        reason = 'czcraft placement',
    })

    -- Broadcast projection for local prop streaming.
    CZCraft.EventBus.broadcastMachineProjection({
        machine_uuid = machineUuid,
        machine_type = machineConfig.type,
        pos_x = transform.pos_x,
        pos_y = transform.pos_y,
        pos_z = transform.pos_z,
        heading = transform.heading,
    })

    return { success = true, machineUuid = machineUuid }
end

-- Pickup saga.
-- @param source number
-- @param params table { machineUuid }
-- @return table { success, reason? }
local function pickupMachine(source, params)
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        return { success = false, reason = 'qb-czcraft is not ready' }
    end
    if not CZCraft.Config.General.features.placement then
        return { success = false, reason = 'placement is disabled' }
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

    -- Permission: HOUSE owner/keyholder or ORG member with permission.
    -- For v0.1, the actor must be the owner or a house keyholder.
    local canPickup = false
    if machine.owner_type == CZCraft.OwnerType.PLAYER then
        if machine.owner_id == playerData.citizenid then
            canPickup = true
        elseif machine.location_type == CZCraft.LocationType.HOUSE then
            local access = CZCraft.QbHousesAdapter.resolveHouseAccess(source, machine.location_id)
            canPickup = access.isOwner or access.isKeyholder
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
            canPickup = CZCraft.Permissions.hasPermission(granted, CZCraft.Permission.OWNER)
        end
    end
    if not canPickup then
        return { success = false, reason = 'no permission to pick up this machine' }
    end

    -- Proximity: player must be near the machine.
    local pedCoords = getPedCoords(source)
    if pedCoords and machine.pos_x then
        local dist = CZCraft.Machines.distance3D(pedCoords.x, pedCoords.y, pedCoords.z, machine.pos_x, machine.pos_y, machine.pos_z)
        if dist > MAX_PROXIMITY then
            return { success = false, reason = 'too far from the machine' }
        end
    end

    -- Precondition: stock + reservations + bills + cycle.
    -- Stock + reservations: load via a count query (Part 3 adds the storage
    -- repo; for v0.1 placement we query directly).
    local stockSums = MySQL.single.await([[
        SELECT COALESCE(SUM(`quantity`), 0) AS total_quantity,
               COALESCE(SUM(`reserved_quantity`), 0) AS total_reserved
        FROM `czcraft_machine_stock`
        WHERE `machine_uuid` = ?
    ]], { params.machineUuid })
    local stockTotal = stockSums and tonumber(stockSums.total_quantity) or 0
    local reservedTotal = stockSums and tonumber(stockSums.total_reserved) or 0

    local activeBillsCount = 0
    local billRows = MySQL.query.await(
        "SELECT COUNT(*) AS cnt FROM `czcraft_bills` WHERE `machine_uuid` = ? AND `status` IN ('PENDING','PAUSED')",
        { params.machineUuid }
    )
    if billRows and billRows[1] then
        activeBillsCount = tonumber(billRows[1].cnt) or 0
    end

    local pickupOk, pickupReason = CZCraft.Machines.validatePickup(machine, activeBillsCount, stockTotal, reservedTotal)
    if not pickupOk then
        return { success = false, reason = pickupReason }
    end

    -- Begin the idempotent operation.
    local opKey = pickupOperationKey(playerData.citizenid, params.machineUuid)
    local opId, isFresh = CZCraft.OperationsRepo.begin(
        opKey,
        { type = 'PLAYER', id = playerData.citizenid },
        { type = machine.owner_type, id = machine.owner_id },
        params.machineUuid,
        'PICKUP',
        params.machineUuid
    )
    if not isFresh then
        return { success = false, reason = 'pickup operation already in progress or completed' }
    end

    -- Step 1: set the machine to PACKED (optimistic version).
    local packedOk, packedError = CZCraft.MachinesRepo.setPacked(params.machineUuid, machine.version)
    if not packedOk then
        CZCraft.OperationsRepo.fail(opId, 'machine pack failed: ' .. tostring(packedError))
        return { success = false, reason = 'machine state changed; retry' }
    end
    CZCraft.OperationsRepo.markStep(opId, 'DOMAIN_COMMITTED', 'COMPLETED')

    -- Step 2: return the item with serial/condition preserved.
    local machineConfig = findMachineConfigByType(machine.machine_type)
    local itemName = machineConfig and machineConfig.item
    if not itemName then
        CZCraft.OperationsRepo.fail(opId, 'machine type has no item mapping: ' .. tostring(machine.machine_type))
        return { success = false, reason = 'machine type has no item mapping' }
    end
    local itemInfo = {
        serial = machine.serial,
        condition = tonumber(machine.condition) or 100,
        machine_uuid = params.machineUuid,
        upgrade_speed_level = tonumber(machine.upgrade_speed_level) or 0,
        upgrade_capacity_level = tonumber(machine.upgrade_capacity_level) or 0,
        upgrade_efficiency_level = tonumber(machine.upgrade_efficiency_level) or 0,
        upgrade_durability_level = tonumber(machine.upgrade_durability_level) or 0,
        upgrade_budget_used = tonumber(machine.upgrade_budget_used) or 0,
    }
    local addMutationId = opKey .. ':add'
    local addResult = CZCraft.QbInventoryAdapter.addMachineItem(source, addMutationId, itemName, itemInfo, 'czcraft pickup')
    if not addResult or not addResult.success then
        -- The machine is already PACKED; the item add can be retried via the
        -- journal on recovery. Mark the step pending.
        local reason = (addResult and addResult.reason) or 'inventory add failed'
        CZCraft.OperationsRepo.markStep(opId, 'INVENTORY_APPLIED', 'FAILED', { error = reason })
        CZCraft.OperationsRepo.fail(opId, reason)
        return { success = false, reason = 'machine packed but item delivery failed; recovery will retry' }
    end
    CZCraft.OperationsRepo.markStep(opId, 'INVENTORY_APPLIED', 'COMPLETED', { replayed = addResult.replayed })
    CZCraft.OperationsRepo.complete(opId)

    -- Audit.
    CZCraft.AuditRepo.append({
        actor_type = 'PLAYER', actor_id = playerData.citizenid,
        owner_type = machine.owner_type, owner_id = machine.owner_id,
        machine_uuid = params.machineUuid,
        action = 'PICKUP',
        previous_state = { lifecycle = 'INSTALLED', location_type = machine.location_type, location_id = machine.location_id },
        next_state = { lifecycle = 'PACKED' },
        reason = 'czcraft pickup',
    })

    -- Tell clients to remove the prop.
    CZCraft.EventBus.broadcastMachineRemoval(params.machineUuid)

    return { success = true }
end

Api.commitPlacement = commitPlacement
Api.pickupMachine = pickupMachine

-- Register lib.callback handlers (ox_lib). Guarded by the readiness flag
-- inside each handler so the resource never mutates before the schema gate
-- passes.
lib.callback.register('qb-czcraft:server:commitPlacement', commitPlacement)
lib.callback.register('qb-czcraft:server:pickupMachine', pickupMachine)

-- Stream all installed machines to a newly ready client (called on client
-- resource start). Sends only projections.
lib.callback.register('qb-czcraft:server:streamAll', function(source)
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        return {}
    end
    return CZCraft.MachinesRepo.listInstalledProjection()
end)

-- House transfer hook: when a house is sold/transferred via qb-phone, the
-- caller fires this event so czcraft reassigns all machines at the house to
-- the new owner. Per decisions.md: "Imóvel transferido: Máquina, stock,
-- bills e ciclo passam ao novo dono da casa." Active cycles continue under
-- the new owner; condition-blocked machines stay blocked (new owner can
-- maintain). Stock and bills are tied to machine_uuid, not owner.
RegisterNetEvent('qb-czcraft:server:houseTransferred')
AddEventHandler('qb-czcraft:server:houseTransferred', function(houseId, newOwnerCid)
    if type(houseId) ~= 'string' or type(newOwnerCid) ~= 'string' then return end
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then return end

    local count = CZCraft.MachinesRepo.transferHouseMachines(houseId, newOwnerCid)
    if count > 0 then
        CZCraft.AuditRepo.append({
            actor_type = 'SYSTEM', actor_id = 'house-transfer',
            owner_type = 'PLAYER', owner_id = newOwnerCid,
            machine_uuid = nil,
            action = 'HOUSE_TRANSFER',
            previous_state = { house_id = houseId },
            next_state = { house_id = houseId, new_owner = newOwnerCid, machines_transferred = count },
            reason = 'qb-phone house transfer',
        })
    end
end)

CZCraft.Api = Api
return Api
