-- Regression test for the UNSIGNED column underflow bug.
--
-- Bug history: the `quantity` and `reserved_quantity` columns in
-- `czcraft_machine_stock` are INT(10) UNSIGNED. SQL guards like
-- `AND quantity - ? >= 0` or `AND quantity + ? >= 0` (where ? is a
-- negative delta) cause MySQL to evaluate the arithmetic BEFORE the
-- comparison, which underflows and throws "INTEGER UNSIGNED value is
-- out of range" instead of returning false. The fix is to either:
--   - Use `quantity >= ?` (no arithmetic on the column), or
--   - Use `CAST(quantity AS SIGNED) + ? >= 0` (safe signed arithmetic)
--
-- This test reads the repo source files and verifies that no WHERE
-- clause uses unguarded UNSIGNED arithmetic on these columns. It's a
-- static analysis test — it can't run the SQL, but it catches the
-- dangerous pattern before it reaches MySQL.

local function readFile(path)
    local f = io.open(path, 'r')
    if not f then error("Failed to read: " .. path) end
    local content = f:read('*a')
    f:close()
    return content
end

local function assertNotContains(haystack, needle, message)
    if type(haystack) == 'string' and string.find(haystack, needle, 1, true) then
        error((message or "Unexpected substring") .. " | found: " .. needle)
    end
end

local function assertContains(haystack, needle, message)
    if type(haystack) ~= 'string' or string.find(haystack, needle, 1, true) == nil then
        error((message or "Expected substring") .. " | not found: " .. needle)
    end
end

local stockSrc = readFile("resources/[meus-scripts]/qb-czcraft/server/repositories/stock.lua")
local cyclesSrc = readFile("resources/[meus-scripts]/qb-czcraft/server/repositories/cycles.lua")

local tests = {}

-- Test 1: stock.lua applyDelta must not use unguarded `quantity + ? >= 0`
-- in a WHERE clause. The dangerous pattern is backtick-quantity + ? >= 0
-- without CAST.
tests[#tests + 1] = {
    name = "stock.lua: no unguarded `quantity` + ? >= 0 in WHERE",
    test = function()
        -- The dangerous pattern: `quantity` + ? >= 0 (without CAST)
        assertNotContains(stockSrc, '`quantity` + ? >= 0',
            "stock.lua still uses unguarded `quantity` + ? >= 0 — UNSIGNED underflow risk")
    end,
}

-- Test 2: stock.lua applyDelta must not use unguarded `reserved_quantity` + ? >= 0
tests[#tests + 1] = {
    name = "stock.lua: no unguarded `reserved_quantity` + ? >= 0 in WHERE",
    test = function()
        assertNotContains(stockSrc, '`reserved_quantity` + ? >= 0',
            "stock.lua still uses unguarded `reserved_quantity` + ? >= 0 — UNSIGNED underflow risk")
    end,
}

-- Test 3: stock.lua applyDelta must use CAST for the guards
tests[#tests + 1] = {
    name = "stock.lua: applyDelta uses CAST for quantity guard",
    test = function()
        assertContains(stockSrc, 'CAST(`quantity` AS SIGNED) + ? >= 0',
            "stock.lua applyDelta should use CAST(quantity AS SIGNED) for the guard")
    end,
}

-- Test 4: stock.lua applyDelta must use CAST for reserved_quantity guard
tests[#tests + 1] = {
    name = "stock.lua: applyDelta uses CAST for reserved_quantity guard",
    test = function()
        assertContains(stockSrc, 'CAST(`reserved_quantity` AS SIGNED) + ? >= 0',
            "stock.lua applyDelta should use CAST(reserved_quantity AS SIGNED) for the guard")
    end,
}

-- Test 5: cycles.lua must not use unguarded `quantity - ? >= 0`
tests[#tests + 1] = {
    name = "cycles.lua: no unguarded `quantity` - ? >= 0 in WHERE",
    test = function()
        assertNotContains(cyclesSrc, '`quantity` - ? >= 0',
            "cycles.lua still uses unguarded `quantity` - ? >= 0 — UNSIGNED underflow risk")
    end,
}

-- Test 6: cycles.lua must not use unguarded `quantity` + ? >= 0
tests[#tests + 1] = {
    name = "cycles.lua: no unguarded `quantity` + ? >= 0 in WHERE",
    test = function()
        assertNotContains(cyclesSrc, '`quantity` + ? >= 0',
            "cycles.lua still uses unguarded `quantity` + ? >= 0 — UNSIGNED underflow risk")
    end,
}

-- Test 7: cycles.lua must not use unguarded `reserved_quantity` + ? >= 0
tests[#tests + 1] = {
    name = "cycles.lua: no unguarded `reserved_quantity` + ? >= 0 in WHERE",
    test = function()
        assertNotContains(cyclesSrc, '`reserved_quantity` + ? >= 0',
            "cycles.lua still uses unguarded `reserved_quantity` + ? >= 0 — UNSIGNED underflow risk")
    end,
}

-- Test 8: cycles.lua applyCatchUpChunk uses `quantity` >= ? (no arithmetic)
tests[#tests + 1] = {
    name = "cycles.lua: applyCatchUpChunk uses quantity >= ? guard",
    test = function()
        assertContains(cyclesSrc, '`quantity` >= ?',
            "cycles.lua applyCatchUpChunk should use `quantity` >= ? instead of `quantity` - ? >= 0")
    end,
}

-- Test 9: cycles.lua start uses CAST for quantity guard
tests[#tests + 1] = {
    name = "cycles.lua: start uses CAST for quantity guard",
    test = function()
        assertContains(cyclesSrc, 'CAST(`quantity` AS SIGNED) + ? >= 0',
            "cycles.lua start should use CAST(quantity AS SIGNED) for the guard")
    end,
}

-- Test 10: cycles.lua complete uses CAST for reserved_quantity guard
tests[#tests + 1] = {
    name = "cycles.lua: complete uses CAST for reserved_quantity guard",
    test = function()
        assertContains(cyclesSrc, 'CAST(`reserved_quantity` AS SIGNED) + ? >= 0',
            "cycles.lua complete should use CAST(reserved_quantity AS SIGNED) for the guard")
    end,
}

return tests
