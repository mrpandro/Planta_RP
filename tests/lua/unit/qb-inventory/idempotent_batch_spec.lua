-- qb-inventory idempotent batch validator tests
-- Pure unit tests for validateBatch + canonicalPayload. The module is loaded
-- via dofile under stock Lua 5.4; no FiveM or MySQL globals are required.

local QBInventoryBatch = dofile("resources/[qb]/qb-inventory/server/idempotent_batch.lua")
local validateBatch = QBInventoryBatch.validateBatch
local canonicalPayload = QBInventoryBatch.canonicalPayload

local constraints = { maxWeight = 120000, maxSlots = 40 }

local itemRegistry = {
    iron = { name = 'iron', weight = 100, unique = false, type = 'item', label = 'Iron', description = '', useable = false, image = 'iron.png', shouldClose = false, combinable = nil },
    steel = { name = 'steel', weight = 200, unique = false, type = 'item', label = 'Steel', description = '', useable = false, image = 'steel.png', shouldClose = false, combinable = nil },
    weapon_pistol = { name = 'weapon_pistol', weight = 1000, unique = true, type = 'weapon', label = 'Pistol', description = '', useable = false, image = 'weapon_pistol.png', shouldClose = true, combinable = nil },
}

local function makeItem(name, amount, slot, info)
    local reg = itemRegistry[name]
    return {
        name = reg.name,
        amount = amount,
        info = info or {},
        label = reg.label,
        description = reg.description,
        weight = reg.weight,
        type = reg.type,
        unique = reg.unique,
        useable = reg.useable,
        image = reg.image,
        shouldClose = reg.shouldClose,
        slot = slot,
        combinable = reg.combinable,
    }
end

-- Fresh inventory with 10 iron at slot 1.
local function freshInventory()
    return {
        [1] = makeItem('iron', 10, 1, {}),
    }
end

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "Assertion failed") .. " | expected=" .. tostring(expected) .. ", actual=" .. tostring(actual))
    end
end

local function assertTrue(value, message)
    if not value then error(message or "Expected truthy value") end
end

local function assertFalse(value, message)
    if value then error(message or "Expected falsy value") end
end

local function assertContains(haystack, needle, message)
    if type(haystack) ~= 'string' or string.find(haystack, needle, 1, true) == nil then
        error((message or "Expected string to contain needle") .. " | needle=" .. tostring(needle) .. ", haystack=" .. tostring(haystack))
    end
end

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

local function findError(errors, pathFragment)
    for _, err in ipairs(errors) do
        if string.find(err.path, pathFragment, 1, true) and string.find(err.message, pathFragment, 1, true) == nil then
            -- match on path containing the fragment
        end
        if string.find(err.path, pathFragment, 1, true) then
            return err
        end
    end
    return nil
end

local function findErrorByMessage(errors, messageFragment)
    for _, err in ipairs(errors) do
        if string.find(err.message, messageFragment, 1, true) then
            return err
        end
    end
    return nil
end

