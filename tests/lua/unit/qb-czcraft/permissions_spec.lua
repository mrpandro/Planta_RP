-- qb-czcraft permission resolution tests
-- Pure tests for HOUSE (owner/keyholder full access) and ORG (grade grants +
-- membership revocation) permission resolution.

dofile("resources/[meus-scripts]/qb-czcraft/shared/constants.lua")
local Permissions = dofile("resources/[meus-scripts]/qb-czcraft/server/domain/permissions.lua")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "Assertion failed") .. " | expected=" .. tostring(expected) .. ", actual=" .. tostring(actual))
    end
end

local function assertTrue(value, message)
    if not value then
        error(message or "Expected truthy value")
    end
end

local function assertFalse(value, message)
    if value then
        error(message or "Expected falsy value")
    end
end

return {
    {
        name = "house owner gets all six permissions",
        test = function()
            local granted = Permissions.resolveHousePermissions({ isOwner = true, isKeyholder = false })
            assertEqual(granted[CZCraft.Permission.OWNER], true, "OWNER")
            assertEqual(granted[CZCraft.Permission.MANAGER], true, "MANAGER")
            assertEqual(granted[CZCraft.Permission.PRODUCTION], true, "PRODUCTION")
            assertEqual(granted[CZCraft.Permission.WITHDRAW], true, "WITHDRAW")
            assertEqual(granted[CZCraft.Permission.DEPOSIT], true, "DEPOSIT")
            assertEqual(granted[CZCraft.Permission.VIEW], true, "VIEW")
        end,
    },
    {
        name = "house keyholder gets all six permissions",
        test = function()
            local granted = Permissions.resolveHousePermissions({ isOwner = false, isKeyholder = true })
            assertEqual(granted[CZCraft.Permission.OWNER], true, "keyholder OWNER")
            assertEqual(granted[CZCraft.Permission.PRODUCTION], true, "keyholder PRODUCTION")
            assertEqual(granted[CZCraft.Permission.WITHDRAW], true, "keyholder WITHDRAW")
        end,
    },
    {
        name = "non-owner non-keyholder gets no permissions",
        test = function()
            local granted = Permissions.resolveHousePermissions({ isOwner = false, isKeyholder = false })
            assertFalse(granted[CZCraft.Permission.OWNER], "no OWNER")
            assertFalse(granted[CZCraft.Permission.VIEW], "no VIEW")
        end,
    },
    {
        name = "ORG grade grants resolve known permissions",
        test = function()
            local accessConfig = {
                jobGrades = { ['2'] = { 'OWNER', 'PRODUCTION', 'VIEW' } },
                gangGrades = {},
            }
            local granted = Permissions.resolveOrgPermissions(CZCraft.OwnerType.JOB, '2', accessConfig)
            assertEqual(granted[CZCraft.Permission.OWNER], true, "JOB grade 2 OWNER")
            assertEqual(granted[CZCraft.Permission.PRODUCTION], true, "JOB grade 2 PRODUCTION")
            assertEqual(granted[CZCraft.Permission.VIEW], true, "JOB grade 2 VIEW")
            assertFalse(granted[CZCraft.Permission.WITHDRAW], "no WITHDRAW")
        end,
    },
    {
        name = "ORG gang grade grants resolve",
        test = function()
            local accessConfig = {
                jobGrades = {},
                gangGrades = { ['3'] = { 'MANAGER', 'DEPOSIT' } },
            }
            local granted = Permissions.resolveOrgPermissions(CZCraft.OwnerType.GANG, '3', accessConfig)
            assertEqual(granted[CZCraft.Permission.MANAGER], true, "GANG grade 3 MANAGER")
            assertEqual(granted[CZCraft.Permission.DEPOSIT], true, "GANG grade 3 DEPOSIT")
        end,
    },
    {
        name = "unknown grade gets no permissions",
        test = function()
            local accessConfig = { jobGrades = { ['5'] = { 'OWNER' } }, gangGrades = {} }
            local granted = Permissions.resolveOrgPermissions(CZCraft.OwnerType.JOB, '1', accessConfig)
            assertFalse(granted[CZCraft.Permission.OWNER], "unknown grade no OWNER")
        end,
    },
    {
        name = "empty grade maps deny all",
        test = function()
            local granted = Permissions.resolveOrgPermissions(CZCraft.OwnerType.JOB, '2', { jobGrades = {}, gangGrades = {} })
            assertFalse(granted[CZCraft.Permission.OWNER], "empty jobGrades deny OWNER")
        end,
    },
    {
        name = "isStillOrgMember true when job matches",
        test = function()
            local playerData = { job = { name = 'police' }, gang = { name = 'none' } }
            assertTrue(Permissions.isStillOrgMember({ type = CZCraft.OwnerType.JOB, id = 'police' }, playerData), "job member")
        end,
    },
    {
        name = "isStillOrgMember false when job changed (membership revoked)",
        test = function()
            local playerData = { job = { name = 'unemployed' }, gang = { name = 'none' } }
            assertFalse(Permissions.isStillOrgMember({ type = CZCraft.OwnerType.JOB, id = 'police' }, playerData), "job revoked")
        end,
    },
    {
        name = "isStillOrgMember false when gang changed",
        test = function()
            local playerData = { job = { name = 'unemployed' }, gang = { name = 'ballas' } }
            assertFalse(Permissions.isStillOrgMember({ type = CZCraft.OwnerType.GANG, id = 'lostmc' }, playerData), "gang revoked")
        end,
    },
    {
        name = "PLAYER ownership is always stillMember",
        test = function()
            assertTrue(Permissions.isStillOrgMember({ type = CZCraft.OwnerType.PLAYER, id = 'ABC123' }, {}), "player always member")
        end,
    },
    {
        name = "hasPermission true for granted, false for denied",
        test = function()
            local granted = { [CZCraft.Permission.OWNER] = true }
            assertTrue(Permissions.hasPermission(granted, CZCraft.Permission.OWNER), "has OWNER")
            assertFalse(Permissions.hasPermission(granted, CZCraft.Permission.WITHDRAW), "no WITHDRAW")
        end,
    },
    {
        name = "hasPermission false for unknown permission",
        test = function()
            assertFalse(Permissions.hasPermission({}, 'DELETE_EVERYTHING'), "unknown permission denied")
        end,
    },
}
