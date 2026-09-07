-- qb-czcraft configuration validator
-- Pure module: accepts the complete config plus an injected QBCore item registry and
-- returns a readiness result and ordered error list. Does not call natives, SQL, or
-- global QBCore state. Aggregates every failure in deterministic order.
-- Does not hardcode machine/recipe counts so later releases may extend configuration.

CZCraft = CZCraft or {}

-- Sentinel for NaN detection (NaN is the only value not equal to itself).
local function isNaN(value)
    return type(value) == 'number' and value ~= value
end

local function isFiniteNumber(value)
    return type(value) == 'number' and not isNaN(value) and math.abs(value) ~= math.huge
end

local function isPositiveInteger(value)
    return type(value) == 'number' and value == math.floor(value) and value > 0
end

local function isPositiveNumber(value)
    return type(value) == 'number' and not isNaN(value) and value > 0
end

local function isNonNegativeNumber(value)
    return type(value) == 'number' and not isNaN(value) and value >= 0
end

local function isUnresolved(value)
    return value == CZCraft.UNRESOLVED
end

local function isBoolean(value)
    return type(value) == 'boolean'
end

local function isNonemptyString(value)
    return type(value) == 'string' and value ~= ''
end

-- Collects keys of a hash table in sorted order for deterministic iteration.
local function sortedKeys(table_)
    local keys = {}
    for key in pairs(table_) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

-- Builds a set from an array for membership checks.
local function arrayToSet(array)
    local set = {}
    if type(array) ~= 'table' then
        return set
    end
    for _, value in ipairs(array) do
        set[value] = true
    end
    return set
end

