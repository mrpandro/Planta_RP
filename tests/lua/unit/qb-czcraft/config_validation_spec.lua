-- qb-czcraft config validation tests
-- Uses isolated deep-copied fixtures and an injected fake item registry.
-- Covers happy path plus aggregated failures for all documented edge cases,
-- and a baseline transitional-state test against the actual checked-in config.

-- Load constants first to set up the CZCraft global with domain identifiers.
dofile("resources/[meus-scripts]/qb-czcraft/shared/constants.lua")
-- Load the actual checked-in config files (for baseline transitional-state test).
dofile("resources/[meus-scripts]/qb-czcraft/config/general.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/machines.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/access.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/plots.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/recipes.lua")
-- Load the pure validator module (returns CZCraft.validateConfig).
local validateConfig = dofile("resources/[meus-scripts]/qb-czcraft/shared/validation.lua")

local UNRESOLVED = CZCraft.UNRESOLVED

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

-- Deep copy helper for isolated fixtures.
local function deepCopy(value)
    if type(value) ~= 'table' then
        return value
    end
    local copy = {}
    for key, val in pairs(value) do
        copy[key] = deepCopy(val)
    end
    return copy
end

-- Builds a complete fake item registry with all items referenced by the MVP catalog.
local function buildFullItemRegistry()
    local registry = {}

    -- Existing QBCore items (with weight in grams).
    local existingItems = {
        metalscrap = 100, iron = 100, steel = 100, copper = 100, aluminum = 100,
        plastic = 100, rubber = 100, screwdriverset = 1000, lockpick = 300,
        repairkit = 2500, pistol_ammo = 200, weapon_pistol = 1000,
    }
    for name, weight in pairs(existingItems) do
        registry[name] = { name = name, weight = weight, type = 'item', unique = false }
    end

    -- cz_* component items (deferred in production, present in test fixtures).
    local componentItems = {
        cz_copper_wire = 50, cz_aluminum_sheet = 200, cz_metal_parts = 150,
        cz_casing = 100, cz_electronics = 80, cz_mechanical_parts = 200,
        cz_components = 300, cz_receiver = 500,
    }
    for name, weight in pairs(componentItems) do
        registry[name] = { name = name, weight = weight, type = 'item', unique = false }
    end

    -- Machine items (unique=true as documented).
    local machineItems = {
        cz_workbench_machine = 5000, cz_refinery_machine = 15000,
        cz_fabricator_machine = 25000, cz_assembly_machine = 40000,
    }
    for name, weight in pairs(machineItems) do
        registry[name] = { name = name, weight = weight, type = 'item', unique = true }
    end

    return registry
end

-- Builds a fully valid config fixture with all overrides resolved.
local function buildValidConfig()
    return {
        General = {
            resourceName = 'qb-czcraft',
            version = '0.1.0',
            features = {
                placement = false, storageTransfers = false, bills = false,
                production = false, scheduler = false, nui = false,
                repairkit = false, admin = false,
            },
            fixtureCaps = { HOUSE = 4, ORG = 20 },
            maxBillsPerMachine = 5,
        },
        Machines = {
            {
                type = 'workbench', displayKey = 'machine.workbench.name',
                item = 'cz_workbench_machine', price = 5000, stockCapacity = 100000,
                prop = 'prop_tool_bench02', itemWeight = 5000, placementClearance = 1.5,
            },
            {
                type = 'refinery', displayKey = 'machine.refinery.name',
                item = 'cz_refinery_machine', price = 15000, stockCapacity = 250000,
                prop = 'gr_prop_gr_bench_01a', itemWeight = 15000, placementClearance = 2.0,
            },
            {
                type = 'fabricator', displayKey = 'machine.fabricator.name',
                item = 'cz_fabricator_machine', price = 25000, stockCapacity = 200000,
                prop = 'gr_prop_gr_bench_03a', itemWeight = 25000, placementClearance = 2.0,
            },
            {
                type = 'assembly', displayKey = 'machine.assembly.name',
                item = 'cz_assembly_machine', price = 40000, stockCapacity = 300000,
                prop = 'prop_tool_bench02_ld', itemWeight = 40000, placementClearance = 2.5,
            },
        },
        Access = {
            ownerTypes = { 'PLAYER', 'JOB', 'GANG' },
            permissions = { 'OWNER', 'MANAGER', 'PRODUCTION', 'WITHDRAW', 'DEPOSIT', 'VIEW' },
            jobGrades = {},
            gangGrades = {},
            tags = {
                CIVIL = { jobs = {}, gangs = {} },
                ORG_WEAPONS = { jobs = { 'police' }, gangs = { 'lostmc', 'ballas', 'vagos', 'cartel', 'families', 'triads' } },
            },
        },
        Plots = {},
        Recipes = deepCopy(CZCraft.Config.Recipes),
    }
