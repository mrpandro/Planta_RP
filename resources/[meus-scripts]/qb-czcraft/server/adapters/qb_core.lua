-- qb-czcraft qb-core adapter
-- Thin wrapper over QBCore exports so domain code never reaches into the
-- global QBCore object directly. Provides player data, money, and metadata
-- lookups used by the api layer.

CZCraft = CZCraft or {}

local QBCoreAdapter = {}

-- @param source number player server id
-- @return table|nil Player
function QBCoreAdapter.getPlayer(source)
    return exports['qb-core']:GetPlayer(source)
end

-- @param source number
-- @return table|nil playerData { citizenid, job, gang, metadata }
function QBCoreAdapter.getPlayerData(source)
    local Player = exports['qb-core']:GetPlayer(source)
    if not Player then return nil end
    return Player.PlayerData
end

-- @return table QBCore.Shared.Items
function QBCoreAdapter.getItems()
    return exports['qb-core']:GetCoreObject().Shared.Items or {}
end

-- Returns the house id the player is currently inside, or nil.
-- @param playerData table
-- @return string|nil houseId
function QBCoreAdapter.getInsideHouse(playerData)
    local inside = playerData and playerData.metadata and playerData.metadata.inside
    if type(inside) ~= 'table' then return nil end
    local house = inside.house
    if type(house) == 'string' and house ~= '' then
        return house
    end
    return nil
end

CZCraft.QBCoreAdapter = QBCoreAdapter
return QBCoreAdapter
