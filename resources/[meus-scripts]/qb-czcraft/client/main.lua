-- qb-czcraft client main
-- Entry point: wires the dual interaction adapter (qb-target when UseTarget,
-- PolyZone/text + E otherwise), handles machine-item use to start placement,
-- and registers the stream/remote event handlers.

local QBCore = exports['qb-core']:GetCoreObject()
local CZCraftClient = {}

-- Whether the resource is ready (set by the server via state bag).
local isReady = false

AddStateBagChangeHandler('qb-czcraft:isReady', nil, function(_, _, value)
    isReady = value == true
end)

-- Starts placement for a machine item the player just used.
-- @param itemName string e.g. 'cz_workbench_machine'
-- @param slot number inventory slot
function CZCraftClient.startPlacement(itemName, slot)
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

-- Use-item hook: when a player uses a cz_*_machine item, start placement.
CreateThread(function()
    -- qb-core fires 'QBCore:Client:UseItem' for usable items.
    AddEventHandler('QBCore:Client:UseItem', function(itemName, itemInfo)
        if not itemName or not string.match(itemName, '^cz_.*_machine$') then
            return
        end
        local playerData = QBCore.Functions.GetPlayerData()
        local slot = itemInfo and itemInfo.slot
        if not slot then return end
        CZCraftClient.startPlacement(itemName, slot)
    end)
end)

-- Expose for other client modules.
CZCraftClient.QBCore = QBCore
CZCraftClient.isReady = function() return isReady end

_G.CZCraftClient = CZCraftClient
