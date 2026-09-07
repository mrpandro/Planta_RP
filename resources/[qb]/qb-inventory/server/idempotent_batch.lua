-- qb-inventory idempotent batch validator (pure, testable)
--
-- Side-effect-free module that validates a batch of removals + additions
-- against a player's inventory clone and produces the canonical payload string
-- used as the SHA2 input for replay detection. Loadable via dofile under stock
-- Lua 5.4: no FiveM or MySQL globals are referenced.
--
-- validateBatch deep-copies the supplied itemsClone, applies removals then
-- additions to the copy, and validates every step. The input clone is never
-- mutated, even on failure (the function works on an internal deep copy).
--
-- Shape contract (mirrors qb-inventory item rows + QBCore.Shared.Items):
--   items[slot] = { name, amount, info, label, weight, type, unique, slot, ... }
--   itemRegistry[name] = { name, weight, unique, type, label, ... }  (name lowercased)
--   removals[i]  = { item = string, amount = integer, slot = integer|nil, metadata = table|nil }
--   additions[i] = { item = string, amount = integer, slot = integer|nil, info = table|nil }
--   constraints  = { maxWeight = number, maxSlots = number }

local function isPositiveInteger(value)
    return type(value) == 'number'
        and math.floor(value) == value
        and value > 0
        and value ~= math.huge
        and value ~= -math.huge
        and value == value -- reject NaN
end

local function isFiniteNumber(value)
    return type(value) == 'number'
        and value ~= math.huge
        and value ~= -math.huge
        and value == value
end

-- Deep copy that preserves array-vs-map distinction via numeric keys.
local function deepCopy(value)
    if type(value) ~= 'table' then return value end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = deepCopy(v)
    end
    return copy
end

-- Structural equality for metadata/info comparison.
local function deepEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do
        if not deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function totalWeight(items)
    local weight = 0
    for _, item in pairs(items) do
        local amount = item.amount
        if type(amount) ~= 'number' then amount = 1 end
        weight = weight + (item.weight * amount)
    end
    return weight
end

local function usedSlotCount(items)
    local count = 0
    for _, item in pairs(items) do
        if item then count = count + 1 end
    end
    return count
end

local function firstFreeSlot(items, maxSlots)
    for i = 1, maxSlots do
        if items[i] == nil then return i end
    end
    return nil
end

local function firstSlotByName(items, itemName)
    local target = tostring(itemName):lower()
    for slot, item in pairs(items) do
        if item and item.name:lower() == target then
            return slot
        end
    end
    return nil
end

local function makeError(path, message)
    return { path = path, message = message }
end

-- Apply + validate a single removal against the working copy.
-- Returns true on success, or { path, message } on failure.
local function applyRemoval(items, removal, constraints, itemRegistry, index)
    local path = 'removals[' .. index .. ']'
    local itemName = removal.item
    local amount = removal.amount

    if type(itemName) ~= 'string' or itemName == '' then
        return makeError(path, 'item must be a non-empty string')
    end
    if not isPositiveInteger(amount) then
        return makeError(path, 'amount must be a positive integer')
    end
    if not itemRegistry[itemName:lower()] then
        return makeError(path, 'item "' .. itemName .. '" is not in the registry')
    end

    local slot = removal.slot
    if slot ~= nil then
        if not isPositiveInteger(slot) or slot > constraints.maxSlots then
            return makeError(path, 'slot out of range [1, ' .. constraints.maxSlots .. ']')
        end
    end

    local targetSlot
    if slot then
        targetSlot = slot
    else
        targetSlot = firstSlotByName(items, itemName)
    end

    local target = targetSlot and items[targetSlot]
    if not target or target.name:lower() ~= itemName:lower() then
        return makeError(path, 'item not present in inventory')
    end

    if removal.metadata ~= nil then
        if not deepEqual(target.info, removal.metadata) then
            return makeError(path, 'metadata does not match stored info')
        end
    end

    if target.amount < amount then
        return makeError(path, 'not enough items in slot (have ' .. tostring(target.amount) .. ', need ' .. tostring(amount) .. ')')
    end

    target.amount = target.amount - amount
    if target.amount <= 0 then
        items[targetSlot] = nil
    end
    return true
