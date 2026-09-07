-- qb-czcraft placement validation tests
-- Pure tests for HOUSE and ORG placement validation: transform/proximity,
-- allow-list, shell bounds, clearance, caps, plot polygon/z-range, owner
-- context match, membership.

dofile("resources/[meus-scripts]/qb-czcraft/shared/constants.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/machines.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/plots.lua")
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

local function makeTransform(x, y, z, heading)
    return { pos_x = x or 100.0, pos_y = y or 200.0, pos_z = z or 30.0, heading = heading or 0.0 }
end

local function makePedCoords(x, y, z)
    return { x = x or 100.0, y = y or 200.0, z = z or 30.0 }
end

local function makeHouseAccess(opts)
    opts = opts or {}
    local isOwner = true
    if opts.isOwner ~= nil then isOwner = opts.isOwner end
    local isKeyholder = false
    if opts.isKeyholder ~= nil then isKeyholder = opts.isKeyholder end
    local insideHouseId = opts.insideHouseId
    if insideHouseId == nil then insideHouseId = 'house_1' end
    return {
        isOwner = isOwner,
        isKeyholder = isKeyholder,
        insideHouseId = insideHouseId,
        shellBounds = opts.shellBounds,
    }
end

local function makeValidHouseParams(opts)
    opts = opts or {}
    return {
        transform = opts.transform or makeTransform(),
        machineType = opts.machineType or CZCraft.MachineType.WORKBENCH,
        machinesConfig = CZCraft.Config.Machines,
        fixtureCaps = { HOUSE = 4, ORG = 20 },
        houseAccess = opts.houseAccess or makeHouseAccess(),
        existingMachines = opts.existingMachines or {},
        pedCoords = opts.pedCoords or makePedCoords(),
        maxProximity = opts.maxProximity or 5.0,
        ownerRef = opts.ownerRef or { type = CZCraft.OwnerType.PLAYER, id = 'CITIZEN123' },
    }
end

