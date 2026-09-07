-- qb-czcraft client streaming
-- Local-only prop streaming. The server broadcasts sanitized projections
-- (machine_uuid, machine_type, transform) and the client creates/destroys
-- local props near the player. Never persists or transmits network IDs.

local CZCraftClient = _G.CZCraftClient

local Streaming = {}

-- Map of machine_uuid -> { entity, machine_type, pos_x, pos_y, pos_z, heading }
local streamedProps = {}

-- Finds the prop model for a machine type.
local function propForType(machineType)
    for _, machine in ipairs(CZCraft.Config.Machines) do
        if machine.type == machineType then
            return machine.prop
        end
    end
    return nil
end

-- Creates a local prop for a machine projection.
-- @param projection table { machine_uuid, machine_type, pos_x, pos_y, pos_z, heading }
local function createProp(projection)
    if streamedProps[projection.machine_uuid] then
        return
    end
    local propModel = propForType(projection.machine_type)
    if not propModel then return end

    local hash = GetHashKey(propModel)
    RequestModel(hash)
    local timeout = 0
    while not HasModelLoaded(hash) and timeout < 100 do
        Wait(10)
        timeout = timeout + 1
    end
    if not HasModelLoaded(hash) then return end

    local entity = CreateObject(hash, projection.pos_x, projection.pos_y, projection.pos_z, false, false, false)
    PlaceObjectOnGroundProperly(entity)
    SetEntityHeading(entity, projection.heading or 0.0)
    FreezeEntityPosition(entity, true)

    streamedProps[projection.machine_uuid] = {
        entity = entity,
        machine_type = projection.machine_type,
        pos_x = projection.pos_x,
        pos_y = projection.pos_y,
        pos_z = projection.pos_z,
        heading = projection.heading,
    }

    CZCraftClient.Interaction.registerStreamed(projection.machine_uuid, entity, projection.machine_type)
end

-- Removes a streamed prop.
-- @param machineUuid string
local function removeProp(machineUuid)
    local entry = streamedProps[machineUuid]
    if not entry then return end
    CZCraftClient.Interaction.unregisterStreamed(machineUuid)
    streamedProps[machineUuid] = nil
end

-- Server -> client: stream a machine projection.
RegisterNetEvent('qb-czcraft:client:streamMachine', function(projection)
    if type(projection) ~= 'table' or not projection.machine_uuid then return end
    createProp(projection)
end)

-- Server -> client: remove a streamed machine.
RegisterNetEvent('qb-czcraft:client:removeMachine', function(machineUuid)
    if type(machineUuid) ~= 'string' then return end
    removeProp(machineUuid)
end)

-- On resource start, request the full projection list from the server.
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    Citizen.CreateThread(function()
        -- Wait for the server to be ready.
        while not CZCraftClient.isReady() do Wait(500) end
        local projections = lib.callback.await('qb-czcraft:server:streamAll', false)
        if type(projections) == 'table' then
            for _, projection in ipairs(projections) do
                createProp(projection)
            end
        end
    end)
end)

-- Cleanup on resource stop.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for machineUuid, _ in pairs(streamedProps) do
        removeProp(machineUuid)
    end
end)

CZCraftClient.Streaming = Streaming
return Streaming