end

-- Apply + validate a single addition against the working copy.
-- Returns true on success, or { path, message } on failure.
local function applyAddition(items, addition, constraints, itemRegistry, index)
    local path = 'additions[' .. index .. ']'
    local itemName = addition.item
    local amount = addition.amount

    if type(itemName) ~= 'string' or itemName == '' then
        return makeError(path, 'item must be a non-empty string')
    end
    local itemInfo = itemRegistry[itemName:lower()]
    if not itemInfo then
        return makeError(path, 'item "' .. itemName .. '" is not in the registry')
    end
    if not isPositiveInteger(amount) then
        return makeError(path, 'amount must be a positive integer')
    end

    local slot = addition.slot
    if slot ~= nil then
        if not isPositiveInteger(slot) or slot > constraints.maxSlots then
            return makeError(path, 'slot out of range [1, ' .. constraints.maxSlots .. ']')
        end
    end

    local addedWeight = itemInfo.weight * amount
    if totalWeight(items) + addedWeight > constraints.maxWeight then
        return makeError(path, 'addition exceeds max weight')
    end

    local isUnique = itemInfo.unique == true
    local targetSlot
    local stacked = false

    if slot then
        local existing = items[slot]
        if existing then
            if isUnique then
                return makeError(path, 'unique item cannot stack into an occupied slot')
            end
            if existing.name:lower() ~= itemName:lower() then
                return makeError(path, 'slot occupied by a different item')
            end
            targetSlot = slot
            stacked = true
        else
            targetSlot = slot
        end
    elseif not isUnique then
        local existingSlot = firstSlotByName(items, itemName)
        if existingSlot then
            targetSlot = existingSlot
            stacked = true
        else
            targetSlot = firstFreeSlot(items, constraints.maxSlots)
        end
    else
        targetSlot = firstFreeSlot(items, constraints.maxSlots)
    end

    if not targetSlot then
        return makeError(path, 'no free slot available')
    end

    if not stacked then
        if items[targetSlot] ~= nil then
            return makeError(path, 'target slot is not free')
        end
        if usedSlotCount(items) + 1 > constraints.maxSlots then
            return makeError(path, 'addition exceeds max slots')
        end
        items[targetSlot] = {
            name = itemInfo.name,
            amount = amount,
            info = deepCopy(addition.info) or {},
            label = itemInfo.label,
            description = itemInfo.description or '',
            weight = itemInfo.weight,
            type = itemInfo.type,
            unique = itemInfo.unique,
            useable = itemInfo.useable,
            image = itemInfo.image,
            shouldClose = itemInfo.shouldClose,
            slot = targetSlot,
            combinable = itemInfo.combinable,
        }
    else
        items[targetSlot].amount = items[targetSlot].amount + amount
    end

    return true
end

