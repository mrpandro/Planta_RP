-- qb-czcraft client NUI handler
-- Opens/closes the NUI dashboard and bridges NUI callbacks to server
-- lib.callback handlers. The NUI sends fetch POSTs to https://qb-czcraft/<cb>,
-- which are received here via RegisterNUICallback and forwarded to the server.

local CZCraftClient = _G.CZCraftClient

local NUI = {}

-- Whether the NUI is currently open.
local isOpen = false

-- The machine UUID currently being viewed (if any).
local currentMachineUuid = nil

-- Opens the NUI dashboard for a machine.
-- @param machineUuid string
-- @param machineType string
function NUI.open(machineUuid, machineType)
    if isOpen then return end
    if not CZCraftClient.isReady() then
        CZCraftClient.QBCore.Functions.Notify('qb-czcraft is not ready', 'error')
        return
    end
    if not CZCraft.Config.General.features.nui then
        CZCraftClient.QBCore.Functions.Notify('NUI is disabled', 'error')
        return
    end

    currentMachineUuid = machineUuid
    isOpen = true

    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'open',
        machineUuid = machineUuid,
        machineType = machineType,
    })
end

-- Closes the NUI dashboard.
function NUI.close()
    if not isOpen then return end
    isOpen = false
    currentMachineUuid = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

-- Returns whether the NUI is open.
function NUI.isOpen()
    return isOpen
end

-- ===========================================================================
-- NUI callback handlers — bridge NUI fetch to server lib.callback
-- ===========================================================================

RegisterNUICallback('close', function(_, cb)
    NUI.close()
    cb({ success = true })
end)

RegisterNUICallback('getOwnerOverview', function(_, cb)
    local result = lib.callback.await('qb-czcraft:server:nui:getOwnerOverview', false)
    cb(result or { success = false, reason = 'no response' })
end)

RegisterNUICallback('getMachineData', function(data, cb)
    if not data or not data.machineUuid then
        cb({ success = false, reason = 'machineUuid required' })
        return
    end
    local result = lib.callback.await('qb-czcraft:server:nui:getMachineData', false, {
        machineUuid = data.machineUuid,
    })
    cb(result or { success = false, reason = 'no response' })
end)

RegisterNUICallback('getStock', function(data, cb)
    if not data or not data.machineUuid then
        cb({ success = false, reason = 'machineUuid required' })
        return
    end
    local result = lib.callback.await('qb-czcraft:server:nui:getStock', false, {
        machineUuid = data.machineUuid,
    })
    cb(result or { success = false, reason = 'no response' })
end)

RegisterNUICallback('getBills', function(data, cb)
    if not data or not data.machineUuid then
        cb({ success = false, reason = 'machineUuid required' })
        return
    end
    local result = lib.callback.await('qb-czcraft:server:nui:getBills', false, {
        machineUuid = data.machineUuid,
    })
    cb(result or { success = false, reason = 'no response' })
end)

RegisterNUICallback('getRecipes', function(data, cb)
    if not data or not data.machineUuid then
        cb({ success = false, reason = 'machineUuid required' })
        return
    end
    local result = lib.callback.await('qb-czcraft:server:nui:getRecipes', false, {
        machineUuid = data.machineUuid,
    })
    cb(result or { success = false, reason = 'no response' })
end)

RegisterNUICallback('createBill', function(data, cb)
    if not data or not data.machineUuid then
        cb({ success = false, reason = 'machineUuid required' })
        return
    end
    local result = lib.callback.await('qb-czcraft:server:nui:createBill', false, {
        machineUuid = data.machineUuid,
        recipeId = data.recipeId,
        mode = data.mode,
        targetQuantity = data.targetQuantity,
    })
    cb(result or { success = false, reason = 'no response' })
end)

RegisterNUICallback('pauseBill', function(data, cb)
    if not data or not data.billId then
        cb({ success = false, reason = 'billId required' })
        return
    end
    local result = lib.callback.await('qb-czcraft:server:nui:pauseBill', false, {
        billId = data.billId,
        version = data.version,
    })
    cb(result or { success = false, reason = 'no response' })
end)

RegisterNUICallback('resumeBill', function(data, cb)
    if not data or not data.billId then
        cb({ success = false, reason = 'billId required' })
        return
    end
    local result = lib.callback.await('qb-czcraft:server:nui:resumeBill', false, {
        billId = data.billId,
        version = data.version,
    })
    cb(result or { success = false, reason = 'no response' })
end)

RegisterNUICallback('removeBill', function(data, cb)
    if not data or not data.billId then
        cb({ success = false, reason = 'billId required' })
        return
    end
    local result = lib.callback.await('qb-czcraft:server:nui:removeBill', false, {
        billId = data.billId,
        version = data.version,
    })
    cb(result or { success = false, reason = 'no response' })
end)

-- Close NUI on ESC.
CreateThread(function()
    while true do
        Wait(0)
        if isOpen then
            if IsControlJustPressed(0, 322) then -- Backspace/ESC
                NUI.close()
            end
        end
    end
end)

CZCraftClient.NUI = NUI
return NUI