return {
    {
        name = "happy path: remove 5 iron, add 2 steel",
        test = function()
            local r = validateBatch(freshInventory(), { { item = 'iron', amount = 5 } }, { { item = 'steel', amount = 2 } }, constraints, itemRegistry)
            assertTrue(r.ok, "should succeed")
            assertEqual(r.items[1].amount, 5, "iron reduced to 5")
            local steelSlot
            for slot, item in pairs(r.items) do
                if item.name == 'steel' then steelSlot = slot; break end
            end
            assertTrue(steelSlot, "steel placed in a slot")
            assertEqual(r.items[steelSlot].amount, 2, "steel amount 2")
        end,
    },
    {
        name = "remove item not present -> error",
        test = function()
            local r = validateBatch(freshInventory(), { { item = 'steel', amount = 1 } }, {}, constraints, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(findErrorByMessage(r.errors, "not present"), "error mentions not present")
        end,
    },
    {
        name = "remove more than available -> error",
        test = function()
            local r = validateBatch(freshInventory(), { { item = 'iron', amount = 999 } }, {}, constraints, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(findErrorByMessage(r.errors, "not enough"), "error mentions not enough")
        end,
    },
    {
        name = "add unknown item -> error",
        test = function()
            local r = validateBatch(freshInventory(), {}, { { item = 'unobtainium', amount = 1 } }, constraints, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(findErrorByMessage(r.errors, "not in the registry"), "error mentions registry")
        end,
    },
    {
        name = "add exceeds maxWeight -> error",
        test = function()
            local heavy = { name = 'lead', weight = 100000, unique = false, type = 'item', label = 'Lead', description = '', useable = false, image = 'lead.png', shouldClose = false, combinable = nil }
            itemRegistry.lead = heavy
            local inv = freshInventory()
            local r = validateBatch(inv, {}, { { item = 'lead', amount = 2 } }, constraints, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(findErrorByMessage(r.errors, "max weight"), "error mentions max weight")
            itemRegistry.lead = nil
        end,
    },
    {
        name = "add exceeds maxSlots -> error",
        test = function()
            local small = { maxWeight = 120000, maxSlots = 1 }
            local inv = freshInventory() -- slot 1 occupied by iron
            local r = validateBatch(inv, {}, { { item = 'steel', amount = 1 } }, small, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(findErrorByMessage(r.errors, "no free slot") or findErrorByMessage(r.errors, "max slots"), "error mentions slots")
        end,
    },
    {
        name = "slot out of range (0 and >maxSlots) -> error",
        test = function()
            local r1 = validateBatch(freshInventory(), {}, { { item = 'steel', amount = 1, slot = 0 } }, constraints, itemRegistry)
            assertFalse(r1.ok, "slot 0 should fail")
            assertTrue(findErrorByMessage(r1.errors, "slot out of range"), "error mentions slot out of range")

            local r2 = validateBatch(freshInventory(), {}, { { item = 'steel', amount = 1, slot = 41 } }, constraints, itemRegistry)
            assertFalse(r2.ok, "slot 41 should fail")
            assertTrue(findErrorByMessage(r2.errors, "slot out of range"), "error mentions slot out of range")
        end,
    },
    {
        name = "non-unique add stacks into existing slot; unique add takes a free slot; unique add with no free slot -> error",
        test = function()
            -- non-unique stack: add iron (already at slot 1) -> stacks
            local r1 = validateBatch(freshInventory(), {}, { { item = 'iron', amount = 5 } }, constraints, itemRegistry)
            assertTrue(r1.ok, "iron should stack")
            assertEqual(r1.items[1].amount, 15, "iron stacked to 15")

            -- unique add: takes a free slot (slot 2)
            local r2 = validateBatch(freshInventory(), {}, { { item = 'weapon_pistol', amount = 1 } }, constraints, itemRegistry)
            assertTrue(r2.ok, "pistol should be placed")
            assertTrue(r2.items[2] and r2.items[2].name == 'weapon_pistol', "pistol at slot 2")

            -- unique add with no free slot -> error
            local tiny = { maxWeight = 120000, maxSlots = 1 }
            local r3 = validateBatch(freshInventory(), {}, { { item = 'weapon_pistol', amount = 1 } }, tiny, itemRegistry)
            assertFalse(r3.ok, "pistol with no free slot should fail")
            assertTrue(findErrorByMessage(r3.errors, "no free slot") or findErrorByMessage(r3.errors, "max slots"), "error mentions slots")
        end,
    },
    {
        name = "negative/zero/NaN/inf amount -> error",
        test = function()
            local rNeg = validateBatch(freshInventory(), { { item = 'iron', amount = -5 } }, {}, constraints, itemRegistry)
            assertFalse(rNeg.ok, "negative removal should fail")

            local rZero = validateBatch(freshInventory(), { { item = 'iron', amount = 0 } }, {}, constraints, itemRegistry)
            assertFalse(rZero.ok, "zero removal should fail")

            local rNaN = validateBatch(freshInventory(), { { item = 'iron', amount = (0/0) } }, {}, constraints, itemRegistry)
            assertFalse(rNaN.ok, "NaN removal should fail")

            local rInf = validateBatch(freshInventory(), { { item = 'iron', amount = math.huge } }, {}, constraints, itemRegistry)
            assertFalse(rInf.ok, "inf removal should fail")
        end,
    },
    {
        name = "empty batch -> ok no-op, items unchanged",
        test = function()
            local inv = freshInventory()
            local r = validateBatch(inv, {}, {}, constraints, itemRegistry)
            assertTrue(r.ok, "empty batch should succeed")
            assertEqual(r.items[1].amount, 10, "iron unchanged")
        end,
    },
    {
        name = "removal + addition of same item net out correctly",
        test = function()
            -- remove 10 iron, add 3 iron -> net 3 iron (fresh slot since slot 1 cleared then re-added)
            local r = validateBatch(freshInventory(), { { item = 'iron', amount = 10 } }, { { item = 'iron', amount = 3 } }, constraints, itemRegistry)
            assertTrue(r.ok, "net-out should succeed")
            local totalIron = 0
            for _, item in pairs(r.items) do
                if item.name == 'iron' then totalIron = totalIron + item.amount end
            end
            assertEqual(totalIron, 3, "net iron is 3")
        end,
    },
    {
        name = "metadata-specified removal mismatches stored metadata -> error",
        test = function()
            local inv = { [1] = makeItem('iron', 10, 1, { quality = 50 }) }
            local r = validateBatch(inv, { { item = 'iron', amount = 1, metadata = { quality = 99 } } }, {}, constraints, itemRegistry)
            assertFalse(r.ok, "metadata mismatch should fail")
            assertTrue(findErrorByMessage(r.errors, "metadata does not match"), "error mentions metadata mismatch")
        end,
    },
    {
        name = "metadata-specified removal matches stored metadata -> ok",
        test = function()
            local inv = { [1] = makeItem('iron', 10, 1, { quality = 50 }) }
            local r = validateBatch(inv, { { item = 'iron', amount = 4, metadata = { quality = 50 } } }, {}, constraints, itemRegistry)
            assertTrue(r.ok, "matching metadata should succeed")
            assertEqual(r.items[1].amount, 6, "iron reduced to 6")
        end,
    },
    {
        name = "canonicalPayload: same inputs -> identical; reordered additions -> different; identifier change -> different",
        test = function()
            local removals = { { item = 'iron', amount = 5 } }
            local additions = { { item = 'steel', amount = 2 }, { item = 'iron', amount = 1 } }
            local a = canonicalPayload('ABC123', removals, additions)
            local b = canonicalPayload('ABC123', removals, additions)
            assertEqual(a, b, "same inputs produce identical payload")

            local reordered = { { item = 'iron', amount = 1 }, { item = 'steel', amount = 2 } }
            local c = canonicalPayload('ABC123', removals, reordered)
            assertTrue(a ~= c, "reordered additions produce a different payload")

            local d = canonicalPayload('DEF456', removals, additions)
            assertTrue(a ~= d, "different identifier produces a different payload")
        end,
    },
    {
        name = "canonicalPayload: nil removals/additions handled deterministically",
        test = function()
            local a = canonicalPayload('X', nil, nil)
            local b = canonicalPayload('X', nil, nil)
            assertEqual(a, b, "nil batches are deterministic")
        end,
    },
    {
        name = "validator never mutates the input clone on failure",
        test = function()
            local inv = freshInventory()
            local snapshot = {
                [1] = makeItem('iron', 10, 1, {}),
            }
            -- run a failing batch (remove more than available)
            local r = validateBatch(inv, { { item = 'iron', amount = 999 } }, {}, constraints, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(deepEqual(inv[1], snapshot[1]), "input clone unchanged after failure")
            assertEqual(inv[1].amount, 10, "input iron amount unchanged")
        end,
    },
    {
        name = "validator never mutates the input clone on success either",
        test = function()
            local inv = freshInventory()
            local originalAmount = inv[1].amount
            local r = validateBatch(inv, { { item = 'iron', amount = 3 } }, { { item = 'steel', amount = 1 } }, constraints, itemRegistry)
            assertTrue(r.ok, "should succeed")
            assertEqual(inv[1].amount, originalAmount, "input clone unchanged on success; result is a separate table")
        end,
    },
    {
        name = "addition into an occupied slot by a different item -> error",
        test = function()
            local r = validateBatch(freshInventory(), {}, { { item = 'steel', amount = 1, slot = 1 } }, constraints, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(findErrorByMessage(r.errors, "different item"), "error mentions different item")
        end,
    },
    {
        name = "unique item cannot stack into an occupied slot -> error",
        test = function()
            local inv = { [1] = makeItem('weapon_pistol', 1, 1, { serie = 'A1' }) }
            local r = validateBatch(inv, {}, { { item = 'weapon_pistol', amount = 1, slot = 1 } }, constraints, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(findErrorByMessage(r.errors, "unique item cannot stack"), "error mentions unique cannot stack")
        end,
    },
    {
        name = "invalid constraints / registry -> error",
        test = function()
            local r1 = validateBatch(freshInventory(), {}, {}, { maxWeight = 120000 }, itemRegistry)
            assertFalse(r1.ok, "missing maxSlots should fail")

            local r2 = validateBatch(freshInventory(), {}, {}, constraints, "not a table")
            assertFalse(r2.ok, "non-table registry should fail")
        end,
    },
    {
        name = "non-table itemsClone -> error",
        test = function()
            local r = validateBatch("not-a-table", {}, {}, constraints, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(findErrorByMessage(r.errors, "itemsClone must be a table"), "error mentions itemsClone")
        end,
    },
    {
        name = "non-table removal entry -> error",
        test = function()
            local r = validateBatch(freshInventory(), { "not-a-table" }, {}, constraints, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(findErrorByMessage(r.errors, "removal must be a table"), "error mentions removal must be a table")
        end,
    },
    {
        name = "non-table addition entry -> error",
        test = function()
            local r = validateBatch(freshInventory(), {}, { "not-a-table" }, constraints, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(findErrorByMessage(r.errors, "addition must be a table"), "error mentions addition must be a table")
        end,
    },
    {
        name = "removal: non-string item name -> error",
        test = function()
            local r = validateBatch(freshInventory(), { { item = 123, amount = 1 } }, {}, constraints, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(findErrorByMessage(r.errors, "item must be a non-empty string"), "error mentions non-empty string")
        end,
    },
    {
        name = "removal: empty item name -> error",
        test = function()
            local r = validateBatch(freshInventory(), { { item = '', amount = 1 } }, {}, constraints, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(findErrorByMessage(r.errors, "item must be a non-empty string"), "error mentions non-empty string")
        end,
    },
    {
        name = "removal: item not in registry -> error",
        test = function()
            local r = validateBatch(freshInventory(), { { item = 'unobtainium', amount = 1 } }, {}, constraints, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(findErrorByMessage(r.errors, "not in the registry"), "error mentions registry")
        end,
    },
    {
        name = "removal: slot out of range -> error",
        test = function()
            local r = validateBatch(freshInventory(), { { item = 'iron', amount = 1, slot = 41 } }, {}, constraints, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(findErrorByMessage(r.errors, "slot out of range"), "error mentions slot out of range")
        end,
    },
    {
        name = "removal: valid explicit slot succeeds",
        test = function()
            local inv = { [1] = makeItem('iron', 10, 1, {}), [2] = makeItem('steel', 5, 2, {}) }
            local r = validateBatch(inv, { { item = 'steel', amount = 2, slot = 2 } }, {}, constraints, itemRegistry)
            assertTrue(r.ok, "should succeed")
            assertEqual(r.items[2].amount, 3, "steel reduced to 3 at slot 2")
        end,
    },
    {
        name = "addition: non-string item name -> error",
        test = function()
            local r = validateBatch(freshInventory(), {}, { { item = 123, amount = 1 } }, constraints, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(findErrorByMessage(r.errors, "item must be a non-empty string"), "error mentions non-empty string")
        end,
    },
    {
        name = "addition: bad amount (non-positive-integer) -> error",
        test = function()
            local r = validateBatch(freshInventory(), {}, { { item = 'steel', amount = -1 } }, constraints, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(findErrorByMessage(r.errors, "amount must be a positive integer"), "error mentions positive integer")
        end,
    },
    {
        name = "addition: explicit slot stacking into same non-unique item succeeds",
        test = function()
            local r = validateBatch(freshInventory(), {}, { { item = 'iron', amount = 5, slot = 1 } }, constraints, itemRegistry)
            assertTrue(r.ok, "should succeed")
            assertEqual(r.items[1].amount, 15, "iron stacked to 15 at explicit slot 1")
        end,
    },
    {
        name = "addition: explicit free slot succeeds",
        test = function()
            local r = validateBatch(freshInventory(), {}, { { item = 'steel', amount = 2, slot = 3 } }, constraints, itemRegistry)
            assertTrue(r.ok, "should succeed")
            assertTrue(r.items[3] and r.items[3].name == 'steel', "steel placed at explicit slot 3")
            assertEqual(r.items[3].amount, 2, "steel amount 2")
        end,
    },
    {
        name = "addition: exceeds max slots via usedSlotCount -> error",
        test = function()
            -- Fill all slots in a 1-slot inventory, then try to add a different item
            local tiny = { maxWeight = 120000, maxSlots = 1 }
            local inv = { [1] = makeItem('iron', 10, 1, {}) }
            local r = validateBatch(inv, {}, { { item = 'steel', amount = 1 } }, tiny, itemRegistry)
            assertFalse(r.ok, "should fail")
            assertTrue(findErrorByMessage(r.errors, "no free slot") or findErrorByMessage(r.errors, "max slots"), "error mentions slots")
        end,
    },
    {
        name = "canonicalPayload: metadata in removals exercises canonicalizeValue",
        test = function()
            -- Removals with metadata: nil, boolean, number, string, array, map
            local removals = {
                { item = 'iron', amount = 1, metadata = { quality = 50 } },           -- map
                { item = 'iron', amount = 1, metadata = { 1, 2, 3 } },                -- array
                { item = 'iron', amount = 1, metadata = { flag = true } },             -- boolean
                { item = 'iron', amount = 1, metadata = { count = 42 } },             -- number
                { item = 'iron', amount = 1, metadata = { name = "test" } },           -- string
            }
            local a = canonicalPayload('ABC', removals, {})
            local b = canonicalPayload('ABC', removals, {})
            assertEqual(a, b, "same metadata payloads produce identical canonical strings")

            -- Different metadata produces a different canonical string
            local removals2 = {
                { item = 'iron', amount = 1, metadata = { quality = 99 } },
            }
            local c = canonicalPayload('ABC', removals2, {})
            assertTrue(a ~= c, "different metadata produces different canonical string")
        end,
    },
    {
        name = "canonicalPayload: info in additions exercises canonicalizeValue",
        test = function()
            local additions = {
                { item = 'steel', amount = 1, info = { quality = 50 } },              -- map
                { item = 'steel', amount = 1, info = { 1, 2, 3 } },                   -- array
                { item = 'steel', amount = 1, info = { flag = true } },               -- boolean
                { item = 'steel', amount = 1, info = { count = 42 } },                -- number
                { item = 'steel', amount = 1, info = { name = "test" } },             -- string
            }
            local a = canonicalPayload('ABC', {}, additions)
            local b = canonicalPayload('ABC', {}, additions)
            assertEqual(a, b, "same info payloads produce identical canonical strings")

            -- Different info produces a different canonical string
            local additions2 = {
                { item = 'steel', amount = 1, info = { quality = 99 } },
            }
            local c = canonicalPayload('ABC', {}, additions2)
            assertTrue(a ~= c, "different info produces different canonical string")
        end,
    },
    {
        name = "canonicalPayload: nil metadata/info handled (empty string, not 'null')",
        test = function()
            -- No metadata/info → meta field is '' (empty), not 'null'
            local withoutMeta = canonicalPayload('X', { { item = 'iron', amount = 1 } }, {})
            -- With nil metadata → canonicalizeValue(nil) would return 'null',
            -- but the guard `descriptor.metadata ~= nil` short-circuits to ''
            assertTrue(string.find(withoutMeta, 'null') == nil, "nil metadata should not produce 'null' in canonical string")
        end,
    },
}
