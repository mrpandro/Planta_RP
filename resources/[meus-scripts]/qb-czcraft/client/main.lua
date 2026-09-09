-- qb-czcraft client main
-- Entry point: wires the dual interaction adapter (qb-target when UseTarget,
-- PolyZone/text + E otherwise), handles machine-item use to start placement,
-- and registers the stream/remote event handlers.

local QBCore = exports['qb-core']:GetCoreObject()
local CZCraftClient = {}

-- Whether the resource is ready (set by the server via state bag).
local isReady = false

-- Read the current GlobalState value on startup. AddStateBagChangeHandler
-- only fires on CHANGES — if the server set isReady=true before this
-- client resource started, the handler never fires and isReady stays
-- false, blocking all item use.
CreateThread(function()
    -- GlobalState may not be replicated yet on the very first frame;
    -- poll briefly until it arrives or we time out.
    for _ = 1, 50 do
        local v = GlobalState['qb-czcraft:isReady']
        if v ~= nil then
            isReady = v == true
            break
        end
        Wait(100)
    end
end)

AddStateBagChangeHandler('qb-czcraft:isReady', nil, function(_, _, value)
    isReady = value == true
end)

-- Starts placement for a machine item the player just used.
-- @param itemName string e.g. 'cz_workbench_machine'
-- @param slot number inventory slot
function CZCraftClient.startPlacement(itemName, slot)
    print(('[qb-czcraft] startPlacement: itemName=%s slot=%s isReady=%s features.placement=%s'):format(
        tostring(itemName), tostring(slot), tostring(isReady),
        tostring(CZCraft.Config and CZCraft.Config.General and CZCraft.Config.General.features and CZCraft.Config.General.features.placement)))
    if not isReady then
        QBCore.Functions.Notify('qb-czcraft is not ready', 'error')
        return
    end
    if not CZCraft.Config.General.features.placement then
        QBCore.Functions.Notify('Placement is disabled', 'error')
        return
    end

    -- Determine the owner context. For v0.1 the player chooses via a context
    -- menu; default to CIVIL (HOUSE) when the player is inside a house.
    local context = 'CIVIL'
    local playerData = QBCore.Functions.GetPlayerData()
    local inside = playerData and playerData.metadata and playerData.metadata.inside
    if not (inside and inside.house) then
        -- Not inside a house: prompt for ORG context if the player has a
        -- job/gang. For v0.1 simplicity, fall back to CIVIL and let the
        -- server reject if no house is present.
        if playerData and playerData.job and playerData.job.name ~= 'unemployed' then
            context = 'JOB'
        elseif playerData and playerData.gang and playerData.gang.name ~= 'none' then
            context = 'GANG'
        end
    end

    CZCraftClient.Placement.begin(itemName, slot, context)
end

-- Use-item hook: when a player uses a cz_*_machine item, the server-side
-- CreateUseableItem callback fires this event. (The previous code listened
-- for 'QBCore:Client:UseItem' which no resource actually fires.)
RegisterNetEvent('qb-czcraft:client:useMachineItem')
AddEventHandler('qb-czcraft:client:useMachineItem', function(itemName, itemInfo)
    print(('[qb-czcraft] useMachineItem received: itemName=%s itemInfo=%s'):format(
        tostring(itemName), tostring(itemInfo)))
    if not itemName or not string.match(itemName, '^cz_.*_machine$') then
        print('[qb-czcraft] useMachineItem: itemName did not match pattern, ignoring')
        return
    end
    local slot = itemInfo and itemInfo.slot
    if not slot then
        print(('[qb-czcraft] useMachineItem: no slot in itemInfo (itemInfo=%s)'):format(tostring(itemInfo)))
        return
    end
    print(('[qb-czcraft] useMachineItem: calling startPlacement, isReady=%s'):format(tostring(isReady)))
    CZCraftClient.startPlacement(itemName, slot)
end)

-- Expose for other client modules.
CZCraftClient.QBCore = QBCore
CZCraftClient.isReady = function() return isReady end

_G.CZCraftClient = CZCraftClient
