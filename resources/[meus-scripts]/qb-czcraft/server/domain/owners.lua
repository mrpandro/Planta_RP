-- qb-czcraft owner resolution (pure)
-- Resolves an ownerRef { type=PLAYER|JOB|GANG, id=string } from a chosen
-- context plus the acting player's job/gang. Side-effect-free so it can run
-- under stock Lua 5.4 in tests; the api layer passes real PlayerData in.

CZCraft = CZCraft or {}

-- Validates the structural shape of an ownerRef.
-- @param ownerRef table { type, id }
-- @return boolean ok
-- @return string|nil reason
local function isValidOwnerRef(ownerRef)
    if type(ownerRef) ~= 'table' then
        return false, 'ownerRef must be a table'
    end
    local ownerType = ownerRef.type
    if ownerType ~= CZCraft.OwnerType.PLAYER
        and ownerType ~= CZCraft.OwnerType.JOB
        and ownerType ~= CZCraft.OwnerType.GANG then
        return false, 'ownerRef.type must be PLAYER, JOB or GANG'
    end
    if type(ownerRef.id) ~= 'string' or ownerRef.id == '' then
        return false, 'ownerRef.id must be a nonempty string'
    end
    return true
end

-- Resolves the ownerRef for a placement/pickup action from the actor's chosen
-- context and live job/gang data.
--
-- @param context string 'CIVIL' | 'JOB' | 'GANG' (the context picker choice)
-- @param playerData table { citizenid, job={name}, gang={name} }
-- @return table|nil ownerRef
-- @return string|nil reason
local function resolveOwnerRef(context, playerData)
    if context == 'CIVIL' then
        if type(playerData) ~= 'table' or type(playerData.citizenid) ~= 'string' then
            return nil, 'CIVIL context requires a valid citizenid'
        end
        return { type = CZCraft.OwnerType.PLAYER, id = playerData.citizenid }
    end

    if context == 'JOB' then
        local jobName = playerData and playerData.job and playerData.job.name
        if type(jobName) ~= 'string' or jobName == '' or jobName == 'unemployed' then
            return nil, 'JOB context requires an active non-unemployed job'
        end
        return { type = CZCraft.OwnerType.JOB, id = jobName }
    end

    if context == 'GANG' then
        local gangName = playerData and playerData.gang and playerData.gang.name
        if type(gangName) ~= 'string' or gangName == '' or gangName == 'none' then
            return nil, 'GANG context requires an active gang'
        end
        return { type = CZCraft.OwnerType.GANG, id = gangName }
    end

    return nil, 'unknown context: ' .. tostring(context)
end

CZCraft.Owners = {
    isValidOwnerRef = isValidOwnerRef,
    resolveOwnerRef = resolveOwnerRef,
}

return CZCraft.Owners
