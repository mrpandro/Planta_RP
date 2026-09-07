-- qb-czcraft recipe snapshot tests
-- Pure tests for canonical string determinism, snapshot immutability/field
-- coverage, hash pre-image sensitivity (any pinned field change alters the
-- canonical string), and standard cost computation.

dofile("resources/[meus-scripts]/qb-czcraft/shared/constants.lua")
dofile("resources/[meus-scripts]/qb-czcraft/config/recipes.lua")
local RecipeSnapshot = dofile("resources/[meus-scripts]/qb-czcraft/shared/recipe_snapshot.lua")

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

-- A simple recipe fixture for deterministic testing.
local function makeFixture()
    return {
        id = 'test_recipe',
        machine = 'refinery',
        duration = 60,
        access = 'CIVIL',
        primaryOutput = 'steel',
        inputs = {
            { item = 'iron', amount = 5 },
            { item = 'metalscrap', amount = 2 },
        },
        outputs = {
            { item = 'steel', amount = 2 },
        },
    }
end

return {
    {
        name = "canonical string is deterministic for the same recipe",
        test = function()
            local r1 = makeFixture()
            local r2 = makeFixture()
            local c1 = RecipeSnapshot.canonicalRecipe(r1)
            local c2 = RecipeSnapshot.canonicalRecipe(r2)
            assertTrue(c1, "canonical should build")
            assertEqual(c1, c2, "same recipe -> same canonical")
        end,
    },
    {
        name = "canonical string is independent of input/output order",
        test = function()
            local r1 = makeFixture()
            local r2 = makeFixture()
            -- Reverse input order.
            r2.inputs = {
                { item = 'metalscrap', amount = 2 },
                { item = 'iron', amount = 5 },
            }
            local c1 = RecipeSnapshot.canonicalRecipe(r1)
            local c2 = RecipeSnapshot.canonicalRecipe(r2)
            assertEqual(c1, c2, "reordered inputs -> same canonical (sorted)")
        end,
    },
    {
        name = "canonical string changes when id changes",
        test = function()
            local r1 = makeFixture()
            local r2 = makeFixture()
            r2.id = 'different_id'
            local c1 = RecipeSnapshot.canonicalRecipe(r1)
            local c2 = RecipeSnapshot.canonicalRecipe(r2)
            assertFalse(c1 == c2, "different id -> different canonical")
        end,
    },
    {
        name = "canonical string changes when duration changes",
        test = function()
            local r1 = makeFixture()
            local r2 = makeFixture()
            r2.duration = 90
            local c1 = RecipeSnapshot.canonicalRecipe(r1)
            local c2 = RecipeSnapshot.canonicalRecipe(r2)
            assertFalse(c1 == c2, "different duration -> different canonical")
        end,
    },
    {
        name = "canonical string changes when input amount changes",
        test = function()
            local r1 = makeFixture()
            local r2 = makeFixture()
            r2.inputs[1].amount = 10
            local c1 = RecipeSnapshot.canonicalRecipe(r1)
            local c2 = RecipeSnapshot.canonicalRecipe(r2)
            assertFalse(c1 == c2, "different input amount -> different canonical")
        end,
    },
    {
        name = "canonical string changes when output item changes",
        test = function()
            local r1 = makeFixture()
            local r2 = makeFixture()
            r2.outputs[1].item = 'copper'
            r2.primaryOutput = 'copper'
            local c1 = RecipeSnapshot.canonicalRecipe(r1)
            local c2 = RecipeSnapshot.canonicalRecipe(r2)
            assertFalse(c1 == c2, "different output -> different canonical")
        end,
    },
    {
        name = "canonical string changes when primaryOutput changes",
        test = function()
            local r1 = makeFixture()
            local r2 = makeFixture()
            r2.outputs = { { item = 'steel', amount = 2 }, { item = 'iron', amount = 1 } }
            r2.primaryOutput = 'iron'
            local c1 = RecipeSnapshot.canonicalRecipe(r1)
            local c2 = RecipeSnapshot.canonicalRecipe(r2)
            assertFalse(c1 == c2, "different primaryOutput -> different canonical")
        end,
    },
    {
        name = "canonical string changes when machine changes",
        test = function()
            local r1 = makeFixture()
            local r2 = makeFixture()
            r2.machine = 'fabricator'
            local c1 = RecipeSnapshot.canonicalRecipe(r1)
            local c2 = RecipeSnapshot.canonicalRecipe(r2)
            assertFalse(c1 == c2, "different machine -> different canonical")
        end,
    },
    {
        name = "snapshot captures all pinned fields",
        test = function()
            local recipe = makeFixture()
            local snap = RecipeSnapshot.recipeSnapshot(recipe)
            assertTrue(snap, "snapshot should build")
            assertEqual(snap.id, 'test_recipe', "snapshot id")
            assertEqual(snap.machine, 'refinery', "snapshot machine")
            assertEqual(snap.duration, 60, "snapshot duration")
            assertEqual(snap.access, 'CIVIL', "snapshot access")
            assertEqual(snap.primaryOutput, 'steel', "snapshot primaryOutput")
            assertEqual(#snap.inputs, 2, "snapshot input count")
            assertEqual(snap.inputs[1].item, 'iron', "snapshot input[1] item")
            assertEqual(snap.inputs[1].amount, 5, "snapshot input[1] amount")
            assertEqual(#snap.outputs, 1, "snapshot output count")
            assertEqual(snap.outputs[1].item, 'steel', "snapshot output[1] item")
        end,
    },
    {
        name = "snapshot is a deep copy (mutating original does not affect snapshot)",
        test = function()
            local recipe = makeFixture()
            local snap = RecipeSnapshot.recipeSnapshot(recipe)
            -- Mutate the original.
            recipe.inputs[1].amount = 999
            recipe.outputs[1].item = 'changed'
            recipe.duration = 999
            -- Snapshot should be unaffected.
            assertEqual(snap.inputs[1].amount, 5, "snapshot input amount unchanged")
            assertEqual(snap.outputs[1].item, 'steel', "snapshot output item unchanged")
            assertEqual(snap.duration, 60, "snapshot duration unchanged")
        end,
    },
    {
        name = "canonical fails for invalid recipe (missing id)",
        test = function()
            local r = makeFixture()
            r.id = ''
            local c, err = RecipeSnapshot.canonicalRecipe(r)
            assertFalse(c, "canonical should fail")
            assertTrue(err, "error should be returned")
        end,
    },
    {
        name = "canonical fails for invalid recipe (empty inputs)",
        test = function()
            local r = makeFixture()
            r.inputs = {}
            local c, err = RecipeSnapshot.canonicalRecipe(r)
            assertFalse(c, "canonical should fail")
            assertTrue(err, "error should be returned")
        end,
    },
    {
        name = "canonical fails for non-positive duration",
        test = function()
            local r = makeFixture()
            r.duration = 0
            local c, err = RecipeSnapshot.canonicalRecipe(r)
            assertFalse(c, "canonical should fail")
            assertTrue(err, "error should be returned")
        end,
    },
    {
        name = "all 15 MVP recipes produce a valid canonical + snapshot",
        test = function()
            for _, recipe in ipairs(CZCraft.Config.Recipes) do
                local c, err = RecipeSnapshot.canonicalRecipe(recipe)
                assertTrue(c, "canonical for " .. recipe.id .. " should build: " .. tostring(err))
                local snap, snapErr = RecipeSnapshot.recipeSnapshot(recipe)
                assertTrue(snap, "snapshot for " .. recipe.id .. " should build: " .. tostring(snapErr))
                assertEqual(snap.id, recipe.id, "snapshot id matches")
            end
        end,
    },
    {
        name = "standardCost sums input unit costs",
        test = function()
            local recipe = {
                inputs = {
                    { item = 'iron', amount = 5 },
                    { item = 'metalscrap', amount = 2 },
                },
            }
            local costs = { iron = 10, metalscrap = 5 }
            local cost = RecipeSnapshot.standardCost(recipe, costs)
            assertEqual(cost, 60, "5*10 + 2*5 = 60")
        end,
    },
    {
        name = "standardCost returns 0 for missing input costs",
        test = function()
            local recipe = {
                inputs = {
                    { item = 'iron', amount = 5 },
                    { item = 'unknown_item', amount = 2 },
                },
            }
            local costs = { iron = 10 }
            local cost = RecipeSnapshot.standardCost(recipe, costs)
            assertEqual(cost, 50, "5*10 + 0 = 50")
        end,
    },
    {
        name = "standardCost returns 0 for empty/invalid recipe",
        test = function()
            assertEqual(RecipeSnapshot.standardCost({}, {}), 0, "empty recipe -> 0")
            assertEqual(RecipeSnapshot.standardCost(nil, nil), 0, "nil recipe -> 0")
        end,
    },
}