-- @param itemsClone table  player inventory keyed by slot (not mutated)
-- @param removals   table  array of removal descriptors
-- @param additions  table  array of addition descriptors
-- @param constraints table { maxWeight, maxSlots }
-- @param itemRegistry table QBCore.Shared.Items (lowercased name keys)
-- @return table { ok = true, items = newItems } | { ok = false, errors = {...} }
local function validateBatch(itemsClone, removals, additions, constraints, itemRegistry)
    if type(itemsClone) ~= 'table' then
        return { ok = false, errors = { makeError('items', 'itemsClone must be a table') } }
    end
    if type(constraints) ~= 'table'
        or not isFiniteNumber(constraints.maxWeight)
        or not isPositiveInteger(constraints.maxSlots) then
        return { ok = false, errors = { makeError('constraints', 'constraints must be { maxWeight, maxSlots }') } }
    end
    if type(itemRegistry) ~= 'table' then
        return { ok = false, errors = { makeError('itemRegistry', 'itemRegistry must be a table') } }
    end

    removals = removals or {}
    additions = additions or {}

    local items = deepCopy(itemsClone)
    local errors = {}

    for i, removal in ipairs(removals) do
        if type(removal) ~= 'table' then
            errors[#errors + 1] = makeError('removals[' .. i .. ']', 'removal must be a table')
        else
            local result = applyRemoval(items, removal, constraints, itemRegistry, i)
            if result ~= true then
                errors[#errors + 1] = result
            end
        end
    end

    -- Only apply additions if every removal validated; otherwise the working
    -- copy is in a partial state and addition errors would be misleading.
    if #errors > 0 then
        return { ok = false, errors = errors }
    end

    for i, addition in ipairs(additions) do
        if type(addition) ~= 'table' then
            errors[#errors + 1] = makeError('additions[' .. i .. ']', 'addition must be a table')
        else
            local result = applyAddition(items, addition, constraints, itemRegistry, i)
            if result ~= true then
                errors[#errors + 1] = result
            end
        end
    end

    if #errors > 0 then
        return { ok = false, errors = errors }
    end

    return { ok = true, items = items }
end

-- Canonical serializer for a single value (used for metadata/info).
-- Maps are emitted with sorted string keys; arrays preserve insertion order.
local function canonicalizeValue(value)
    if value == nil then
        return 'null'
    elseif type(value) == 'boolean' then
        return value and 'true' or 'false'
    elseif type(value) == 'number' then
        return tostring(value)
    elseif type(value) == 'string' then
        return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
    elseif type(value) == 'table' then
        -- Detect array: contiguous integer keys 1..n with no non-integer keys.
        local n = 0
        for k in pairs(value) do
            n = n + 1
        end
        local isArray = true
        for k in pairs(value) do
            if type(k) ~= 'number' or math.floor(k) ~= k or k < 1 or k > n then
                isArray = false
                break
            end
        end

        if isArray and n > 0 then
            local parts = {}
            for i = 1, n do
                parts[i] = canonicalizeValue(value[i])
            end
            return '[' .. table.concat(parts, ',') .. ']'
        else
            local keys = {}
            for k in pairs(value) do
                keys[#keys + 1] = tostring(k)
            end
            table.sort(keys)
            local parts = {}
            for _, k in ipairs(keys) do
                parts[#parts + 1] = '"' .. k .. '":' .. canonicalizeValue(value[k])
            end
            return '{' .. table.concat(parts, ',') .. '}'
        end
    end
    return 'null'
end

local function canonicalEntry(op, descriptor)
    local item = descriptor.item or ''
    local amount = tostring(descriptor.amount or '')
    local slot = descriptor.slot ~= nil and tostring(descriptor.slot) or ''
    local meta = descriptor.metadata ~= nil and canonicalizeValue(descriptor.metadata) or ''
    if op == 'A' then
        meta = descriptor.info ~= nil and canonicalizeValue(descriptor.info) or ''
    end
    return op .. ':' .. item .. ',' .. amount .. ',' .. slot .. ',' .. meta
end

-- Deterministic string used as the SHA2 input. The identifier and the
-- removals/additions arrays are emitted in fixed field order; array order is
-- preserved (a reordered batch is intentionally a different mutation).
-- @return string
local function canonicalPayload(identifier, removals, additions)
    removals = removals or {}
    additions = additions or {}
    local parts = { 'id:' .. tostring(identifier or '') }
    local rParts = {}
    for i, removal in ipairs(removals) do
        rParts[i] = canonicalEntry('R', removal)
    end
    parts[#parts + 1] = 'R:' .. table.concat(rParts, ';')
    local aParts = {}
    for i, addition in ipairs(additions) do
        aParts[i] = canonicalEntry('A', addition)
    end
    parts[#parts + 1] = 'A:' .. table.concat(aParts, ';')
    return table.concat(parts, '|')
end

QBInventoryBatch = {
    validateBatch = validateBatch,
    canonicalPayload = canonicalPayload,
}

return QBInventoryBatch
