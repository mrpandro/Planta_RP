-- qb-czcraft machine lifecycle + pickup tests
-- Pure tests for the PACKED<->INSTALLED state machine, pickup preconditions,
-- and ownerRef resolution.

dofile("resources/[meus-scripts]/qb-czcraft/shared/constants.lua")
local Owners = dofile("resources/[meus-scripts]/qb-czcraft/server/domain/owners.lua")
local Machines = dofile("resources/[meus-scripts]/qb-czcraft/server/domain/machines.lua")

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

local function assertContains(haystack, needle, message)
    if type(haystack) ~= 'string' or string.find(haystack, needle, 1, true) == nil then
        error((message or "Expected string to contain needle") .. " | needle=" .. tostring(needle) .. ", haystack=" .. tostring(haystack))
    end
end

return {
    {
        name = "lifecycle constants are PACKED and INSTALLED",
        test = function()
            assertEqual(Machines.Lifecycle.PACKED, 'PACKED', "PACKED")
            assertEqual(Machines.Lifecycle.INSTALLED, 'INSTALLED', "INSTALLED")
        end,
    },
    {
        name = "pickup happy path: stopped, no cycle, no bills, empty stock",
        test = function()
            local machine = {
                lifecycle = 'INSTALLED',
                operational_status = 'STOPPED',
                active_cycle_id = nil,
            }
            local ok, reason = Machines.validatePickup(machine, 0, 0, 0)
            assertTrue(ok, "should allow pickup")
            assertEqual(reason, nil, "no reason")
        end,
    },
    {
        name = "pickup fails when machine is RUNNING",
        test = function()
            local machine = { lifecycle = 'INSTALLED', operational_status = 'RUNNING', active_cycle_id = nil }
            local ok, reason = Machines.validatePickup(machine, 0, 0, 0)
            assertFalse(ok, "should fail")
            assertContains(reason, "running", "reason mentions running")
        end,
    },
    {
        name = "pickup fails when active cycle present",
        test = function()
            local machine = { lifecycle = 'INSTALLED', operational_status = 'STOPPED', active_cycle_id = 'cycle-123' }
            local ok, reason = Machines.validatePickup(machine, 0, 0, 0)
            assertFalse(ok, "should fail")
            assertContains(reason, "active cycle", "reason mentions cycle")
        end,
    },
    {
        name = "pickup fails when active or paused bills present",
        test = function()
            local machine = { lifecycle = 'INSTALLED', operational_status = 'STOPPED', active_cycle_id = nil }
            local ok, reason = Machines.validatePickup(machine, 2, 0, 0)
            assertFalse(ok, "should fail")
            assertContains(reason, "bills", "reason mentions bills")
        end,
    },
    {
        name = "pickup fails when stock is non-empty",
        test = function()
            local machine = { lifecycle = 'INSTALLED', operational_status = 'STOPPED', active_cycle_id = nil }
            local ok, reason = Machines.validatePickup(machine, 0, 50, 0)
            assertFalse(ok, "should fail")
            assertContains(reason, "stock must be empty", "reason mentions stock")
        end,
    },
    {
        name = "pickup fails when reservations are non-zero",
        test = function()
            local machine = { lifecycle = 'INSTALLED', operational_status = 'STOPPED', active_cycle_id = nil }
            local ok, reason = Machines.validatePickup(machine, 0, 0, 10)
            assertFalse(ok, "should fail")
            assertContains(reason, "reserved", "reason mentions reservations")
        end,
    },
    {
        name = "pickup fails when machine is PACKED (not INSTALLED)",
        test = function()
            local machine = { lifecycle = 'PACKED', operational_status = 'STOPPED', active_cycle_id = nil }
            local ok, reason = Machines.validatePickup(machine, 0, 0, 0)
            assertFalse(ok, "should fail")
            assertContains(reason, "INSTALLED", "reason mentions installed")
        end,
    },
    {
        name = "ownerRef CIVIL resolves to PLAYER with citizenid",
        test = function()
            local ref, err = Owners.resolveOwnerRef('CIVIL', { citizenid = 'CIT123' })
            assertTrue(ref, "ref should resolve")
            assertEqual(err, nil, "no error")
            assertEqual(ref.type, CZCraft.OwnerType.PLAYER, "type PLAYER")
            assertEqual(ref.id, 'CIT123', "id citizenid")
        end,
    },
    {
        name = "ownerRef JOB resolves to JOB with job name",
        test = function()
            local ref, err = Owners.resolveOwnerRef('JOB', { job = { name = 'police' }, gang = { name = 'none' } })
            assertTrue(ref, "ref should resolve")
            assertEqual(ref.type, CZCraft.OwnerType.JOB, "type JOB")
            assertEqual(ref.id, 'police', "id job name")
        end,
    },
    {
        name = "ownerRef JOB fails for unemployed",
        test = function()
            local ref, err = Owners.resolveOwnerRef('JOB', { job = { name = 'unemployed' }, gang = { name = 'none' } })
            assertFalse(ref, "ref should not resolve")
            assertContains(err, "non-unemployed", "reason mentions unemployed")
        end,
    },
    {
        name = "ownerRef GANG resolves to GANG with gang name",
        test = function()
            local ref, err = Owners.resolveOwnerRef('GANG', { job = { name = 'unemployed' }, gang = { name = 'lostmc' } })
            assertTrue(ref, "ref should resolve")
            assertEqual(ref.type, CZCraft.OwnerType.GANG, "type GANG")
            assertEqual(ref.id, 'lostmc', "id gang name")
        end,
    },
    {
        name = "ownerRef GANG fails for none",
        test = function()
            local ref, err = Owners.resolveOwnerRef('GANG', { job = { name = 'unemployed' }, gang = { name = 'none' } })
            assertFalse(ref, "ref should not resolve")
            assertContains(err, "gang", "reason mentions gang")
        end,
    },
    {
        name = "ownerRef unknown context fails",
        test = function()
            local ref, err = Owners.resolveOwnerRef('ALIEN', { citizenid = 'CIT123' })
            assertFalse(ref, "ref should not resolve")
            assertContains(err, "unknown context", "reason mentions unknown context")
        end,
    },
    {
        name = "isValidOwnerRef accepts valid PLAYER ref",
        test = function()
            local ok = Owners.isValidOwnerRef({ type = CZCraft.OwnerType.PLAYER, id = 'CIT123' })
            assertTrue(ok, "should be valid")
        end,
    },
    {
        name = "isValidOwnerRef rejects empty id",
        test = function()
            local ok = Owners.isValidOwnerRef({ type = CZCraft.OwnerType.PLAYER, id = '' })
            assertFalse(ok, "should be invalid")
        end,
    },
    {
        name = "isValidOwnerRef rejects unknown type",
        test = function()
            local ok = Owners.isValidOwnerRef({ type = 'ALIEN', id = 'x' })
            assertFalse(ok, "should be invalid")
        end,
    },
}
