-- qb-czcraft client interaction
-- Dual interaction adapter: qb-target when UseTarget=true, PolyZone + E text
-- otherwise. Registers machine interaction (open dashboard, pickup) on the
-- streamed local props.

local CZCraftClient = _G.CZCraftClient

local Interaction = {}

-- Map of machine_uuid -> { entity, machine_type } for currently streamed props.
local streamedMachines = {}

-- Registers a qb-target box zone on a streamed machine entity.
-- @param machineUuid string
-- @param entity number local prop entity
-- @param machineType string
local function addTarget(machineUuid, entity, machineType)
    if not exports['qb-target'] then return end
    exports['qb-target']:AddTargetEntity(entity, {
        options = {
            {
                type = 'client',
                event = 'qb-czcraft:client:openDashboard',
                icon = 'fas fa-cogs',
                label = 'Open Machine',
                machineUuid = machineUuid,
                machineType = machineType,
            },
            {
                type = 'client',
                event = 'qb-czcraft:client:pickupPrompt',
                icon = 'fas fa-hand-paper',
                label = 'Pick Up Machine',
                machineUuid = machineUuid,
            },
        },
        distance = 2.0,
    })
end

-- Handles the open-dashboard event (opens the NUI dashboard).
RegisterNetEvent('qb-czcraft:client:openDashboard', function(data)
    if not data or not data.machineUuid then return end
    CZCraftClient.NUI.open(data.machineUuid, data.machineType)
end)

-- Handles the pickup prompt event.
RegisterNetEvent('qb-czcraft:client:pickupPrompt', function(data)
    if not data or not data.machineUuid then return end
    CZCraftClient.Placement.requestPickup(data.machineUuid)
end)

-- E-key interaction for non-target mode.
CreateThread(function()
    while true do
        Wait(0)
        if not CZCraftClient.QBCore.Config.UseTarget then
            if IsControlJustPressed(0, 38) then -- E
                local playerPed = PlayerPedId()
                local coords = GetEntityCoords(playerPed)
                for machineUuid, info in pairs(streamedMachines) do
                    if info.entity and DoesEntityExist(info.entity) then
                        local entCoords = GetEntityCoords(info.entity)
                        local dist = #(coords - entCoords)
                        if dist < 2.0 then
                            -- Show a help prompt and let the player choose via
                            -- a simple input menu. For v0.1, E opens the
                            -- dashboard; pickup is via a separate command.
                            TriggerEvent('qb-czcraft:client:openDashboard', { machineUuid = machineUuid, machineType = info.machineType })
                            break
                        end
                    end
                end
            end
        else
            Wait(500)
        end
    end
end)

-- Registers a streamed machine for interaction.
-- @param machineUuid string
-- @param entity number local prop entity
-- @param machineType string
function Interaction.registerStreamed(machineUuid, entity, machineType)
    streamedMachines[machineUuid] = { entity = entity, machineType = machineType }
    if CZCraftClient.QBCore.Config.UseTarget then
        addTarget(machineUuid, entity, machineType)
    end
end

-- Removes a streamed machine from interaction tracking.
-- @param machineUuid string
function Interaction.unregisterStreamed(machineUuid)
    local info = streamedMachines[machineUuid]
    if info and info.entity and DoesEntityExist(info.entity) then
        if CZCraftClient.QBCore.Config.UseTarget and exports['qb-target'] then
            exports['qb-target']:RemoveTargetEntity(info.entity, 'Open Machine')
            exports['qb-target']:RemoveTargetEntity(info.entity, 'Pick Up Machine')
        end
        DeleteEntity(info.entity)
    end
    streamedMachines[machineUuid] = nil
end

CZCraftClient.Interaction = Interaction
return Interaction
