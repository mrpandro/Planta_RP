-- qb-czcraft repairkit server handler
-- Server-authoritative repairkit with pending-repair-ack flow.
--
-- Design (ADR-001, revised after live staging diagnostic):
-- Vehicle repair natives (SetVehicleFixed, SetVehicleEngineHealth, etc.) are
-- silent no-ops server-side in FiveM — the calls succeed but have no effect.
-- Vehicle health is a client-side concept. The original design (repair applied
-- server-side before item consumption) was based on a false premise.
--
-- The revised flow:
-- 1. Client uses repairkit → server validates entity/distance/item, creates
--    a pending-repair session (nonce + timeout).
-- 2. Client shows progress bar, sends 'complete' on finish.
-- 3. Server revalidates, marks the session as pending-apply, tells the client
--    to apply the repair client-side.
-- 4. Client applies the repair (SetVehicleFixed, etc.) and sends 'ack'.
-- 5. Server consumes the item ONLY on ack.
-- 6. If ack doesn't arrive within ACK_TIMEOUT_MS, the server clears the
--    pending state without consuming the item.
--
-- Safety property: the item is consumed only if the client confirms the
-- repair was applied. A connection drop between steps 4 and 5 leaves the
-- vehicle repaired (client-side) but the item NOT consumed — the player can
-- retry. This is a reconciled client-trust step, not the original blind
-- "cosmetic-only" version.

CZCraft = CZCraft or {}

local Repairkit = {}

-- Configuration constants.
local REPAIRKIT_ITEM = 'repairkit'
local MAX_VEHICLE_DISTANCE = 5.0  -- meters from the player ped to the vehicle
local PROGRESS_DURATION_MS = 10000  -- 10 second progress bar
local REQUEST_COOLDOWN_MS = 12000  -- cooldown between repair requests (must exceed progress)
local ACK_TIMEOUT_MS = 5000  -- max time to wait for client repair ack

-- Tracks the last repair request time per player to prevent duplicate/spam.
local lastRequestTime = {}

-- Tracks active repair sessions: source -> { vehicleNet, startedAt, nonce, stage }
-- stage: 'progress' -> waiting for complete event
--        'pending-apply' -> waiting for client ack
local activeSessions = {}