-- Validates the general configuration section.
local function validateGeneral(general, errors)
    if type(general) ~= 'table' then
        errors[#errors + 1] = { path = 'general', message = 'general config must be a table' }
        return
    end

    if not isNonemptyString(general.resourceName) then
        errors[#errors + 1] = { path = 'general.resourceName', message = 'resourceName must be a nonempty string' }
    end

    if not isNonemptyString(general.version) then
        errors[#errors + 1] = { path = 'general.version', message = 'version must be a nonempty string' }
    end

    local features = general.features
    if type(features) ~= 'table' then
        errors[#errors + 1] = { path = 'general.features', message = 'features must be a table' }
    else
        local expectedFlags = { 'placement', 'storageTransfers', 'bills', 'production', 'scheduler', 'nui', 'repairkit', 'admin' }
        for _, flag in ipairs(expectedFlags) do
            if not isBoolean(features[flag]) then
                errors[#errors + 1] = { path = 'general.features.' .. flag, message = 'feature flag must be a boolean' }
            end
        end
    end

    local fixtureCaps = general.fixtureCaps
    if type(fixtureCaps) ~= 'table' then
        errors[#errors + 1] = { path = 'general.fixtureCaps', message = 'fixtureCaps must be a table' }
    else
        local knownLocationTypes = arrayToSet({ CZCraft.LocationType.HOUSE, CZCraft.LocationType.ORG })
        for key in pairs(fixtureCaps) do
            if not knownLocationTypes[key] then
                errors[#errors + 1] = { path = 'general.fixtureCaps.' .. tostring(key), message = 'unknown location type in fixture caps' }
            end
        end
        for _, locType in ipairs({ CZCraft.LocationType.HOUSE, CZCraft.LocationType.ORG }) do
            local cap = fixtureCaps[locType]
            if cap == nil then
                errors[#errors + 1] = { path = 'general.fixtureCaps.' .. locType, message = 'missing fixture cap for location type' }
            elseif not isPositiveInteger(cap) then
                errors[#errors + 1] = { path = 'general.fixtureCaps.' .. locType, message = 'fixture cap must be a positive integer' }
            end
        end
    end

    if isUnresolved(general.maxBillsPerMachine) then
        errors[#errors + 1] = { path = 'general.maxBillsPerMachine', message = 'required override unresolved: max bills per machine' }
    elseif not isPositiveInteger(general.maxBillsPerMachine) then
        errors[#errors + 1] = { path = 'general.maxBillsPerMachine', message = 'maxBillsPerMachine must be a positive integer' }
    end
end

-- Validates the machine definitions.
local function validateMachines(machines, errors)
    if type(machines) ~= 'table' then
        errors[#errors + 1] = { path = 'machines', message = 'machines config must be a table/list' }
        return
    end

    local seenTypes = {}
    local seenItems = {}
    local seenProps = {}

    for index, machine in ipairs(machines) do
        local path = 'machines[' .. index .. ']'

        if type(machine) ~= 'table' then
            errors[#errors + 1] = { path = path, message = 'machine entry must be a table' }
            goto continue
        end

        local machineType = machine.type
        if not isNonemptyString(machineType) then
            errors[#errors + 1] = { path = path .. '.type', message = 'machine type must be a nonempty string' }
        elseif seenTypes[machineType] then
            errors[#errors + 1] = { path = path .. '.type', message = 'duplicate machine type: ' .. machineType }
        else
            seenTypes[machineType] = true
        end

        if not isNonemptyString(machine.displayKey) then
            errors[#errors + 1] = { path = path .. '.displayKey', message = 'displayKey must be a nonempty string' }
        end

        local item = machine.item
        if not isNonemptyString(item) then
            errors[#errors + 1] = { path = path .. '.item', message = 'machine item must be a nonempty string' }
        elseif seenItems[item] then
            errors[#errors + 1] = { path = path .. '.item', message = 'duplicate machine item: ' .. item }
        else
            seenItems[item] = true
        end

        if not isPositiveInteger(machine.price) then
            errors[#errors + 1] = { path = path .. '.price', message = 'price must be a positive integer' }
        end

        if not isPositiveInteger(machine.stockCapacity) then
            errors[#errors + 1] = { path = path .. '.stockCapacity', message = 'stockCapacity must be a positive integer' }
        end

        local prop = machine.prop
        if not isNonemptyString(prop) then
            errors[#errors + 1] = { path = path .. '.prop', message = 'prop must be a nonempty string' }
        elseif not CZCraft.ApprovedProps[prop] then
            errors[#errors + 1] = { path = path .. '.prop', message = 'prop not in approved allow-list: ' .. tostring(prop) }
        end

        if isUnresolved(machine.itemWeight) then
            errors[#errors + 1] = { path = path .. '.itemWeight', message = 'required override unresolved: machine item weight' }
        elseif not isPositiveNumber(machine.itemWeight) then
            errors[#errors + 1] = { path = path .. '.itemWeight', message = 'itemWeight must be a positive number' }
        end

        if isUnresolved(machine.placementClearance) then
            errors[#errors + 1] = { path = path .. '.placementClearance', message = 'required override unresolved: placement clearance' }
        elseif not isPositiveNumber(machine.placementClearance) then
            errors[#errors + 1] = { path = path .. '.placementClearance', message = 'placementClearance must be a positive number' }
        end

        ::continue::
    end
end

-- Validates a single inputs or outputs array of a recipe.
local function validateItemLines(lines, sideName, recipePath, errors)
    if type(lines) ~= 'table' then
        errors[#errors + 1] = { path = recipePath .. '.' .. sideName, message = sideName .. ' must be a table/list' }
        return
    end

    if #lines == 0 then
        errors[#errors + 1] = { path = recipePath .. '.' .. sideName, message = sideName .. ' must not be empty' }
        return
    end

    local seenItems = {}

    for lineIndex, line in ipairs(lines) do
        local linePath = recipePath .. '.' .. sideName .. '[' .. lineIndex .. ']'

        if type(line) ~= 'table' then
            errors[#errors + 1] = { path = linePath, message = 'item line must be a table' }
            goto continue
        end

        local item = line.item
        if not isNonemptyString(item) then
            errors[#errors + 1] = { path = linePath .. '.item', message = 'item must be a nonempty string' }
        elseif seenItems[item] then
            errors[#errors + 1] = { path = linePath .. '.item', message = 'duplicate item in ' .. sideName .. ': ' .. item }
        else
            seenItems[item] = true
        end

        if not isPositiveInteger(line.amount) then
            errors[#errors + 1] = { path = linePath .. '.amount', message = 'amount must be a positive integer' }
        end

        ::continue::
    end
end

-- Validates the recipe catalog structure (not cross-references).
local function validateRecipes(recipes, knownMachineTypes, knownAccessTags, errors)
    if type(recipes) ~= 'table' then
        errors[#errors + 1] = { path = 'recipes', message = 'recipes config must be a table/list' }
        return
    end

    local seenIds = {}

    for index, recipe in ipairs(recipes) do
        local path = 'recipes[' .. index .. ']'

        if type(recipe) ~= 'table' then
            errors[#errors + 1] = { path = path, message = 'recipe entry must be a table' }
            goto continue
        end

        local id = recipe.id
        if not isNonemptyString(id) then
            errors[#errors + 1] = { path = path .. '.id', message = 'recipe id must be a nonempty string' }
        elseif seenIds[id] then
            errors[#errors + 1] = { path = path .. '.id', message = 'duplicate recipe id: ' .. id }
        else
            seenIds[id] = true
        end

        local machine = recipe.machine
        if not isNonemptyString(machine) then
            errors[#errors + 1] = { path = path .. '.machine', message = 'machine must be a nonempty string' }
        elseif not knownMachineTypes[machine] then
            errors[#errors + 1] = { path = path .. '.machine', message = 'unknown machine type: ' .. tostring(machine) }
        end

        if not isBoolean(recipe.enabled) then
            errors[#errors + 1] = { path = path .. '.enabled', message = 'enabled must be a boolean' }
        end

        local access = recipe.access
        if not isNonemptyString(access) then
            errors[#errors + 1] = { path = path .. '.access', message = 'access must be a nonempty string' }
        elseif not knownAccessTags[access] then
            errors[#errors + 1] = { path = path .. '.access', message = 'unknown access tag: ' .. tostring(access) }
        end

        if not isPositiveInteger(recipe.duration) then
            errors[#errors + 1] = { path = path .. '.duration', message = 'duration must be a positive integer' }
        end

        validateItemLines(recipe.inputs, 'inputs', path, errors)
        validateItemLines(recipe.outputs, 'outputs', path, errors)

        local primaryOutput = recipe.primaryOutput
        if not isNonemptyString(primaryOutput) then
            errors[#errors + 1] = { path = path .. '.primaryOutput', message = 'primaryOutput must be a nonempty string' }
        else
            local foundInOutputs = false
            if type(recipe.outputs) == 'table' then
                for _, outputLine in ipairs(recipe.outputs) do
                    if type(outputLine) == 'table' and outputLine.item == primaryOutput then
                        foundInOutputs = true
                        break
                    end
                end
            end
            if not foundInOutputs then
                errors[#errors + 1] = { path = path .. '.primaryOutput', message = 'primaryOutput not found in outputs: ' .. primaryOutput }
            end
        end

        ::continue::
    end
end

-- Validates cross-references against the injected item registry.
local function validateItemReferences(machines, recipes, itemRegistry, errors)
    if type(itemRegistry) ~= 'table' then
        errors[#errors + 1] = { path = 'itemRegistry', message = 'item registry must be a table' }
        return
    end

    local function checkItem(itemName, path)
        local entry = itemRegistry[itemName]
        if entry == nil then
            errors[#errors + 1] = { path = path, message = 'missing QBCore item: ' .. itemName }
            return
        end
        if type(entry) ~= 'table' then
            errors[#errors + 1] = { path = path, message = 'item registry entry is not a table: ' .. itemName }
            return
        end
        local weight = entry.weight
        if not isNonNegativeNumber(weight) then
            errors[#errors + 1] = { path = path, message = 'item has unusable weight for stock calculations: ' .. itemName }
        end
    end

    -- Machine packed items.
    for index, machine in ipairs(machines or {}) do
        if type(machine) == 'table' and isNonemptyString(machine.item) then
            local path = 'machines[' .. index .. '].item'
            local entry = itemRegistry[machine.item]
            if entry == nil then
                errors[#errors + 1] = { path = path, message = 'missing QBCore item: ' .. machine.item }
            elseif type(entry) ~= 'table' then
                errors[#errors + 1] = { path = path, message = 'item registry entry is not a table: ' .. machine.item }
            else
                local weight = entry.weight
                if not isNonNegativeNumber(weight) then
                    errors[#errors + 1] = { path = path, message = 'machine item has unusable weight: ' .. machine.item }
                end
                if entry.unique ~= true then
                    errors[#errors + 1] = { path = path, message = 'machine item must be unique=true: ' .. machine.item }
                end
            end
        end
    end

    -- Recipe input/output items.
    for index, recipe in ipairs(recipes or {}) do
        if type(recipe) == 'table' then
            local recipePath = 'recipes[' .. index .. ']'
            if type(recipe.inputs) == 'table' then
                for lineIndex, line in ipairs(recipe.inputs) do
                    if type(line) == 'table' and isNonemptyString(line.item) then
                        checkItem(line.item, recipePath .. '.inputs[' .. lineIndex .. '].item')
                    end
                end
            end
            if type(recipe.outputs) == 'table' then
                for lineIndex, line in ipairs(recipe.outputs) do
                    if type(line) == 'table' and isNonemptyString(line.item) then
                        checkItem(line.item, recipePath .. '.outputs[' .. lineIndex .. '].item')
                    end
                end
            end
        end
    end
end

-- Validates the access configuration.
local function validateAccess(access, errors)
    if type(access) ~= 'table' then
        errors[#errors + 1] = { path = 'access', message = 'access config must be a table' }
        return
    end

    local knownOwnerTypes = arrayToSet({ CZCraft.OwnerType.PLAYER, CZCraft.OwnerType.JOB, CZCraft.OwnerType.GANG })
    local knownPermissions = arrayToSet({
        CZCraft.Permission.OWNER,
        CZCraft.Permission.MANAGER,
        CZCraft.Permission.PRODUCTION,
        CZCraft.Permission.WITHDRAW,
        CZCraft.Permission.DEPOSIT,
        CZCraft.Permission.VIEW,
    })

    if type(access.ownerTypes) == 'table' then
        for _, ownerType in ipairs(access.ownerTypes) do
            if not knownOwnerTypes[ownerType] then
                errors[#errors + 1] = { path = 'access.ownerTypes', message = 'unknown owner type: ' .. tostring(ownerType) }
            end
        end
    else
        errors[#errors + 1] = { path = 'access.ownerTypes', message = 'ownerTypes must be a table/list' }
    end

    if type(access.permissions) == 'table' then
        for _, permission in ipairs(access.permissions) do
            if not knownPermissions[permission] then
                errors[#errors + 1] = { path = 'access.permissions', message = 'unknown permission: ' .. tostring(permission) }
            end
        end
    else
        errors[#errors + 1] = { path = 'access.permissions', message = 'permissions must be a table/list' }
    end

    -- Validate grade grant maps. Empty deny-all maps are valid.
    for _, gradeMapName in ipairs({ 'jobGrades', 'gangGrades' }) do
        local gradeMap = access[gradeMapName]
        if gradeMap ~= nil then
            if type(gradeMap) ~= 'table' then
                errors[#errors + 1] = { path = 'access.' .. gradeMapName, message = gradeMapName .. ' must be a table' }
            else
                for gradeKey, grants in pairs(gradeMap) do
                    if type(grants) ~= 'table' then
                        errors[#errors + 1] = { path = 'access.' .. gradeMapName .. '.' .. tostring(gradeKey), message = 'grade grant map must be a table' }
                    else
                        for _, permission in ipairs(grants) do
                            if not knownPermissions[permission] then
                                errors[#errors + 1] = { path = 'access.' .. gradeMapName .. '.' .. tostring(gradeKey), message = 'unknown permission in grade grants: ' .. tostring(permission) }
                            end
                        end
                    end
                end
            end
        end
    end

    -- Validate access tags.
    if type(access.tags) ~= 'table' then
        errors[#errors + 1] = { path = 'access.tags', message = 'tags must be a table' }
    else
        for tagName, tagConfig in pairs(access.tags) do
            local tagPath = 'access.tags.' .. tostring(tagName)
            if type(tagConfig) ~= 'table' then
                errors[#errors + 1] = { path = tagPath, message = 'tag config must be a table' }
            else
                if type(tagConfig.jobs) ~= 'table' then
                    errors[#errors + 1] = { path = tagPath .. '.jobs', message = 'jobs must be a table/list' }
                end
                if type(tagConfig.gangs) ~= 'table' then
                    errors[#errors + 1] = { path = tagPath .. '.gangs', message = 'gangs must be a table/list' }
                end
            end
        end
    end
end

-- Validates plot entries only when present. Empty collection is valid.
local function validatePlots(plots, errors)
    if plots == nil then
        return
    end

    if type(plots) ~= 'table' then
        errors[#errors + 1] = { path = 'plots', message = 'plots config must be a table/list' }
        return
    end

    -- Empty collection is valid at scaffold time.
    if #plots == 0 then
        return
    end

    local seenIds = {}

    for index, plot in ipairs(plots) do
        local path = 'plots[' .. index .. ']'

        if type(plot) ~= 'table' then
            errors[#errors + 1] = { path = path, message = 'plot entry must be a table' }
            goto continue
        end

        local id = plot.id
        if not isNonemptyString(id) then
            errors[#errors + 1] = { path = path .. '.id', message = 'plot id must be a nonempty string' }
        elseif seenIds[id] then
            errors[#errors + 1] = { path = path .. '.id', message = 'duplicate plot id: ' .. id }
        else
            seenIds[id] = true
        end

        local ownerType = plot.ownerType
        if ownerType ~= CZCraft.OwnerType.JOB and ownerType ~= CZCraft.OwnerType.GANG then
            errors[#errors + 1] = { path = path .. '.ownerType', message = 'plot ownerType must be JOB or GANG' }
        end

        if not isNonemptyString(plot.ownerId) then
            errors[#errors + 1] = { path = path .. '.ownerId', message = 'plot ownerId must be a nonempty string' }
        end

        local zBounds = plot.zBounds
        if type(zBounds) ~= 'table' then
            errors[#errors + 1] = { path = path .. '.zBounds', message = 'zBounds must be a table' }
        else
            if not isFiniteNumber(zBounds.min) then
                errors[#errors + 1] = { path = path .. '.zBounds.min', message = 'zBounds.min must be a finite number' }
            end
            if not isFiniteNumber(zBounds.max) then
                errors[#errors + 1] = { path = path .. '.zBounds.max', message = 'zBounds.max must be a finite number' }
            end
        end

        local polygon = plot.polygon
        if type(polygon) ~= 'table' or #polygon == 0 then
            errors[#errors + 1] = { path = path .. '.polygon', message = 'polygon must be a nonempty list of points' }
        else
            for pointIndex, point in ipairs(polygon) do
                local pointPath = path .. '.polygon[' .. pointIndex .. ']'
                if type(point) ~= 'table' then
                    errors[#errors + 1] = { path = pointPath, message = 'polygon point must be a table' }
                else
                    if not isFiniteNumber(point.x) then
                        errors[#errors + 1] = { path = pointPath .. '.x', message = 'polygon x must be a finite number' }
                    end
                    if not isFiniteNumber(point.y) then
                        errors[#errors + 1] = { path = pointPath .. '.y', message = 'polygon y must be a finite number' }
                    end
                end
            end
        end

        if not isPositiveInteger(plot.machineCap) then
            errors[#errors + 1] = { path = path .. '.machineCap', message = 'machineCap must be a positive integer' }
        end

        if not isPositiveNumber(plot.placementClearance) then
            errors[#errors + 1] = { path = path .. '.placementClearance', message = 'placementClearance must be a positive number' }
        end

        ::continue::
    end
end

-- Public entry point: validates the complete config against an injected item registry.
-- @param config table: { General, Machines, Access, Plots, Recipes }
-- @param itemRegistry table: QBCore.Shared.Items-like hash table
-- @return table: { isReady = boolean, errors = { {path, message}, ... } }
function CZCraft.validateConfig(config, itemRegistry)
    local errors = {}

    if type(config) ~= 'table' then
        return { isReady = false, errors = { { path = 'config', message = 'config must be a table' } } }
    end

    validateGeneral(config.General, errors)
    validateMachines(config.Machines, errors)

    local knownMachineTypes = {}
    if type(config.Machines) == 'table' then
        for _, machine in ipairs(config.Machines) do
            if type(machine) == 'table' and isNonemptyString(machine.type) then
                knownMachineTypes[machine.type] = true
            end
        end
    end

    local knownAccessTags = arrayToSet({ CZCraft.AccessTag.CIVIL, CZCraft.AccessTag.ORG_WEAPONS })
    validateRecipes(config.Recipes, knownMachineTypes, knownAccessTags, errors)
    validateItemReferences(config.Machines, config.Recipes, itemRegistry, errors)
    validateAccess(config.Access, errors)
    validatePlots(config.Plots, errors)

    return { isReady = #errors == 0, errors = errors }
end

return CZCraft.validateConfig
