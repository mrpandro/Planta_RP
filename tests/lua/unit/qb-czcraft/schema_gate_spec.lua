-- qb-czcraft schema gate tests
-- Pure unit tests for the required/applied schema-version gate. The version
-- reader is injected so no MySQL or FiveM globals are required.

-- Load constants first to set up the CZCraft global with REQUIRED_SCHEMA_VERSION.
dofile("resources/[meus-scripts]/qb-czcraft/shared/constants.lua")
local checkSchemaGate = dofile("resources/[meus-scripts]/qb-czcraft/server/schema_gate.lua")

local REQUIRED = CZCraft.REQUIRED_SCHEMA_VERSION

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

return {
    {
        name = "missing schema table (query throws) fails closed with missing reason",
        test = function()
            local r = checkSchemaGate(function() error("Table 'czcraft_schema_version' doesn't exist") end, REQUIRED)

            assertFalse(r.isReady, "should not be ready")
            assertEqual(r.requiredVersion, REQUIRED, "requiredVersion echoed")
            assertEqual(r.appliedVersion, nil, "appliedVersion nil")
            assertContains(r.reason, "missing or unreadable", "reason mentions missing/unreadable")
        end,
    },
    {
        name = "empty schema version table (nil row) fails closed",
        test = function()
            local r = checkSchemaGate(function() return nil end, REQUIRED)

            assertFalse(r.isReady, "should not be ready")
            assertEqual(r.appliedVersion, nil, "appliedVersion nil")
            assertContains(r.reason, "no singleton row", "reason mentions missing row")
        end,
    },
    {
        name = "non-numeric version fails closed",
        test = function()
            local r = checkSchemaGate(function() return "abc" end, REQUIRED)

            assertFalse(r.isReady, "should not be ready")
            assertEqual(r.appliedVersion, "abc", "appliedVersion echoed for diagnostics")
            assertContains(r.reason, "not a non-negative integer", "reason mentions non-integer")
        end,
    },
    {
        name = "fractional version fails closed",
        test = function()
            local r = checkSchemaGate(function() return 1.5 end, REQUIRED)

            assertFalse(r.isReady, "should not be ready")
            assertContains(r.reason, "not a non-negative integer", "reason mentions non-integer")
        end,
    },
    {
        name = "negative version fails closed",
        test = function()
            local r = checkSchemaGate(function() return -1 end, REQUIRED)

            assertFalse(r.isReady, "should not be ready")
            assertContains(r.reason, "not a non-negative integer", "reason mentions non-integer")
        end,
    },
    {
        name = "behind required version fails closed with behind reason",
        test = function()
            local r = checkSchemaGate(function() return 0 end, REQUIRED)

            assertFalse(r.isReady, "should not be ready")
            assertEqual(r.appliedVersion, 0, "appliedVersion 0")
            assertContains(r.reason, "behind required", "reason mentions behind")
        end,
    },
    {
        name = "exact required version passes",
        test = function()
            local r = checkSchemaGate(function() return REQUIRED end, REQUIRED)

            assertTrue(r.isReady, "should be ready")
            assertEqual(r.appliedVersion, REQUIRED, "appliedVersion equals required")
            assertEqual(r.reason, nil, "no reason when ready")
        end,
    },
    {
        name = "newer applied version is accepted",
        test = function()
            local r = checkSchemaGate(function() return REQUIRED + 1 end, REQUIRED)

            assertTrue(r.isReady, "should be ready")
            assertEqual(r.appliedVersion, REQUIRED + 1, "appliedVersion is newer")
        end,
    },
    {
        name = "invalid required version fails closed",
        test = function()
            local r = checkSchemaGate(function() return 1 end, "one")

            assertFalse(r.isReady, "should not be ready")
            assertContains(r.reason, "required schema version", "reason mentions required version")
        end,
    },
    {
        name = "queryFn receives the singleton select SQL",
        test = function()
            local capturedSql
            local function captureFn(sql) capturedSql = sql; return 1 end

            local r = checkSchemaGate(captureFn, REQUIRED)

            assertTrue(r.isReady, "should be ready")
            assertContains(capturedSql, "czcraft_schema_version", "query targets schema version table")
            assertContains(capturedSql, "`id` = 1", "query targets singleton row")
        end,
    },
}
