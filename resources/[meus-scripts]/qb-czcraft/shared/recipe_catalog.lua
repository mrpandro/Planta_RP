-- qb-czcraft recipe catalog builder
-- Pure, side-effect-free module that consumes the ordered recipe list and produces
-- lookups by recipe ID and machine type while preserving stable catalog order.
-- Detects malformed/duplicate IDs without silently overwriting entries and returns
-- structured errors for the validator to aggregate.
-- Does not implement cycle snapshots or recipe hashing (deferred to production integration).

CZCraft = CZCraft or {}

-- Builds a catalog from an ordered list of recipe definitions.
-- @param recipes table: ordered list of recipe tables (from config/recipes.lua)
-- @return table|nil catalog: { byId = {...}, byMachine = { machineType = {recipe,...} }, order = {...} }
-- @return table|nil errors: list of { path = string, message = string } entries
function CZCraft.buildRecipeCatalog(recipes)
    if type(recipes) ~= 'table' then
        return nil, { { path = 'recipes', message = 'recipes must be a table/list' } }
    end

    local catalog = {
        byId = {},
        byMachine = {},
        order = {},
    }
    local errors = {}

    for index, recipe in ipairs(recipes) do
        local path = 'recipes[' .. index .. ']'

        if type(recipe) ~= 'table' then
            errors[#errors + 1] = { path = path, message = 'recipe entry must be a table' }
            goto continue
        end

        local id = recipe.id
        if type(id) ~= 'string' or id == '' then
            errors[#errors + 1] = { path = path .. '.id', message = 'recipe id must be a nonempty string' }
            goto continue
        end

        -- Detect duplicate IDs without overwriting the first entry.
        if catalog.byId[id] ~= nil then
            errors[#errors + 1] = { path = path .. '.id', message = 'duplicate recipe id: ' .. id }
            goto continue
        end

        local machine = recipe.machine
        if type(machine) ~= 'string' or machine == '' then
            errors[#errors + 1] = { path = path .. '.machine', message = 'recipe machine must be a nonempty string' }
            goto continue
        end

        local entry = {
            index = index,
            recipe = recipe,
        }

        catalog.byId[id] = entry
        catalog.order[#catalog.order + 1] = id

        if not catalog.byMachine[machine] then
            catalog.byMachine[machine] = {}
        end
        local machineList = catalog.byMachine[machine]
        machineList[#machineList + 1] = entry

        ::continue::
    end

    if #errors > 0 then
        return nil, errors
    end

    return catalog, nil
end

return CZCraft.buildRecipeCatalog
