-- qb-czcraft repairkit client handler
-- When the player uses a repairkit item, checks for a nearby vehicle, starts a
-- progress bar, then asks the server to validate+consume+repair. The server
-- applies the mechanical repair to the vehicle entity before sending the
-- success event; the client only plays a sound and shows a notification.

local CZCraftClient = _G.CZCraftClient

local Repairkit = {}

-- Maximum distance to look for a vehicle when the repairkit is used.
local VEHICLE_SEARCH_RADIUS = 5.0

-- Whether a repair is currently in progress (prevents duplicate triggers).
local repairInProgress = false

-- Finds the nearest vehicle entity within VEHICLE_SEARCH_RADIUS of the player ped.
-- @return number|nil vehicleEntity
-- @return number|nil vehicleNet
local function findNearbyVehicle()
    local playerPed = PlayerPedId()
    local coords = GetEntityCoords(playerPed)
    local vehicle = GetClosestVehicle(coords.x, coords.y, coords.z, VEHICLE_SEARCH_RADIUS, 0, 70)
    if not vehicle or vehicle == 0 then
        return nil, nil
    end
    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    return vehicle, netId
end

-- Applies cosmetic finishing touches to the vehicle. The mechanical repair
-- (engine, body, petrol tank, wheels, windows) is applied SERVER-SIDE before
-- the success event is sent. This function only handles dirt removal and the
-- repair sound — non-critical cosmetics that are safe to skip if the event
-- is lost.
-- @param vehicleEntity number
local function applyRepair(vehicleEntity)
    -- Remove dirt.
    SetVehicleDirtLevel(vehicleEntity, 0.0)
    -- Play the repair sound.
    PlayVehicleSound(vehicleEntity, 'REPAIR', 'CAR_STEREO_HUD_SOUNDS')
end

-- Starts the repair flow when the repairkit item is used.
local function startRepair()
    if not CZCraftClient.isReady() then
        CZCraftClient.QBCore.Functions.Notify('qb-czcraft is not ready', 'error')
        return
    end
    if not CZCraft.Config.General.features.repairkit then
        CZCraftClient.QBCore.Functions.Notify('Repairkit handler is disabled', 'error')
        return
    end
    if repairInProgress then
        CZCraftClient.QBCore.Functions.Notify('Repair already in progress', 'error')
        return
    end

    -- Find a nearby vehicle.
    local vehicleEntity, vehicleNet = findNearbyVehicle()
    if not vehicleEntity or not vehicleNet then
        CZCraftClient.QBCore.Functions.Notify('No vehicle nearby', 'error')
        return
    end

    -- Check the vehicle is not already at full health.
    local engineHealth = GetVehicleEngineHealth(vehicleEntity)
    if engineHealth >= 1000.0 then
        CZCraftClient.QBCore.Functions.Notify('Vehicle is already in good condition', 'primary')
        return
    end

    repairInProgress = true

    -- Ask the server to start the repair session.
    TriggerServerEvent('qb-czcraft:server:repairkit:start', vehicleNet)
end

-- ===========================================================================
-- Server response handlers
-- ===========================================================================

-- Server says: start the progress bar.
RegisterNetEvent('qb-czcraft:client:repairkit:progress')
AddEventHandler('qb-czcraft:client:repairkit:progress', function(data)
    if not data or not data.nonce then
        repairInProgress = false
        CZCraftClient.QBCore.Functions.Notify('Invalid repair response', 'error')
        return
    end

    local durationMs = data.durationMs or 10000

    -- Use ox_lib progress bar if available, otherwise fall back to a simple loop.
    if lib and lib.progressBar then
        lib.progressBar({
            duration = durationMs,
            label = 'Repairing vehicle...',
            useWhileDead = false,
            canCancel = true,
            disable = {
                move = true,
                car = true,
                combat = true,
            },
            anim = {
                dict = 'mini@repair',
                clip = 'fixing_a_ped',
            },
        }, function(cancelled)
            if cancelled then
                TriggerServerEvent('qb-czcraft:server:repairkit:cancel', { nonce = data.nonce })
                repairInProgress = false
                CZCraftClient.QBCore.Functions.Notify('Repair cancelled', 'primary')
            else
                TriggerServerEvent('qb-czcraft:server:repairkit:complete', { nonce = data.nonce })
            end
        end)
    else
        -- Fallback: simple progress using QBCore export.
        CreateThread(function()
            local playerPed = PlayerPedId()
            TaskStartScenarioInPlace(playerPed, 'PROP_HUMAN_BUM_BIN', 0, true)
            local elapsed = 0
            while elapsed < durationMs do
                Wait(100)
                elapsed = elapsed + 100
                if IsControlJustPressed(0, 322) then  -- ESC
                    ClearPedTasks(playerPed)
                    TriggerServerEvent('qb-czcraft:server:repairkit:cancel', { nonce = data.nonce })
                    repairInProgress = false
                    CZCraftClient.QBCore.Functions.Notify('Repair cancelled', 'primary')
                    return
                end
            end
            ClearPedTasks(playerPed)
            TriggerServerEvent('qb-czcraft:server:repairkit:complete', { nonce = data.nonce })
        end)
    end
end)

-- Server says: repair succeeded (mechanical repair already applied server-side).
-- The client only applies cosmetic finishing touches (dirt + sound).
RegisterNetEvent('qb-czcraft:client:repairkit:success')
AddEventHandler('qb-czcraft:client:repairkit:success', function(data)
    repairInProgress = false

    if not data or not data.vehicleNet then
        CZCraftClient.QBCore.Functions.Notify('Repair failed: invalid response', 'error')
        return
    end

    local vehicleEntity = NetworkGetEntityFromNetworkId(data.vehicleNet)
    if not vehicleEntity or vehicleEntity == 0 or not DoesEntityExist(vehicleEntity) then
        CZCraftClient.QBCore.Functions.Notify('Vehicle no longer exists', 'error')
        return
    end

    applyRepair(vehicleEntity)
    CZCraftClient.QBCore.Functions.Notify('Vehicle repaired', 'success')
end)

-- Server says: repair failed.
RegisterNetEvent('qb-czcraft:client:repairkit:fail')
AddEventHandler('qb-czcraft:client:repairkit:fail', function(reason)
    repairInProgress = false
    CZCraftClient.QBCore.Functions.Notify(reason or 'Repair failed', 'error')
end)

-- Hook into the repairkit usable item.
CreateThread(function()
    -- Wait for QBCore to be available.
    while not CZCraftClient.QBCore do
        Wait(100)
    end

    -- Register the useable item hook. QBCore fires QBCore:Client:UseItem.
    AddEventHandler('QBCore:Client:UseItem', function(itemName)
        if itemName ~= 'repairkit' then return end
        startRepair()
    end)
end)

CZCraftClient.Repairkit = Repairkit
return Repairkit
