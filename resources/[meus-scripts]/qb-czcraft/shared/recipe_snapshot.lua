-- qb-czcraft recipe snapshot (pure)
-- Builds a deterministic canonical string and a frozen snapshot table for a
-- recipe so an in-flight cycle is pinned to the exact inputs/outputs/duration/
-- cost that were configured when it started. Later recipe edits do not
-- retroactively change an in-flight cycle.
--
-- The canonical string is the hash pre-image; the repository computes the real
-- SHA-256 via SQL `SHA2(?, 256)` when persisting czcraft_active_cycles.
-- recipe_hash. This keeps shared/ side-effect-free (no native crypto) and
-- matches the existing inject-queryFn pattern.
--
-- Pinned fields (the ones that affect cycle outcome):
--   id, machine, duration, access, primaryOutput, inputs (item+amount),
--   outputs (item+amount). The `enabled` flag is NOT pinned because pausing/
--   disabling a recipe should stop the *next* cycle, not the in-flight one.

CZCraft = CZCraft or {}

-- Determines whether a value is a finite number.
local function isFiniteNumber(value)
    return type(value) == 'number' and value == value and math.abs(value) ~= math.huge
end

-- Validates that a recipe has the minimum fields needed for a snapshot.
-- @param recipe table
-- @return boolean ok
-- @return string|nil reason
local function validateRecipeForSnapshot(recipe)
    if type(recipe) ~= 'table' then
        return false, 'recipe must be a table'
    end
    if type(recipe.id) ~= 'string' or recipe.id == '' then
        return false, 'recipe.id must be a nonempty string'
    end
    if type(recipe.machine) ~= 'string' or recipe.machine == '' then
        return false, 'recipe.machine must be a nonempty string'
    end
    if not isFiniteNumber(recipe.duration) or recipe.duration <= 0 then
        return false, 'recipe.duration must be a positive finite number'
    end
    if type(recipe.inputs) ~= 'table' or #recipe.inputs == 0 then
        return false, 'recipe.inputs must be a nonempty list'
    end
    if type(recipe.outputs) ~= 'table' or #recipe.outputs == 0 then
        return false, 'recipe.outputs must be a nonempty list'
    end
    if type(recipe.primaryOutput) ~= 'string' or recipe.primaryOutput == '' then
        return false, 'recipe.primaryOutput must be a nonempty string'
    end
    return true
end

-- Sorts an array of { item, amount } by item name for deterministic ordering.
local function sortedItemLines(lines)
    local copy = {}
    for _, line in ipairs(lines) do
        copy[#copy + 1] = { item = line.item, amount = line.amount }
    end
    table.sort(copy, function(a, b) return a.item < b.item end)
    return copy
end

-- Builds the deterministic canonical string for a recipe.
-- This is the hash pre-image: the repository computes SHA2(canonical, 256).
-- @param recipe table
-- @return string canonical
-- @return string|nil error  (nil on success)
local function canonicalRecipe(recipe)
    local ok, reason = validateRecipeForSnapshot(recipe)
    if not ok then
        return nil, reason
    end

    local parts = {}
    parts[#parts + 1] = 'id=' .. recipe.id
    parts[#parts + 1] = 'machine=' .. recipe.machine
    parts[#parts + 1] = 'duration=' .. tostring(recipe.duration)
    parts[#parts + 1] = 'access=' .. tostring(recipe.access or '')
    parts[#parts + 1] = 'primaryOutput=' .. recipe.primaryOutput

    -- Inputs: sorted by item name for stable ordering.
    local sortedInputs = sortedItemLines(recipe.inputs)
    local inputParts = {}
    for _, line in ipairs(sortedInputs) do
        inputParts[#inputParts + 1] = line.item .. ':' .. tostring(line.amount)
    end
    parts[#parts + 1] = 'inputs=' .. table.concat(inputParts, ',')

    -- Outputs: sorted by item name for stable ordering.
    local sortedOutputs = sortedItemLines(recipe.outputs)
    local outputParts = {}
    for _, line in ipairs(sortedOutputs) do
        outputParts[#outputParts + 1] = line.item .. ':' .. tostring(line.amount)
    end
    parts[#parts + 1] = 'outputs=' .. table.concat(outputParts, ',')

    return table.concat(parts, '|')
end

-- Builds a frozen snapshot of the recipe fields that affect cycle outcome.
-- The snapshot is a deep copy of the pinned fields; the caller persists it as
-- JSON in czcraft_active_cycles.recipe_snapshot.
-- @param recipe table
-- @return table|nil snapshot
-- @return string|nil error
local function recipeSnapshot(recipe)
    local ok, reason = validateRecipeForSnapshot(recipe)
    if not ok then
        return nil, reason
    end

    local snapshot = {
        id = recipe.id,
        machine = recipe.machine,
        duration = recipe.duration,
        access = recipe.access,
        primaryOutput = recipe.primaryOutput,
        inputs = {},
        outputs = {},
    }
    for _, line in ipairs(recipe.inputs) do
        snapshot.inputs[#snapshot.inputs + 1] = { item = line.item, amount = line.amount }
    end
    for _, line in ipairs(recipe.outputs) do
        snapshot.outputs[#snapshot.outputs + 1] = { item = line.item, amount = line.amount }
    end
    return snapshot
end

-- Computes the standard cost of a recipe from the input unit costs.
-- @param recipe table
-- @param inputCosts table { [item_name] = cost_per_unit }
-- @return number standardCost
local function standardCost(recipe, inputCosts)
    if type(recipe) ~= 'table' or type(recipe.inputs) ~= 'table' then
        return 0
    end
    local total = 0
    for _, line in ipairs(recipe.inputs) do
        local unitCost = inputCosts and inputCosts[line.item] or 0
        if type(unitCost) == 'number' then
            total = total + (unitCost * (line.amount or 0))
        end
    end
    return total
end

CZCraft.RecipeSnapshot = {
    validateRecipeForSnapshot = validateRecipeForSnapshot,
    canonicalRecipe = canonicalRecipe,
    recipeSnapshot = recipeSnapshot,
    standardCost = standardCost,
}

return CZCraft.RecipeSnapshot