return {
    {
        name = "HOUSE placement happy path passes",
        test = function()
            local r = Machines.validateHousePlacement(makeValidHouseParams())
            assertTrue(r.ok, "should pass")
            assertEqual(r.location.type, CZCraft.LocationType.HOUSE, "location type")
            assertEqual(r.location.id, 'house_1', "location id")
            assertEqual(r.machineConfig.type, CZCraft.MachineType.WORKBENCH, "machine config")
        end,
    },
    {
        name = "HOUSE placement fails when player not inside a house",
        test = function()
            local params = makeValidHouseParams({ houseAccess = makeHouseAccess({ insideHouseId = '' }) })
            local r = Machines.validateHousePlacement(params)
            assertFalse(r.ok, "should fail")
            assertContains(r.reason, "inside a house", "reason mentions inside")
        end,
    },
    {
        name = "HOUSE placement fails when neither owner nor keyholder",
        test = function()
            local params = makeValidHouseParams({ houseAccess = makeHouseAccess({ isOwner = false, isKeyholder = false }) })
            local r = Machines.validateHousePlacement(params)
            assertFalse(r.ok, "should fail")
            assertContains(r.reason, "owner or a keyholder", "reason mentions owner/keyholder")
        end,
    },
    {
        name = "HOUSE placement keyholder allowed",
        test = function()
            local params = makeValidHouseParams({ houseAccess = makeHouseAccess({ isOwner = false, isKeyholder = true }) })
            local r = Machines.validateHousePlacement(params)
            assertTrue(r.ok, "keyholder should pass")
        end,
    },
    {
        name = "HOUSE placement fails for non-allow-listed machine type",
        test = function()
            local params = makeValidHouseParams({ machineType = 'teleporter' })
            local r = Machines.validateHousePlacement(params)
            assertFalse(r.ok, "should fail")
            assertContains(r.reason, "not in allow-list", "reason mentions allow-list")
        end,
    },
    {
        name = "HOUSE placement fails when transform is non-finite",
        test = function()
            local params = makeValidHouseParams({ transform = { pos_x = math.huge, pos_y = 200, pos_z = 30, heading = 0 } })
            local r = Machines.validateHousePlacement(params)
            assertFalse(r.ok, "should fail")
            assertContains(r.reason, "finite", "reason mentions finite")
        end,
    },
    {
        name = "HOUSE placement fails when too far from ped",
        test = function()
            local params = makeValidHouseParams({
                transform = makeTransform(500, 500, 30),
                pedCoords = makePedCoords(100, 200, 30),
            })
            local r = Machines.validateHousePlacement(params)
            assertFalse(r.ok, "should fail")
            assertContains(r.reason, "within", "reason mentions proximity")
        end,
    },
    {
        name = "HOUSE placement fails when outside shell bounds",
        test = function()
            local params = makeValidHouseParams({
                transform = makeTransform(500, 200, 30),
                pedCoords = makePedCoords(500, 200, 30),
                houseAccess = makeHouseAccess({ shellBounds = { minX = 90, maxX = 110, minY = 190, maxY = 210 } }),
            })
            local r = Machines.validateHousePlacement(params)
            assertFalse(r.ok, "should fail")
            assertContains(r.reason, "shell bounds", "reason mentions shell bounds")
        end,
    },
    {
        name = "HOUSE placement fails when cap reached",
        test = function()
            local existing = {}
            for i = 1, 4 do
                existing[i] = { location_type = CZCraft.LocationType.HOUSE, location_id = 'house_1', pos_x = 100 + i, pos_y = 200, pos_z = 30 }
            end
            local params = makeValidHouseParams({ existingMachines = existing })
            local r = Machines.validateHousePlacement(params)
            assertFalse(r.ok, "should fail")
            assertContains(r.reason, "cap reached", "reason mentions cap")
        end,
    },
    {
        name = "HOUSE placement fails when too close to existing machine",
        test = function()
            local existing = {
                { location_type = CZCraft.LocationType.HOUSE, location_id = 'house_1', pos_x = 100.5, pos_y = 200.0, pos_z = 30 },
            }
            local params = makeValidHouseParams({ existingMachines = existing })
            local r = Machines.validateHousePlacement(params)
            assertFalse(r.ok, "should fail")
            assertContains(r.reason, "too close", "reason mentions clearance")
        end,
    },
    {
        name = "HOUSE placement fails with invalid ownerRef",
        test = function()
            local params = makeValidHouseParams({ ownerRef = { type = 'ALIEN', id = 'x' } })
            local r = Machines.validateHousePlacement(params)
            assertFalse(r.ok, "should fail")
            assertContains(r.reason, "ownerRef", "reason mentions ownerRef")
        end,
    },
    {
        name = "ORG placement happy path passes with matching plot + owner",
        test = function()
            local plots = {
                {
                    id = 'plot_1', ownerType = CZCraft.OwnerType.JOB, ownerId = 'police',
                    zBounds = { min = 0, max = 100 },
                    polygon = { { x = 0, y = 0 }, { x = 100, y = 0 }, { x = 100, y = 100 }, { x = 0, y = 100 } },
                    machineCap = 5, placementClearance = 2.0,
                },
            }
            local params = {
                transform = makeTransform(50, 50, 30),
                machineType = CZCraft.MachineType.ASSEMBLY,
                machinesConfig = CZCraft.Config.Machines,
                plotsConfig = plots,
                fixtureCaps = { HOUSE = 4, ORG = 20 },
                ownerRef = { type = CZCraft.OwnerType.JOB, id = 'police' },
                orgAccess = { gradeKey = '2', isStillMember = true },
                existingMachines = {},
                pedCoords = makePedCoords(50, 50, 30),
                maxProximity = 5.0,
            }
            local r = Machines.validateOrgPlacement(params)
            assertTrue(r.ok, "should pass")
            assertEqual(r.location.type, CZCraft.LocationType.ORG, "location type ORG")
            assertEqual(r.location.id, 'plot_1', "location id plot_1")
        end,
    },
    {
        name = "ORG placement fails when transform outside plot polygon",
        test = function()
            local plots = {
                {
                    id = 'plot_1', ownerType = CZCraft.OwnerType.JOB, ownerId = 'police',
                    zBounds = { min = 0, max = 100 },
                    polygon = { { x = 0, y = 0 }, { x = 10, y = 0 }, { x = 10, y = 10 }, { x = 0, y = 10 } },
                    machineCap = 5, placementClearance = 2.0,
                },
            }
            local params = {
                transform = makeTransform(500, 500, 30),
                machineType = CZCraft.MachineType.ASSEMBLY,
                machinesConfig = CZCraft.Config.Machines,
                plotsConfig = plots,
                fixtureCaps = { HOUSE = 4, ORG = 20 },
                ownerRef = { type = CZCraft.OwnerType.JOB, id = 'police' },
                orgAccess = { gradeKey = '2', isStillMember = true },
                existingMachines = {},
                pedCoords = makePedCoords(500, 500, 30),
                maxProximity = 5.0,
            }
            local r = Machines.validateOrgPlacement(params)
            assertFalse(r.ok, "should fail")
            assertContains(r.reason, "not inside any configured ORG plot", "reason mentions plot")
        end,
    },
    {
        name = "ORG placement fails when z outside z-range",
        test = function()
            local plots = {
                {
                    id = 'plot_1', ownerType = CZCraft.OwnerType.JOB, ownerId = 'police',
                    zBounds = { min = 0, max = 50 },
                    polygon = { { x = 0, y = 0 }, { x = 100, y = 0 }, { x = 100, y = 100 }, { x = 0, y = 100 } },
                    machineCap = 5, placementClearance = 2.0,
                },
            }
            local params = {
                transform = makeTransform(50, 50, 200),
                machineType = CZCraft.MachineType.ASSEMBLY,
                machinesConfig = CZCraft.Config.Machines,
                plotsConfig = plots,
                fixtureCaps = { HOUSE = 4, ORG = 20 },
                ownerRef = { type = CZCraft.OwnerType.JOB, id = 'police' },
                orgAccess = { gradeKey = '2', isStillMember = true },
                existingMachines = {},
                pedCoords = makePedCoords(50, 50, 200),
                maxProximity = 5.0,
            }
            local r = Machines.validateOrgPlacement(params)
            assertFalse(r.ok, "should fail")
            assertContains(r.reason, "not inside any configured ORG plot", "z out of range treated as outside plot")
        end,
    },
    {
        name = "ORG placement fails when owner context does not match plot",
        test = function()
            local plots = {
                {
                    id = 'plot_1', ownerType = CZCraft.OwnerType.JOB, ownerId = 'police',
                    zBounds = { min = 0, max = 100 },
                    polygon = { { x = 0, y = 0 }, { x = 100, y = 0 }, { x = 100, y = 100 }, { x = 0, y = 100 } },
                    machineCap = 5, placementClearance = 2.0,
                },
            }
            local params = {
                transform = makeTransform(50, 50, 30),
                machineType = CZCraft.MachineType.ASSEMBLY,
                machinesConfig = CZCraft.Config.Machines,
                plotsConfig = plots,
                fixtureCaps = { HOUSE = 4, ORG = 20 },
                ownerRef = { type = CZCraft.OwnerType.GANG, id = 'lostmc' },
                orgAccess = { gradeKey = '2', isStillMember = true },
                existingMachines = {},
                pedCoords = makePedCoords(50, 50, 30),
                maxProximity = 5.0,
            }
            local r = Machines.validateOrgPlacement(params)
            assertFalse(r.ok, "should fail")
            assertContains(r.reason, "does not match", "reason mentions owner context mismatch")
        end,
    },
    {
        name = "ORG placement fails when membership revoked",
        test = function()
            local plots = {
                {
                    id = 'plot_1', ownerType = CZCraft.OwnerType.JOB, ownerId = 'police',
                    zBounds = { min = 0, max = 100 },
                    polygon = { { x = 0, y = 0 }, { x = 100, y = 0 }, { x = 100, y = 100 }, { x = 0, y = 100 } },
                    machineCap = 5, placementClearance = 2.0,
                },
            }
            local params = {
                transform = makeTransform(50, 50, 30),
                machineType = CZCraft.MachineType.ASSEMBLY,
                machinesConfig = CZCraft.Config.Machines,
                plotsConfig = plots,
                fixtureCaps = { HOUSE = 4, ORG = 20 },
                ownerRef = { type = CZCraft.OwnerType.JOB, id = 'police' },
                orgAccess = { gradeKey = '2', isStillMember = false },
                existingMachines = {},
                pedCoords = makePedCoords(50, 50, 30),
                maxProximity = 5.0,
            }
            local r = Machines.validateOrgPlacement(params)
            assertFalse(r.ok, "should fail")
            assertContains(r.reason, "no longer a member", "reason mentions membership")
        end,
    },
    {
        name = "ORG placement fails when plot cap reached",
        test = function()
            local plots = {
                {
                    id = 'plot_1', ownerType = CZCraft.OwnerType.JOB, ownerId = 'police',
                    zBounds = { min = 0, max = 100 },
                    polygon = { { x = 0, y = 0 }, { x = 100, y = 0 }, { x = 100, y = 100 }, { x = 0, y = 100 } },
                    machineCap = 2, placementClearance = 2.0,
                },
            }
            local existing = {
                { location_type = CZCraft.LocationType.ORG, location_id = 'plot_1', pos_x = 10, pos_y = 10, pos_z = 30 },
                { location_type = CZCraft.LocationType.ORG, location_id = 'plot_1', pos_x = 90, pos_y = 90, pos_z = 30 },
            }
            local params = {
                transform = makeTransform(50, 50, 30),
                machineType = CZCraft.MachineType.ASSEMBLY,
                machinesConfig = CZCraft.Config.Machines,
                plotsConfig = plots,
                fixtureCaps = { HOUSE = 4, ORG = 20 },
                ownerRef = { type = CZCraft.OwnerType.JOB, id = 'police' },
                orgAccess = { gradeKey = '2', isStillMember = true },
                existingMachines = existing,
                pedCoords = makePedCoords(50, 50, 30),
                maxProximity = 5.0,
            }
            local r = Machines.validateOrgPlacement(params)
            assertFalse(r.ok, "should fail")
            assertContains(r.reason, "cap reached", "reason mentions cap")
        end,
    },
    {
        name = "pointInPolygon: point inside square is true",
        test = function()
            local poly = { { x = 0, y = 0 }, { x = 10, y = 0 }, { x = 10, y = 10 }, { x = 0, y = 10 } }
            assertTrue(Machines.pointInPolygon(poly, 5, 5), "center inside")
        end,
    },
    {
        name = "pointInPolygon: point outside square is false",
        test = function()
            local poly = { { x = 0, y = 0 }, { x = 10, y = 0 }, { x = 10, y = 10 }, { x = 0, y = 10 } }
            assertFalse(Machines.pointInPolygon(poly, 50, 50), "far outside")
        end,
    },
}
