-- qb-czcraft recipe catalog tests
-- Verifies the exact 15 IDs/order, four machine groupings, 12/3 access split,
-- all documented amounts/durations/primary outputs, duplicate rejection, and
-- non-overwriting indexes. Follows the table-returning *_spec.lua convention.

-- Load constants first to set up the CZCraft global with domain identifiers.
dofile("resources/[meus-scripts]/qb-czcraft/shared/constants.lua")
-- Load the recipe config which references CZCraft.MachineType and CZCraft.AccessTag.
dofile("resources/[meus-scripts]/qb-czcraft/config/recipes.lua")
-- Load the pure catalog builder module (returns CZCraft.buildRecipeCatalog).
local buildRecipeCatalog = dofile("resources/[meus-scripts]/qb-czcraft/shared/recipe_catalog.lua")

local Recipes = CZCraft.Config.Recipes

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

local function assertEqualTable(actual, expected, message)
    if type(actual) ~= 'table' or type(expected) ~= 'table' then
        error((message or "Table assertion failed") .. " | one side is not a table")
    end
    for key, value in pairs(expected) do
        if actual[key] ~= value then
            error((message or "Table mismatch") .. " | key=" .. tostring(key) .. " expected=" .. tostring(value) .. ", actual=" .. tostring(actual[key]))
        end
    end
end