end

-- Finds an error by path prefix in the error list.
local function hasErrorWithPath(errors, pathPrefix)
    for _, err in ipairs(errors) do
        if string.sub(err.path, 1, #pathPrefix) == pathPrefix then
            return true
        end
    end
    return false
end

-- Finds an error by exact path match.
local function hasErrorWithExactPath(errors, exactPath)
    for _, err in ipairs(errors) do
        if err.path == exactPath then
            return true
        end
    end
    return false
end

return {
    {
        name = "happy path: fully valid config with all overrides and items is ready",
        test = function()
            local config = buildValidConfig()
            local registry = buildFullItemRegistry()

            local result = validateConfig(config, registry)

            assertTrue(result.isReady, "valid config should be ready")
            if #result.errors > 0 then
                local messages = {}
                for _, err in ipairs(result.errors) do
                    messages[#messages + 1] = err.path .. ": " .. err.message
                end
                error("Expected no errors but got: " .. table.concat(messages, "\n"))
            end
            assertEqual(#result.errors, 0, "error count should be zero")
        end,
    },
    {
        name = "unresolved maxBillsPerMachine is reported as a blocker",
        test = function()
            local config = buildValidConfig()
            config.General.maxBillsPerMachine = UNRESOLVED

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'general.maxBillsPerMachine'), "should report unresolved maxBillsPerMachine")
        end,
    },
    {
        name = "non-numeric maxBillsPerMachine is reported",
        test = function()
            local config = buildValidConfig()
            config.General.maxBillsPerMachine = "five"

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'general.maxBillsPerMachine'), "should report invalid maxBillsPerMachine")
        end,
    },
    {
        name = "non-boolean feature flag is reported",
        test = function()
            local config = buildValidConfig()
            config.General.features.production = "yes"

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'general.features.production'), "should report invalid feature flag type")
        end,
    },
    {
        name = "non-positive fixture cap is reported",
        test = function()
            local config = buildValidConfig()
            config.General.fixtureCaps.HOUSE = 0

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'general.fixtureCaps.HOUSE'), "should report invalid fixture cap")
        end,
    },
    {
        name = "unknown location type in fixture caps is reported",
        test = function()
            local config = buildValidConfig()
            config.General.fixtureCaps.WAREHOUSE = 10

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'general.fixtureCaps.WAREHOUSE'), "should report unknown location type")
        end,
    },
    {
        name = "unresolved machine itemWeight is reported for each machine",
        test = function()
            local config = buildValidConfig()
            config.Machines[1].itemWeight = UNRESOLVED
            config.Machines[2].itemWeight = UNRESOLVED

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'machines[1].itemWeight'), "should report machine[1] itemWeight")
            assertTrue(hasErrorWithExactPath(result.errors, 'machines[2].itemWeight'), "should report machine[2] itemWeight")
        end,
    },
    {
        name = "unresolved placement clearance is reported for each machine",
        test = function()
            local config = buildValidConfig()
            config.Machines[3].placementClearance = UNRESOLVED

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'machines[3].placementClearance'), "should report machine[3] placementClearance")
        end,
    },
    {
        name = "non-approved prop is reported",
        test = function()
            local config = buildValidConfig()
            config.Machines[1].prop = 'prop_unknown_thing'

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'machines[1].prop'), "should report non-approved prop")
        end,
    },
    {
        name = "duplicate machine type is reported",
        test = function()
            local config = buildValidConfig()
            config.Machines[2].type = 'workbench'

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'machines[2].type'), "should report duplicate machine type")
        end,
    },
    {
        name = "duplicate machine item is reported",
        test = function()
            local config = buildValidConfig()
            config.Machines[2].item = 'cz_workbench_machine'

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'machines[2].item'), "should report duplicate machine item")
        end,
    },
    {
        name = "missing QBCore item for machine is reported",
        test = function()
            local config = buildValidConfig()
            local registry = buildFullItemRegistry()
            registry['cz_workbench_machine'] = nil

            local result = validateConfig(config, registry)

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'machines[1].item'), "should report missing machine item")
        end,
    },
    {
        name = "machine item without unique=true is reported",
        test = function()
            local config = buildValidConfig()
            local registry = buildFullItemRegistry()
            registry['cz_refinery_machine'].unique = false

            local result = validateConfig(config, registry)

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'machines[2].item'), "should report machine item not unique")
        end,
    },
    {
        name = "machine item with unusable weight is reported",
        test = function()
            local config = buildValidConfig()
            local registry = buildFullItemRegistry()
            registry['cz_fabricator_machine'].weight = "heavy"

            local result = validateConfig(config, registry)

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'machines[3].item'), "should report unusable machine item weight")
        end,
    },
    {
        name = "missing QBCore item for recipe input is reported",
        test = function()
            local config = buildValidConfig()
            local registry = buildFullItemRegistry()
            registry['metalscrap'] = nil

            local result = validateConfig(config, registry)

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'recipes[1].inputs[1].item'), "should report missing recipe input item")
        end,
    },
    {
        name = "missing QBCore item for recipe output is reported",
        test = function()
            local config = buildValidConfig()
            local registry = buildFullItemRegistry()
            registry['cz_copper_wire'] = nil

            local result = validateConfig(config, registry)

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'recipes[3].outputs[1].item'), "should report missing recipe output item")
        end,
    },
    {
        name = "duplicate recipe ID is reported",
        test = function()
            local config = buildValidConfig()
            config.Recipes[2].id = 'reclaim_iron'

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'recipes[2].id'), "should report duplicate recipe ID")
        end,
    },
    {
        name = "duplicate item line within recipe inputs is reported",
        test = function()
            local config = buildValidConfig()
            -- smelt_steel has inputs: iron x5, metalscrap x2. Make a duplicate iron line.
            config.Recipes[2].inputs[2].item = 'iron'

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'recipes[2].inputs[2].item'), "should report duplicate item in inputs")
        end,
    },
    {
        name = "unknown machine reference in recipe is reported",
        test = function()
            local config = buildValidConfig()
            config.Recipes[1].machine = 'teleporter'

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'recipes[1].machine'), "should report unknown machine reference")
        end,
    },
    {
        name = "unknown access tag in recipe is reported",
        test = function()
            local config = buildValidConfig()
            config.Recipes[1].access = 'MILITARY'

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'recipes[1].access'), "should report unknown access tag")
        end,
    },
    {
        name = "empty recipe inputs are reported",
        test = function()
            local config = buildValidConfig()
            config.Recipes[1].inputs = {}

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'recipes[1].inputs'), "should report empty inputs")
        end,
    },
    {
        name = "empty recipe outputs are reported",
        test = function()
            local config = buildValidConfig()
            config.Recipes[1].outputs = {}

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'recipes[1].outputs'), "should report empty outputs")
        end,
    },
    {
        name = "non-positive recipe duration is reported",
        test = function()
            local config = buildValidConfig()
            config.Recipes[1].duration = 0

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'recipes[1].duration'), "should report invalid duration")
        end,
    },
    {
        name = "non-integer recipe amount is reported",
        test = function()
            local config = buildValidConfig()
            config.Recipes[1].inputs[1].amount = 2.5

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'recipes[1].inputs[1].amount'), "should report non-integer amount")
        end,
    },
    {
        name = "missing primaryOutput in outputs is reported",
        test = function()
            local config = buildValidConfig()
            config.Recipes[1].primaryOutput = 'steel'

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'recipes[1].primaryOutput'), "should report primaryOutput not in outputs")
        end,
    },
    {
        name = "unknown permission in grade grants is reported",
        test = function()
            local config = buildValidConfig()
            config.Access.jobGrades = { police = { 'OWNER', 'DELETE_EVERYTHING' } }

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithPath(result.errors, 'access.jobGrades'), "should report unknown permission in grade grants")
        end,
    },
    {
        name = "empty deny-all grade maps are valid",
        test = function()
            local config = buildValidConfig()
            config.Access.jobGrades = {}
            config.Access.gangGrades = {}

            local result = validateConfig(config, buildFullItemRegistry())

            assertTrue(result.isReady, "empty grade maps should be valid")
            assertEqual(#result.errors, 0, "no errors expected")
        end,
    },
    {
        name = "malformed plot with non-finite z bounds is reported",
        test = function()
            local config = buildValidConfig()
            config.Plots = {
                {
                    id = 'plot_1', ownerType = 'JOB', ownerId = 'police',
                    zBounds = { min = math.huge, max = 100 },
                    polygon = { { x = 1, y = 2 }, { x = 3, y = 4 } },
                    machineCap = 20, placementClearance = 2.0,
                },
            }

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'plots[1].zBounds.min'), "should report non-finite z bound")
        end,
    },
    {
        name = "malformed plot with non-finite polygon coordinates is reported",
        test = function()
            local config = buildValidConfig()
            config.Plots = {
                {
                    id = 'plot_2', ownerType = 'GANG', ownerId = 'ballas',
                    zBounds = { min = 0, max = 100 },
                    polygon = { { x = 1, y = 2 }, { x = math.huge, y = 4 } },
                    machineCap = 20, placementClearance = 2.0,
                },
            }

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'plots[1].polygon[2].x'), "should report non-finite polygon coordinate")
        end,
    },
    {
        name = "plot with invalid ownerType is reported",
        test = function()
            local config = buildValidConfig()
            config.Plots = {
                {
                    id = 'plot_3', ownerType = 'PLAYER', ownerId = 'abc',
                    zBounds = { min = 0, max = 100 },
                    polygon = { { x = 1, y = 2 } },
                    machineCap = 20, placementClearance = 2.0,
                },
            }

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(hasErrorWithExactPath(result.errors, 'plots[1].ownerType'), "should report invalid plot ownerType")
        end,
    },
    {
        name = "empty plots collection is valid",
        test = function()
            local config = buildValidConfig()
            config.Plots = {}

            local result = validateConfig(config, buildFullItemRegistry())

            assertTrue(result.isReady, "empty plots should be valid")
            assertEqual(#result.errors, 0, "no errors expected")
        end,
    },
    {
        name = "multiple errors are aggregated in deterministic order",
        test = function()
            local config = buildValidConfig()
            -- Introduce multiple errors across different sections.
            config.General.maxBillsPerMachine = UNRESOLVED
            config.Machines[1].itemWeight = UNRESOLVED
            config.Recipes[1].duration = 0

            local result = validateConfig(config, buildFullItemRegistry())

            assertFalse(result.isReady, "should not be ready")
            assertTrue(#result.errors >= 3, "should aggregate at least 3 errors, got " .. #result.errors)

            -- General errors should come before machine errors, which come before recipe errors.
            local foundGeneral = false
            local foundMachine = false
            local foundRecipe = false
            local generalIndex = 0
            local machineIndex = 0
            local recipeIndex = 0

            for index, err in ipairs(result.errors) do
                if err.path == 'general.maxBillsPerMachine' then
                    foundGeneral = true
                    generalIndex = index
                elseif err.path == 'machines[1].itemWeight' then
                    foundMachine = true
                    machineIndex = index
                elseif err.path == 'recipes[1].duration' then
                    foundRecipe = true
                    recipeIndex = index
                end
            end

            assertTrue(foundGeneral, "should find general error")
            assertTrue(foundMachine, "should find machine error")
            assertTrue(foundRecipe, "should find recipe error")
            assertTrue(generalIndex < machineIndex, "general error should come before machine error")
            assertTrue(machineIndex < recipeIndex, "machine error should come before recipe error")
        end,
    },
    {
        name = "baseline: placement/bills/production/scheduler/nui flags enabled in checked-in config",
        test = function()
            local features = CZCraft.Config.General.features
            -- Part 1: placement; Part 3: bills, production, scheduler; NUI task 5.
            assertEqual(features.placement, true, "placement should be enabled")
            assertEqual(features.bills, true, "bills should be enabled")
            assertEqual(features.production, true, "production should be enabled")
            assertEqual(features.scheduler, true, "scheduler should be enabled")
            assertEqual(features.nui, true, "nui should be enabled")
            -- Remaining flags stay disabled until their parts land.
            assertEqual(features.storageTransfers, false, "storageTransfers disabled")
            assertEqual(features.repairkit, false, "repairkit disabled")
            assertEqual(features.admin, false, "admin disabled")
        end,
    },
    {
        name = "baseline: fixture caps are 4 HOUSE and 20 ORG in checked-in config",
        test = function()
            assertEqual(CZCraft.Config.General.fixtureCaps.HOUSE, 4, "HOUSE fixture cap")
            assertEqual(CZCraft.Config.General.fixtureCaps.ORG, 20, "ORG fixture cap")
        end,
    },
    {
        name = "baseline: deny-all grade maps remain empty in checked-in config",
        test = function()
            local access = CZCraft.Config.Access
            assertEqual(next(access.jobGrades), nil, "jobGrades should be empty")
            assertEqual(next(access.gangGrades), nil, "gangGrades should be empty")
        end,
    },
    {
        name = "baseline: selected props are in the approved allow-list",
        test = function()
            for _, machine in ipairs(CZCraft.Config.Machines) do
                assertTrue(CZCraft.ApprovedProps[machine.prop], "machine " .. machine.type .. " prop should be approved: " .. machine.prop)
            end
        end,
    },
    {
        name = "baseline: checked-in config becomes ready with a complete item registry",
        test = function()
            -- The checked-in config now has all balance overrides resolved and all
            -- cz_* items defined in qb-core/shared/items.lua. With a complete registry,
            -- the validator should report readiness=true.
            local registry = buildFullItemRegistry()

            local config = {
                General = CZCraft.Config.General,
                Machines = CZCraft.Config.Machines,
                Access = CZCraft.Config.Access,
                Plots = CZCraft.Config.Plots,
                Recipes = CZCraft.Config.Recipes,
            }

            local result = validateConfig(config, registry)

            if not result.isReady then
                local messages = {}
                for _, err in ipairs(result.errors) do
                    messages[#messages + 1] = err.path .. ": " .. err.message
                end
                error("Checked-in config should be ready but got blockers: " .. table.concat(messages, "\n"))
            end
            assertTrue(result.isReady, "checked-in config should be ready with complete registry")
            assertEqual(#result.errors, 0, "no errors expected with complete registry")
        end,
    },
    {
        name = "baseline: checked-in config reports missing-item blockers when registry lacks cz_* items",
        test = function()
            -- Simulates a registry without the cz_* items (pre-item-definition state).
            -- The config itself is valid (no unresolved sentinels), so only item
            -- cross-reference failures should appear.
            local registry = {
                metalscrap = { name = 'metalscrap', weight = 100, type = 'item', unique = false },
                iron = { name = 'iron', weight = 100, type = 'item', unique = false },
                steel = { name = 'steel', weight = 100, type = 'item', unique = false },
                copper = { name = 'copper', weight = 100, type = 'item', unique = false },
                aluminum = { name = 'aluminum', weight = 100, type = 'item', unique = false },
                plastic = { name = 'plastic', weight = 100, type = 'item', unique = false },
                rubber = { name = 'rubber', weight = 100, type = 'item', unique = false },
                screwdriverset = { name = 'screwdriverset', weight = 1000, type = 'item', unique = false },
                lockpick = { name = 'lockpick', weight = 300, type = 'item', unique = false },
                repairkit = { name = 'repairkit', weight = 2500, type = 'item', unique = false },
                pistol_ammo = { name = 'pistol_ammo', weight = 200, type = 'item', unique = false },
                weapon_pistol = { name = 'weapon_pistol', weight = 1000, type = 'item', unique = false },
            }

            local config = {
                General = CZCraft.Config.General,
                Machines = CZCraft.Config.Machines,
                Access = CZCraft.Config.Access,
                Plots = CZCraft.Config.Plots,
                Recipes = CZCraft.Config.Recipes,
            }

            local result = validateConfig(config, registry)

            assertFalse(result.isReady, "should not be ready without cz_* items")
            -- Should report missing machine items and missing component items,
            -- but NOT unresolved sentinels (those are now resolved).
            local hasMissingMachineItem = hasErrorWithExactPath(result.errors, 'machines[1].item')
            local hasMissingComponentItem = hasErrorWithPath(result.errors, 'recipes[3].outputs[1].item')
            local hasUnresolvedMaxBills = hasErrorWithExactPath(result.errors, 'general.maxBillsPerMachine')
            local hasUnresolvedItemWeight = hasErrorWithExactPath(result.errors, 'machines[1].itemWeight')

            assertTrue(hasMissingMachineItem, "should report missing machine item")
            assertTrue(hasMissingComponentItem, "should report missing cz_* component item")
            assertFalse(hasUnresolvedMaxBills, "should NOT report unresolved maxBillsPerMachine (resolved)")
            assertFalse(hasUnresolvedItemWeight, "should NOT report unresolved itemWeight (resolved)")
        end,
    },
    {
        name = "baseline: all machine balance overrides are resolved (no UNRESOLVED sentinels)",
        test = function()
            for index, machine in ipairs(CZCraft.Config.Machines) do
                assertFalse(machine.itemWeight == CZCraft.UNRESOLVED, "machine[" .. index .. "] itemWeight should be resolved")
                assertFalse(machine.placementClearance == CZCraft.UNRESOLVED, "machine[" .. index .. "] placementClearance should be resolved")
            end
            assertFalse(CZCraft.Config.General.maxBillsPerMachine == CZCraft.UNRESOLVED, "maxBillsPerMachine should be resolved")
        end,
    },
    {
        name = "baseline: checked-in config has exactly 4 machines and 15 recipes",
        test = function()
            assertEqual(#CZCraft.Config.Machines, 4, "machine count")
            assertEqual(#CZCraft.Config.Recipes, 15, "recipe count")
        end,
    },
    {
        name = "baseline: ORG_WEAPONS allow-list matches documented job and gangs",
        test = function()
            local tag = CZCraft.Config.Access.tags.ORG_WEAPONS
            assertEqual(#tag.jobs, 1, "ORG_WEAPONS job count")
            assertEqual(tag.jobs[1], 'police', "ORG_WEAPONS job")
            assertEqual(#tag.gangs, 6, "ORG_WEAPONS gang count")

            local expectedGangs = { lostmc = true, ballas = true, vagos = true, cartel = true, families = true, triads = true }
            for _, gang in ipairs(tag.gangs) do
                assertTrue(expectedGangs[gang], "gang " .. gang .. " should be in expected list")
                expectedGangs[gang] = nil
            end
            assertEqual(next(expectedGangs), nil, "all expected gangs should be present")
        end,
    },
}
