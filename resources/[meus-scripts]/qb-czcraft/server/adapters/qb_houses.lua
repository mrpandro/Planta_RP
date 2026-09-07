-- qb-czcraft qb-houses adapter (read-only)
-- Resolves house ownership and keyholder status from qb-houses runtime data
-- without patching qb-houses source. The house-transfer hook + startup
-- reconciliation are deferred (this session is qb-czcraft-internal only).

CZCraft = CZCraft or {}

local QbHousesAdapter = {}

-- Returns whether the acting player is the owner or a keyholder of a house.
-- Uses the qb-houses `hasKey` export (which covers keyholders) plus a direct
-- owner check via the qb-houses callback.
-- @param source number player server id
-- @param houseId string
-- @return table { isOwner, isKeyholder }
function QbHousesAdapter.resolveHouseAccess(source, houseId)
    local Player = exports['qb-core']:GetPlayer(source)
    if not Player then
        return { isOwner = false, isKeyholder = false }
    end
    local playerData = Player.PlayerData
    local license = playerData.license
    local citizenid = playerData.citizenid

    -- Owner check via the qb-houses callback (synchronous-style via export if
    -- available, else fall back to a direct query).
    local isOwner = false
    local ownerRow = MySQL.single.await(
        'SELECT `identifier`, `citizenid` FROM `player_houses` WHERE `house` = ?',
        { houseId }
    )
    if ownerRow then
        isOwner = (ownerRow.identifier == license and ownerRow.citizenid == citizenid)
    end

    -- Keyholder check via the qb-houses export.
    local isKeyholder = false
    if not isOwner then
        local ok, result = pcall(function()
            return exports['qb-houses']:hasKey(license, citizenid, houseId)
        end)
        if ok then
            isKeyholder = result == true
        end
    end

    return { isOwner = isOwner, isKeyholder = isKeyholder }
end

-- Returns the house owner's citizenid for a given house (so a keyholder
-- placing a machine associates it with the house owner, not themselves).
-- @param houseId string
-- @return string|nil ownerCitizenid
function QbHousesAdapter.getHouseOwnerCitizenid(houseId)
    local row = MySQL.single.await(
        'SELECT `citizenid` FROM `player_houses` WHERE `house` = ?',
        { houseId }
    )
    return row and row.citizenid or nil
end

CZCraft.QbHousesAdapter = QbHousesAdapter
return QbHousesAdapter