return {
    {
        name = "catalog contains exactly 15 recipes in the documented order",
        test = function()
            local catalog, errors = buildRecipeCatalog(Recipes)
            assertTrue(catalog, "catalog should build without errors")
            assertEqual(errors, nil, "no errors expected")

            local expectedIds = {
                'reclaim_iron', 'smelt_steel', 'draw_copper_wire', 'roll_aluminum_sheet',
                'make_metal_parts', 'make_casing', 'make_electronics', 'make_mechanical_parts', 'make_components',
                'assemble_screwdriverset', 'assemble_lockpick',
                'assemble_repairkit', 'assemble_pistol_ammo', 'assemble_receiver', 'assemble_pistol',
            }

            assertEqual(#catalog.order, 15, "recipe count")
            for index, expectedId in ipairs(expectedIds) do
                assertEqual(catalog.order[index], expectedId, "recipe order[" .. index .. "]")
            end
        end,
    },
    {
        name = "recipes are grouped into four machine types with documented counts",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)

            -- Refinery: 4 recipes
            assertEqual(#catalog.byMachine['refinery'], 4, "refinery recipe count")
            -- Fabricator: 5 recipes
            assertEqual(#catalog.byMachine['fabricator'], 5, "fabricator recipe count")
            -- Workbench: 2 recipes
            assertEqual(#catalog.byMachine['workbench'], 2, "workbench recipe count")
            -- Assembly: 4 recipes
            assertEqual(#catalog.byMachine['assembly'], 4, "assembly recipe count")
        end,
    },
    {
        name = "access split is 12 CIVIL and 3 ORG_WEAPONS",
        test = function()
            local civilCount = 0
            local orgWeaponsCount = 0

            for _, recipe in ipairs(Recipes) do
                if recipe.access == 'CIVIL' then
                    civilCount = civilCount + 1
                elseif recipe.access == 'ORG_WEAPONS' then
                    orgWeaponsCount = orgWeaponsCount + 1
                end
            end

            assertEqual(civilCount, 12, "CIVIL recipe count")
            assertEqual(orgWeaponsCount, 3, "ORG_WEAPONS recipe count")
        end,
    },
    {
        name = "reclaim_iron has documented inputs/outputs/duration/primaryOutput",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)
            local entry = catalog.byId['reclaim_iron']
            assertTrue(entry, "reclaim_iron should be in catalog")
            local recipe = entry.recipe

            assertEqual(recipe.machine, 'refinery', "reclaim_iron machine")
            assertEqual(recipe.duration, 45, "reclaim_iron duration")
            assertEqual(recipe.access, 'CIVIL', "reclaim_iron access")
            assertEqual(recipe.primaryOutput, 'iron', "reclaim_iron primaryOutput")
            assertEqual(#recipe.inputs, 1, "reclaim_iron input count")
            assertEqualTable(recipe.inputs[1], { item = 'metalscrap', amount = 5 }, "reclaim_iron input[1]")
            assertEqual(#recipe.outputs, 1, "reclaim_iron output count")
            assertEqualTable(recipe.outputs[1], { item = 'iron', amount = 2 }, "reclaim_iron output[1]")
        end,
    },
    {
        name = "smelt_steel has documented inputs/outputs/duration/primaryOutput",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)
            local recipe = catalog.byId['smelt_steel'].recipe

            assertEqual(recipe.machine, 'refinery', "smelt_steel machine")
            assertEqual(recipe.duration, 60, "smelt_steel duration")
            assertEqual(recipe.access, 'CIVIL', "smelt_steel access")
            assertEqual(recipe.primaryOutput, 'steel', "smelt_steel primaryOutput")
            assertEqual(#recipe.inputs, 2, "smelt_steel input count")
            assertEqualTable(recipe.inputs[1], { item = 'iron', amount = 5 }, "smelt_steel input[1]")
            assertEqualTable(recipe.inputs[2], { item = 'metalscrap', amount = 2 }, "smelt_steel input[2]")
            assertEqual(#recipe.outputs, 1, "smelt_steel output count")
            assertEqualTable(recipe.outputs[1], { item = 'steel', amount = 2 }, "smelt_steel output[1]")
        end,
    },
    {
        name = "draw_copper_wire has documented inputs/outputs/duration/primaryOutput",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)
            local recipe = catalog.byId['draw_copper_wire'].recipe

            assertEqual(recipe.machine, 'refinery', "draw_copper_wire machine")
            assertEqual(recipe.duration, 45, "draw_copper_wire duration")
            assertEqual(recipe.primaryOutput, 'cz_copper_wire', "draw_copper_wire primaryOutput")
            assertEqualTable(recipe.inputs[1], { item = 'copper', amount = 3 }, "draw_copper_wire input[1]")
            assertEqualTable(recipe.outputs[1], { item = 'cz_copper_wire', amount = 6 }, "draw_copper_wire output[1]")
        end,
    },
    {
        name = "roll_aluminum_sheet has documented inputs/outputs/duration/primaryOutput",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)
            local recipe = catalog.byId['roll_aluminum_sheet'].recipe

            assertEqual(recipe.duration, 50, "roll_aluminum_sheet duration")
            assertEqual(recipe.primaryOutput, 'cz_aluminum_sheet', "roll_aluminum_sheet primaryOutput")
            assertEqualTable(recipe.inputs[1], { item = 'aluminum', amount = 4 }, "roll_aluminum_sheet input[1]")
            assertEqualTable(recipe.outputs[1], { item = 'cz_aluminum_sheet', amount = 2 }, "roll_aluminum_sheet output[1]")
        end,
    },
    {
        name = "make_metal_parts has documented inputs/outputs/duration/primaryOutput",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)
            local recipe = catalog.byId['make_metal_parts'].recipe

            assertEqual(recipe.machine, 'fabricator', "make_metal_parts machine")
            assertEqual(recipe.duration, 60, "make_metal_parts duration")
            assertEqual(recipe.primaryOutput, 'cz_metal_parts', "make_metal_parts primaryOutput")
            assertEqualTable(recipe.inputs[1], { item = 'steel', amount = 4 }, "make_metal_parts input[1]")
            assertEqualTable(recipe.outputs[1], { item = 'cz_metal_parts', amount = 4 }, "make_metal_parts output[1]")
        end,
    },
    {
        name = "make_casing has documented inputs/outputs/duration/primaryOutput",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)
            local recipe = catalog.byId['make_casing'].recipe

            assertEqual(recipe.duration, 60, "make_casing duration")
            assertEqual(recipe.primaryOutput, 'cz_casing', "make_casing primaryOutput")
            assertEqual(#recipe.inputs, 2, "make_casing input count")
            assertEqualTable(recipe.inputs[1], { item = 'cz_aluminum_sheet', amount = 2 }, "make_casing input[1]")
            assertEqualTable(recipe.inputs[2], { item = 'plastic', amount = 4 }, "make_casing input[2]")
            assertEqualTable(recipe.outputs[1], { item = 'cz_casing', amount = 2 }, "make_casing output[1]")
        end,
    },
    {
        name = "make_electronics has documented inputs/outputs/duration/primaryOutput",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)
            local recipe = catalog.byId['make_electronics'].recipe

            assertEqual(recipe.duration, 75, "make_electronics duration")
            assertEqual(recipe.primaryOutput, 'cz_electronics', "make_electronics primaryOutput")
            assertEqualTable(recipe.inputs[1], { item = 'cz_copper_wire', amount = 4 }, "make_electronics input[1]")
            assertEqualTable(recipe.inputs[2], { item = 'plastic', amount = 3 }, "make_electronics input[2]")
            assertEqualTable(recipe.outputs[1], { item = 'cz_electronics', amount = 2 }, "make_electronics output[1]")
        end,
    },
    {
        name = "make_mechanical_parts has documented inputs/outputs/duration/primaryOutput",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)
            local recipe = catalog.byId['make_mechanical_parts'].recipe

            assertEqual(recipe.duration, 75, "make_mechanical_parts duration")
            assertEqual(recipe.primaryOutput, 'cz_mechanical_parts', "make_mechanical_parts primaryOutput")
            assertEqualTable(recipe.inputs[1], { item = 'cz_metal_parts', amount = 3 }, "make_mechanical_parts input[1]")
            assertEqualTable(recipe.inputs[2], { item = 'rubber', amount = 2 }, "make_mechanical_parts input[2]")
            assertEqualTable(recipe.outputs[1], { item = 'cz_mechanical_parts', amount = 2 }, "make_mechanical_parts output[1]")
        end,
    },
    {
        name = "make_components has documented inputs/outputs/duration/primaryOutput",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)
            local recipe = catalog.byId['make_components'].recipe

            assertEqual(recipe.duration, 90, "make_components duration")
            assertEqual(recipe.primaryOutput, 'cz_components', "make_components primaryOutput")
            assertEqual(#recipe.inputs, 3, "make_components input count")
            assertEqualTable(recipe.inputs[1], { item = 'cz_metal_parts', amount = 2 }, "make_components input[1]")
            assertEqualTable(recipe.inputs[2], { item = 'cz_electronics', amount = 1 }, "make_components input[2]")
            assertEqualTable(recipe.inputs[3], { item = 'plastic', amount = 2 }, "make_components input[3]")
            assertEqualTable(recipe.outputs[1], { item = 'cz_components', amount = 2 }, "make_components output[1]")
        end,
    },
    {
        name = "assemble_screwdriverset has documented inputs/outputs/duration/primaryOutput",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)
            local recipe = catalog.byId['assemble_screwdriverset'].recipe

            assertEqual(recipe.machine, 'workbench', "assemble_screwdriverset machine")
            assertEqual(recipe.duration, 120, "assemble_screwdriverset duration")
            assertEqual(recipe.primaryOutput, 'screwdriverset', "assemble_screwdriverset primaryOutput")
            assertEqualTable(recipe.inputs[1], { item = 'cz_metal_parts', amount = 3 }, "assemble_screwdriverset input[1]")
            assertEqualTable(recipe.inputs[2], { item = 'plastic', amount = 2 }, "assemble_screwdriverset input[2]")
            assertEqualTable(recipe.outputs[1], { item = 'screwdriverset', amount = 1 }, "assemble_screwdriverset output[1]")
        end,
    },
    {
        name = "assemble_lockpick has documented inputs/outputs/duration/primaryOutput",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)
            local recipe = catalog.byId['assemble_lockpick'].recipe

            assertEqual(recipe.duration, 75, "assemble_lockpick duration")
            assertEqual(recipe.primaryOutput, 'lockpick', "assemble_lockpick primaryOutput")
            assertEqualTable(recipe.inputs[1], { item = 'cz_metal_parts', amount = 2 }, "assemble_lockpick input[1]")
            assertEqualTable(recipe.outputs[1], { item = 'lockpick', amount = 2 }, "assemble_lockpick output[1]")
        end,
    },
    {
        name = "assemble_repairkit has documented inputs/outputs/duration/primaryOutput",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)
            local recipe = catalog.byId['assemble_repairkit'].recipe

            assertEqual(recipe.machine, 'assembly', "assemble_repairkit machine")
            assertEqual(recipe.duration, 180, "assemble_repairkit duration")
            assertEqual(recipe.access, 'CIVIL', "assemble_repairkit access")
            assertEqual(recipe.primaryOutput, 'repairkit', "assemble_repairkit primaryOutput")
            assertEqual(#recipe.inputs, 3, "assemble_repairkit input count")
            assertEqualTable(recipe.inputs[1], { item = 'cz_components', amount = 3 }, "assemble_repairkit input[1]")
            assertEqualTable(recipe.inputs[2], { item = 'cz_mechanical_parts', amount = 2 }, "assemble_repairkit input[2]")
            assertEqualTable(recipe.inputs[3], { item = 'cz_casing', amount = 1 }, "assemble_repairkit input[3]")
            assertEqualTable(recipe.outputs[1], { item = 'repairkit', amount = 1 }, "assemble_repairkit output[1]")
        end,
    },
    {
        name = "assemble_pistol_ammo has documented inputs/outputs/duration/primaryOutput and ORG_WEAPONS access",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)
            local recipe = catalog.byId['assemble_pistol_ammo'].recipe

            assertEqual(recipe.duration, 150, "assemble_pistol_ammo duration")
            assertEqual(recipe.access, 'ORG_WEAPONS', "assemble_pistol_ammo access")
            assertEqual(recipe.primaryOutput, 'pistol_ammo', "assemble_pistol_ammo primaryOutput")
            assertEqualTable(recipe.inputs[1], { item = 'cz_copper_wire', amount = 3 }, "assemble_pistol_ammo input[1]")
            assertEqualTable(recipe.inputs[2], { item = 'cz_metal_parts', amount = 2 }, "assemble_pistol_ammo input[2]")
            assertEqualTable(recipe.outputs[1], { item = 'pistol_ammo', amount = 1 }, "assemble_pistol_ammo output[1]")
        end,
    },
    {
        name = "assemble_receiver has documented inputs/outputs/duration/primaryOutput and ORG_WEAPONS access",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)
            local recipe = catalog.byId['assemble_receiver'].recipe

            assertEqual(recipe.duration, 240, "assemble_receiver duration")
            assertEqual(recipe.access, 'ORG_WEAPONS', "assemble_receiver access")
            assertEqual(recipe.primaryOutput, 'cz_receiver', "assemble_receiver primaryOutput")
            assertEqual(#recipe.inputs, 3, "assemble_receiver input count")
            assertEqualTable(recipe.inputs[1], { item = 'steel', amount = 5 }, "assemble_receiver input[1]")
            assertEqualTable(recipe.inputs[2], { item = 'cz_metal_parts', amount = 4 }, "assemble_receiver input[2]")
            assertEqualTable(recipe.inputs[3], { item = 'cz_casing', amount = 1 }, "assemble_receiver input[3]")
            assertEqualTable(recipe.outputs[1], { item = 'cz_receiver', amount = 1 }, "assemble_receiver output[1]")
        end,
    },
    {
        name = "assemble_pistol has documented inputs/outputs/duration/primaryOutput and ORG_WEAPONS access",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)
            local recipe = catalog.byId['assemble_pistol'].recipe

            assertEqual(recipe.duration, 600, "assemble_pistol duration")
            assertEqual(recipe.access, 'ORG_WEAPONS', "assemble_pistol access")
            assertEqual(recipe.primaryOutput, 'weapon_pistol', "assemble_pistol primaryOutput")
            assertEqual(#recipe.inputs, 3, "assemble_pistol input count")
            assertEqualTable(recipe.inputs[1], { item = 'cz_receiver', amount = 1 }, "assemble_pistol input[1]")
            assertEqualTable(recipe.inputs[2], { item = 'cz_components', amount = 3 }, "assemble_pistol input[2]")
            assertEqualTable(recipe.inputs[3], { item = 'cz_mechanical_parts', amount = 1 }, "assemble_pistol input[3]")
            assertEqualTable(recipe.outputs[1], { item = 'weapon_pistol', amount = 1 }, "assemble_pistol output[1]")
        end,
    },
    {
        name = "all recipes have enabled=true and primaryOutput present in outputs",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)

            for _, id in ipairs(catalog.order) do
                local recipe = catalog.byId[id].recipe
                assertTrue(recipe.enabled, "recipe " .. id .. " should be enabled")
                assertTrue(recipe.primaryOutput, "recipe " .. id .. " should have primaryOutput")

                local found = false
                for _, output in ipairs(recipe.outputs) do
                    if output.item == recipe.primaryOutput then
                        found = true
                        break
                    end
                end
                assertTrue(found, "recipe " .. id .. " primaryOutput should be in outputs")
            end
        end,
    },
    {
        name = "duplicate recipe IDs are rejected without overwriting the first entry",
        test = function()
            local duplicateRecipes = {
                { id = 'test_dup', machine = 'refinery', inputs = { { item = 'iron', amount = 1 } }, outputs = { { item = 'steel', amount = 1 } }, primaryOutput = 'steel' },
                { id = 'test_dup', machine = 'refinery', inputs = { { item = 'copper', amount = 1 } }, outputs = { { item = 'cz_copper_wire', amount = 1 } }, primaryOutput = 'cz_copper_wire' },
            }

            local catalog, errors = buildRecipeCatalog(duplicateRecipes)
            assertEqual(catalog, nil, "catalog should be nil on duplicate IDs")
            assertTrue(errors, "errors should be returned")
            assertEqual(#errors, 1, "should have exactly one error")
            assertEqual(errors[1].path, 'recipes[2].id', "error path should point to the duplicate")
        end,
    },
    {
        name = "malformed recipe ID is rejected with a structured error",
        test = function()
            local malformedRecipes = {
                { id = '', machine = 'refinery', inputs = { { item = 'iron', amount = 1 } }, outputs = { { item = 'steel', amount = 1 } }, primaryOutput = 'steel' },
            }

            local catalog, errors = buildRecipeCatalog(malformedRecipes)
            assertEqual(catalog, nil, "catalog should be nil on malformed ID")
            assertTrue(errors, "errors should be returned")
            assertEqual(#errors, 1, "should have exactly one error")
            assertEqual(errors[1].path, 'recipes[1].id', "error path should point to the malformed ID")
        end,
    },
    {
        name = "byId index preserves the original recipe object without overwriting",
        test = function()
            local catalog = buildRecipeCatalog(Recipes)
            -- The byId entry should reference the same recipe object from the list.
            assertEqual(catalog.byId['reclaim_iron'].recipe, Recipes[1], "byId should reference original recipe object")
            assertEqual(catalog.byId['reclaim_iron'].index, 1, "byId should preserve original index")
        end,
    },
}