-- Generates a unique nonce for each repair session.
local function generateNonce()
    return string.gsub('xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx', '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
end

-- Validates that the player has a repairkit item in their inventory.
-- @param playerData table
-- @return boolean hasItem
local function hasRepairkit(playerData)
    if not playerData or not playerData.items then return false end
    for _, item in pairs(playerData.items) do
        if item and item.name == REPAIRKIT_ITEM and item.amount and item.amount > 0 then
            return true
        end
    end
    return false
end

-- Validates the vehicle entity: exists, is a vehicle, is not destroyed, and is
-- within MAX_VEHICLE_DISTANCE of the player ped.
-- @param source number
-- @param vehicleNet number network ID of the vehicle
-- @return boolean isValid
-- @return string|nil reason
local function validateVehicle(source, vehicleNet)
    vehicleNet = tonumber(vehicleNet)
    if not vehicleNet or vehicleNet <= 0 then
        return false, 'invalid vehicle network ID'
    end

    local vehicleEntity = NetworkGetEntityFromNetworkId(vehicleNet)
    if not vehicleEntity or vehicleEntity == 0 or not DoesEntityExist(vehicleEntity) then
        return false, 'vehicle entity not found'
    end

    -- Verify it's actually a vehicle.
    -- GetEntityType: 1=ped, 2=vehicle, 3=object.
    if GetEntityType(vehicleEntity) ~= 2 then
        return false, 'entity is not a vehicle'
    end

    -- Check the vehicle is not destroyed.
    if GetEntityHealth(vehicleEntity) <= 0 then
        return false, 'vehicle is destroyed'
    end

    -- Distance check: player ped must be near the vehicle.
    local ped = GetPlayerPed(source)
    if ped == 0 then
        return false, 'player ped not found'
    end
    local pedCoords = GetEntityCoords(ped)
    local vehCoords = GetEntityCoords(vehicleEntity)
    local dist = #(pedCoords - vehCoords)
    if dist > MAX_VEHICLE_DISTANCE then
        return false, 'too far from the vehicle'
    end

    return true, nil
end

-- ===========================================================================
-- Repair flow:
-- 1. Client uses repairkit item -> QBCore:Client:UseItem -> client/repairkit.lua
-- 2. Client checks proximity to a vehicle, starts progress bar
-- 3. Client sends 'qb-czcraft:server:repairkit:start' with vehicleNet
-- 4. Server validates entity/distance/item, creates a session with a nonce
-- 5. Client shows progress bar for PROGRESS_DURATION_MS
-- 6. Client sends 'qb-czcraft:server:repairkit:complete' with nonce
-- 7. Server revalidates, marks pending-apply, tells client to apply repair
-- 8. Client applies repair client-side, sends 'qb-czcraft:server:repairkit:ack'
-- 9. Server consumes item on ack, sends success
-- 10. If ack doesn't arrive within ACK_TIMEOUT_MS, server clears session (no consumption)
-- ===========================================================================

-- Step 1: Start — validate and create a session.
RegisterNetEvent('qb-czcraft:server:repairkit:start')
AddEventHandler('qb-czcraft:server:repairkit:start', function(vehicleNet)
    local src = source

    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'qb-czcraft is not ready')
        return
    end
    if not CZCraft.Config.General.features.repairkit then
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'repairkit handler is disabled')
        return
    end

    -- Rate limit: prevent spam/duplicate requests.
    local now = GetGameTimer()
    local lastTime = lastRequestTime[src] or 0
    if (now - lastTime) < REQUEST_COOLDOWN_MS then
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'please wait before repairing again')
        return
    end

    -- Reject if the player already has an active repair session.
    if activeSessions[src] then
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'repair already in progress')
        return
    end

    -- Validate the vehicle.
    local valid, reason = validateVehicle(src, vehicleNet)
    if not valid then
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, reason)
        return
    end

    -- Validate the player has the item.
    local playerData = CZCraft.QBCoreAdapter.getPlayerData(src)
    if not playerData then
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'player not found')
        return
    end
    if not hasRepairkit(playerData) then
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'no repairkit in inventory')
        return
    end

    -- Create the session.
    local nonce = generateNonce()
    activeSessions[src] = {
        vehicleNet = tonumber(vehicleNet),
        startedAt = now,
        nonce = nonce,
        stage = 'progress',
    }
    lastRequestTime[src] = now

    -- Tell the client to show the progress bar.
    TriggerClientEvent('qb-czcraft:client:repairkit:progress', src, {
        nonce = nonce,
        durationMs = PROGRESS_DURATION_MS,
    })
end)

-- Step 2: Complete — revalidate, tell client to apply repair.
RegisterNetEvent('qb-czcraft:server:repairkit:complete')
AddEventHandler('qb-czcraft:server:repairkit:complete', function(data)
    local src = source

    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'qb-czcraft is not ready')
        return
    end
    if not CZCraft.Config.General.features.repairkit then
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'repairkit handler is disabled')
        return
    end

    if type(data) ~= 'table' or type(data.nonce) ~= 'string' then
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'invalid request')
        return
    end

    -- Validate the session.
    local session = activeSessions[src]
    if not session then
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'no active repair session')
        return
    end
    if session.nonce ~= data.nonce then
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'invalid session nonce')
        return
    end
    if session.stage ~= 'progress' then
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'session is not in progress stage')
        return
    end

    -- Check the progress duration has elapsed (prevent instant completion exploits).
    local elapsed = GetGameTimer() - session.startedAt
    if elapsed < (PROGRESS_DURATION_MS - 500) then  -- 500ms tolerance for network latency
        activeSessions[src] = nil
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'progress not completed')
        return
    end

    -- Revalidate the vehicle (it may have moved or been destroyed).
    local valid, reason = validateVehicle(src, session.vehicleNet)
    if not valid then
        activeSessions[src] = nil
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, reason)
        return
    end

    -- Revalidate the player still has the item.
    local playerData = CZCraft.QBCoreAdapter.getPlayerData(src)
    if not playerData then
        activeSessions[src] = nil
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'player not found')
        return
    end
    if not hasRepairkit(playerData) then
        activeSessions[src] = nil
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'no repairkit in inventory')
        return
    end

    -- Mark the session as pending-apply and tell the client to apply the repair.
    session.stage = 'pending-apply'
    session.pendingAt = GetGameTimer()

    -- Start a timeout thread: if ack doesn't arrive, clear the session.
    CreateThread(function()
        Wait(ACK_TIMEOUT_MS)
        local s = activeSessions[src]
        if s and s.nonce == session.nonce and s.stage == 'pending-apply' then
            activeSessions[src] = nil
            TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'repair ack timeout — item not consumed')
        end
    end)

    -- Tell the client to apply the repair client-side.
    TriggerClientEvent('qb-czcraft:client:repairkit:apply', src, {
        vehicleNet = session.vehicleNet,
        nonce = data.nonce,
    })
