-- qb-czcraft schema-version gate (pure, testable)
--
-- Compares the applied czcraft_schema_version.version against the required
-- version and returns a structured result. The version reader is injected so
-- this module runs under stock Lua 5.4 in tests without FiveM or MySQL.
--
-- Fail-closed policy: missing table/query error, empty row, non-numeric,
-- negative, or below-required versions all return isReady = false. A newer
-- applied version is accepted (applied >= required).
--
-- The resource never applies DDL itself; this gate only reads.

local function isInteger(value)
    return type(value) == 'number' and math.floor(value) == value and value >= 0
end

-- @param queryFn function(sql, params) -> number|nil  (must throw on error)
-- @param requiredVersion integer (CZCraft.REQUIRED_SCHEMA_VERSION)
-- @return table: { isReady, requiredVersion, appliedVersion, reason }
local function checkSchemaGate(queryFn, requiredVersion)
    if not isInteger(requiredVersion) then
        return {
            isReady = false,
            requiredVersion = requiredVersion,
            appliedVersion = nil,
            reason = 'required schema version is not a non-negative integer',
        }
    end

    local ok, applied = pcall(queryFn, 'SELECT `version` FROM `czcraft_schema_version` WHERE `id` = 1', {})

    if not ok then
        return {
            isReady = false,
            requiredVersion = requiredVersion,
            appliedVersion = nil,
            reason = 'czcraft_schema_version is missing or unreadable: ' .. tostring(applied),
        }
    end

    if applied == nil then
        return {
            isReady = false,
            requiredVersion = requiredVersion,
            appliedVersion = nil,
            reason = 'czcraft_schema_version has no singleton row',
        }
    end

    if not isInteger(applied) then
        return {
            isReady = false,
            requiredVersion = requiredVersion,
            appliedVersion = applied,
            reason = 'czcraft_schema_version.version is not a non-negative integer',
        }
    end

    if applied < requiredVersion then
        return {
            isReady = false,
            requiredVersion = requiredVersion,
            appliedVersion = applied,
            reason = 'schema version ' .. tostring(applied) .. ' is behind required ' .. tostring(requiredVersion),
        }
    end

    return {
        isReady = true,
        requiredVersion = requiredVersion,
        appliedVersion = applied,
        reason = nil,
    }
end

CZCraft = CZCraft or {}
CZCraft.CheckSchemaGate = checkSchemaGate

return checkSchemaGate
