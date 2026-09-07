-- qb-czcraft permission resolution (pure)
-- Maps the six industrial permissions (OWNER|MANAGER|PRODUCTION|WITHDRAW|
-- DEPOSIT|VIEW) onto actor + location context. Side-effect-free: the api layer
-- injects house owner/keyholder lookups and live job/gang grade data.
--
-- HOUSE: owner or any keyholder of the house gets all six permissions
--   (inclusive of pickup). Placing as a keyholder associates the machine with
--   the house owner; pickup hands the item to whoever executes it.
-- ORG: grade grants from Config.Access.jobGrades/gangGrades, re-evaluated each
--   action. Losing membership revokes access immediately without altering ORG
--   ownership.

CZCraft = CZCraft or {}

local ALL_PERMISSIONS = {
    [CZCraft.Permission.OWNER] = true,
    [CZCraft.Permission.MANAGER] = true,
    [CZCraft.Permission.PRODUCTION] = true,
    [CZCraft.Permission.WITHDRAW] = true,
    [CZCraft.Permission.DEPOSIT] = true,
    [CZCraft.Permission.VIEW] = true,
}

-- Validates that a permission string is one of the six.
local function isKnownPermission(permission)
    return ALL_PERMISSIONS[permission] == true
end

-- HOUSE permission resolution.
-- @param houseAccess table { isOwner = boolean, isKeyholder = boolean }
-- @return table set of granted permissions (or empty table if neither)
local function resolveHousePermissions(houseAccess)
    if type(houseAccess) ~= 'table' then
        return {}
    end
    if houseAccess.isOwner or houseAccess.isKeyholder then
        -- Owner and keyholders both get the full six-permission set.
        local granted = {}
        for permission in pairs(ALL_PERMISSIONS) do
            granted[permission] = true
        end
        return granted
    end
    return {}
end

-- ORG permission resolution from grade grants.
-- @param ownerType 'JOB'|'GANG'
-- @param gradeKey string the grade key to look up in the grant map
-- @param accessConfig table Config.Access (jobGrades, gangGrades)
-- @return table set of granted permissions
local function resolveOrgPermissions(ownerType, gradeKey, accessConfig)
    if type(accessConfig) ~= 'table' then
        return {}
    end
    local gradeMap
    if ownerType == CZCraft.OwnerType.JOB then
        gradeMap = accessConfig.jobGrades or {}
    elseif ownerType == CZCraft.OwnerType.GANG then
        gradeMap = accessConfig.gangGrades or {}
    else
        return {}
    end

    local grants = gradeMap[gradeKey]
    if type(grants) ~= 'table' then
        return {}
    end

    local granted = {}
    for _, permission in ipairs(grants) do
        if isKnownPermission(permission) then
            granted[permission] = true
        end
    end
    return granted
end

-- Checks whether an actor holds a single permission given a resolved grant set.
local function hasPermission(grantedSet, permission)
    return isKnownPermission(permission) and grantedSet[permission] == true
end

-- Checks that the actor's live membership still matches the machine's ownerRef.
-- Losing job/gang membership revokes ORG access immediately.
-- @param ownerRef table { type, id }
-- @param playerData table { job={name}, gang={name} }
-- @return boolean stillMember
local function isStillOrgMember(ownerRef, playerData)
    if ownerRef.type == CZCraft.OwnerType.JOB then
        local jobName = playerData and playerData.job and playerData.job.name
        return jobName == ownerRef.id
    end
    if ownerRef.type == CZCraft.OwnerType.GANG then
        local gangName = playerData and playerData.gang and playerData.gang.name
        return gangName == ownerRef.id
    end
    -- PLAYER ownership is not membership-based.
    return true
end

CZCraft.Permissions = {
    isKnownPermission = isKnownPermission,
    resolveHousePermissions = resolveHousePermissions,
    resolveOrgPermissions = resolveOrgPermissions,
    hasPermission = hasPermission,
    isStillOrgMember = isStillOrgMember,
}

return CZCraft.Permissions
