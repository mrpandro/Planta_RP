-- qb-czraft client placement
-- Ghost prop + raycast + rotate (scroll) + cancel (ESC) placement flow.
-- On confirm, sends the transform to the server via lib.callback.await.
-- The server is authoritative: the client only proposes a transform; the
-- server re-validates proximity, allow-list, and house/plot eligibility.

local CZCraftClient = _G.CZCraftClient

local Placement = {}

-- Active placement state.
local placing = false
local placementItemName = nil
local placementSlot = nil
local placementContext = nil
local ghostEntity = nil
local placementRotation = 0.0

-- Raycast from the player's camera to find a ground/world hit point.
-- @return vector3|nil hitCoords
local function raycastGround()
    local playerPed = PlayerPedId()
    local startPos = GetOffsetFromEntityInWorldCoords(playerPed, 0.0, 0.0, 0.0)
    local camCoords = GetGameplayCamCoord()
    local camRot = GetGameplayCamRot(2)
    local dir = RotationToDirection(camRot)
    local endPos = camCoords + dir * 10.0

    local rayHandle = StartShapeTestRay(
        startPos.x, startPos.y, startPos.z,
        endPos.x, endPos.y, endPos.z,
        1, -- world
        playerPed, 0
    )
    local _, hit, hitCoords = GetShapeTestResult(rayHandle)
    if hit == 1 then
        return hitCoords
    end
    return nil
end

-- Converts camera rotation to a direction vector.
local function RotationToDirection(rotation)
    local z = math.rad(rotation.z)
    local x = math.rad(rotation.x)
    local num = math.abs(math.cos(x))
    return vector3(
        -math.sin(z) * num,
        math.cos(z) * num,
        math.sin(x)
    )
end

-- Finds the prop model for a machine item name.
local function propForItem(itemName)
    for _, machine in ipairs(CZCraft.Config.Machines) do
        if machine.item == itemName then
            return machine.prop
        end
    end
    return nil
end

-- Creates the ghost prop at the current raycast hit.
local function createGhost(propModel)
    if ghostEntity and DoesEntityExist(ghostEntity) then
        DeleteEntity(ghostEntity)
    end
    local hash = GetHashKey(propModel)
    RequestModel(hash)
    local timeout = 0
    while not HasModelLoaded(hash) and timeout < 100 do
        Wait(10)
        timeout = timeout + 1
    end
    local hitCoords = raycastGround() or GetEntityCoords(PlayerPedId())
    ghostEntity = CreateObject(hash, hitCoords.x, hitCoords.y, hitCoords.z, false, false, false)
    SetEntityAlpha(ghostEntity, 180, false)
    SetEntityCollision(ghostEntity, false, false)
    SetEntityDrawOutline(ghostEntity, true)
    PlaceObjectOnGroundProperly(ghostEntity)
    SetEntityHeading(ghostEntity, placementRotation)
end

-- Updates the ghost position + rotation each frame while placing.
local function updateGhost()
    if not ghostEntity or not DoesEntityExist(ghostEntity) then return end
    local hitCoords = raycastGround()
    if hitCoords then
        SetEntityCoords(ghostEntity, hitCoords.x, hitCoords.y, hitCoords.z, false, false, false, true)
        PlaceObjectOnGroundProperly(ghostEntity)
    end
    SetEntityHeading(ghostEntity, placementRotation)
end

-- Placement control thread: scroll to rotate, ENTER to confirm, ESC to cancel.
CreateThread(function()
    while true do
        Wait(0)
        if not placing then
            Wait(200)
        else
            updateGhost()
            -- Rotate with mouse wheel / scroll.
            if IsControlJustPressed(0, 174) then -- SCROLLUP
                placementRotation = placementRotation + 15.0
                if placementRotation >= 360.0 then placementRotation = placementRotation - 360.0 end
            elseif IsControlJustPressed(0, 175) then -- SCROLLDOWN
                placementRotation = placementRotation - 15.0
                if placementRotation < 0.0 then placementRotation = placementRotation + 360.0 end
            end
            -- Confirm with ENTER.
            if IsControlJustPressed(0, 201) then -- INPUT_FRONTEND_ACCEPT
                Placement.confirm()
            end
            -- Cancel with ESC or BACKSPACE.
            if IsControlJustPressed(0, 194) or IsControlJustPressed(0, 200) then
                Placement.cancel()
            end
        end
    end
end)

-- Begins placement for a machine item.
-- @param itemName string
-- @param slot number
-- @param context string 'CIVIL'|'JOB'|'GANG'
function Placement.begin(itemName, slot, context)
    if placing then
        return
    end
    local propModel = propForItem(itemName)
    if not propModel then
        CZCraftClient.QBCore.Functions.Notify('Unknown machine item', 'error')
        return
    end
    placing = true
    placementItemName = itemName
    placementSlot = slot
    placementContext = context
    placementRotation = 0.0
    createGhost(propModel)
    CZCraftClient.QBCore.Functions.Notify('Place the machine: scroll to rotate, ENTER to confirm, ESC to cancel', 'primary')
end

-- Confirms placement: sends the transform to the server.
function Placement.confirm()
    if not placing or not ghostEntity or not DoesEntityExist(ghostEntity) then
        return
    end
    local coords = GetEntityCoords(ghostEntity)
    local heading = GetEntityHeading(ghostEntity)
    local transform = {
        pos_x = coords.x,
        pos_y = coords.y,
        pos_z = coords.z,
        heading = heading,
    }

    -- Freeze the ghost while awaiting the server response.
    local itemName = placementItemName
    local slot = placementSlot
    local context = placementContext

    Placement.cleanup()

    Citizen.CreateThread(function()
        local result = lib.callback.await('qb-czcraft:server:commitPlacement', false, {
            transform = transform,
            itemSlot = slot,
            context = context,
        })
        if result and result.success then
            CZCraftClient.QBCore.Functions.Notify('Machine placed', 'success')
        else
            CZCraftClient.QBCore.Functions.Notify('Placement failed: ' .. (result and result.reason or 'unknown'), 'error')
        end
    end)
end

-- Cancels placement and cleans up the ghost.
function Placement.cancel()
    Placement.cleanup()
    CZCraftClient.QBCore.Functions.Notify('Placement cancelled', 'primary')
end

-- Removes the ghost entity and resets state.
function Placement.cleanup()
    if ghostEntity and DoesEntityExist(ghostEntity) then
        DeleteEntity(ghostEntity)
    end
    ghostEntity = nil
    placing = false
    placementItemName = nil
    placementSlot = nil
    placementContext = nil
end

-- Pickup: requests the server to pack a machine the player is targeting.
-- @param machineUuid string
function Placement.requestPickup(machineUuid)
    if not CZCraftClient.isReady() then
        CZCraftClient.QBCore.Functions.Notify('qb-czcraft is not ready', 'error')
        return
    end
    Citizen.CreateThread(function()
        local result = lib.callback.await('qb-czcraft:server:pickupMachine', false, {
            machineUuid = machineUuid,
        })
        if result and result.success then
            CZCraftClient.QBCore.Functions.Notify('Machine picked up', 'success')
        else
            CZCraftClient.QBCore.Functions.Notify('Pickup failed: ' .. (result and result.reason or 'unknown'), 'error')
        end
    end)
end

CZCraftClient.Placement = Placement
return Placement