end)

-- Step 3: Ack — client confirms the repair was applied, consume the item.
RegisterNetEvent('qb-czcraft:server:repairkit:ack')
AddEventHandler('qb-czcraft:server:repairkit:ack', function(data)
    local src = source

    if type(data) ~= 'table' or type(data.nonce) ~= 'string' then
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'invalid ack')
        return
    end

    local session = activeSessions[src]
    if not session then
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'no active repair session')
        return
    end
    if session.nonce ~= data.nonce then
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'invalid session nonce')
        return
    end
    if session.stage ~= 'pending-apply' then
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'session is not pending-apply')
        return
    end

    -- Revalidate the player still has the item (may have been used elsewhere).
    local playerData = CZCraft.QBCoreAdapter.getPlayerData(src)
    if not playerData then
        activeSessions[src] = nil
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'player not found')
        return
    end
    if not hasRepairkit(playerData) then
        activeSessions[src] = nil
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'no repairkit in inventory')
        return
    end

    -- Consume the item.
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then
        activeSessions[src] = nil
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'player object not found')
        return
    end

    local removed = Player.Functions.RemoveItem(REPAIRKIT_ITEM, 1)
    if not removed then
        activeSessions[src] = nil
        TriggerClientEvent('qb-czcraft:client:repairkit:fail', src, 'failed to consume repairkit')
        return
    end

    -- Trigger the item box animation on the client.
    TriggerClientEvent('inventory:client:ItemBox', src, QBCore.Shared.Items[REPAIRKIT_ITEM], 'remove')

    -- Clear the session.
    activeSessions[src] = nil

    -- Notify the client — cosmetic only (sound + notification).
    TriggerClientEvent('qb-czcraft:client:repairkit:success', src, {
        vehicleNet = session.vehicleNet,
        nonce = data.nonce,
    })
end)

-- Cancel: the player cancelled the progress bar (ESC, moved away, etc.).
RegisterNetEvent('qb-czcraft:server:repairkit:cancel')
AddEventHandler('qb-czcraft:server:repairkit:cancel', function(data)
    local src = source
    if type(data) ~= 'table' then return end

    local session = activeSessions[src]
    if not session then return end
    if data.nonce and session.nonce ~= data.nonce then return end

    activeSessions[src] = nil
    -- No item consumption on cancel.
end)

-- Cleanup on player disconnect.
AddEventHandler('playerDropped', function()
    local src = source
    activeSessions[src] = nil
    lastRequestTime[src] = nil
end)

Repairkit.REPAIRKIT_ITEM = REPAIRKIT_ITEM
Repairkit.PROGRESS_DURATION_MS = PROGRESS_DURATION_MS
Repairkit.MAX_VEHICLE_DISTANCE = MAX_VEHICLE_DISTANCE
Repairkit.ACK_TIMEOUT_MS = ACK_TIMEOUT_MS

CZCraft.Repairkit = Repairkit
return Repairkit
