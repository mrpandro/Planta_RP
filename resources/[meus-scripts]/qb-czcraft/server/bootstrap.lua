-- qb-czcraft server bootstrap
-- Obtains QBCore, injects QBCore.Shared.Items into the pure validator, runs the
-- schema-version gate against czcraft_schema_version, and sets a shared runtime
-- readiness state. Prints a concise localized not-ready summary followed by
-- every actionable blocker. Does not swallow unexpected validator failures —
-- converts them into an explicit not-ready bootstrap error.
-- Registers no mutation events, callbacks, commands, scheduler loops, or gameplay exports.
-- The resource never applies DDL; the schema gate only reads the applied version.

local QBCore = exports['qb-core']:GetCoreObject()

-- Fail-closed before MySQL readiness and the schema gate complete.
GlobalState['qb-czcraft:isReady'] = false

-- Assemble the complete config table from the loaded CZCraft.Config sections.
local function assembleConfig()
    return {
        General = CZCraft.Config.General,
        Machines = CZCraft.Config.Machines,
        Access = CZCraft.Config.Access,
        Plots = CZCraft.Config.Plots,
        Recipes = CZCraft.Config.Recipes,
    }
end

-- Creates a copy-safe error list so the readiness state cannot be mutated externally.
local function copyErrors(errors)
    local copies = {}
    for _, error_ in ipairs(errors) do
        copies[#copies + 1] = { path = error_.path, message = error_.message }
    end
    return copies
end

local function printReport(result)
    if result.isReady then
        print(Lang:t('startup.ready'))
        return
    end

    print(Lang:t('startup.notReady'))

    for _, error_ in ipairs(result.errors) do
        print(Lang:t('startup.blocker', { path = error_.path, message = error_.message }))
    end
end

-- Wraps MySQL.scalar.await so the schema gate receives a plain queryFn.
local function schemaVersionReader()
    return MySQL.scalar.await('SELECT `version` FROM `czcraft_schema_version` WHERE `id` = 1', {})
end

-- Runs config validation and the schema gate, then publishes readiness.
local function runBootstrap()
    local config = assembleConfig()
    local itemRegistry = QBCore.Shared.Items or {}

    -- Run the pure validator. Unexpected failures become explicit not-ready errors.
    local ok, result = pcall(CZCraft.validateConfig, config, itemRegistry)

    if not ok then
        local bootstrapError = {
            isReady = false,
            errors = {
                { path = 'bootstrap', message = tostring(result) },
            },
        }
        print(Lang:t('startup.bootstrapError', { message = tostring(result) }))
        GlobalState['qb-czcraft:isReady'] = false
        CZCraft.Runtime = {
            isReady = false,
            errors = copyErrors(bootstrapError.errors),
            schemaVersion = { required = CZCraft.REQUIRED_SCHEMA_VERSION, applied = nil, reason = 'validator failure' },
        }
        return
    end

    -- Run the schema-version gate against the live database.
    local schemaResult = CZCraft.CheckSchemaGate(schemaVersionReader, CZCraft.REQUIRED_SCHEMA_VERSION)

    if not schemaResult.isReady then
        result.isReady = false
        if schemaResult.appliedVersion ~= nil and schemaResult.appliedVersion < schemaResult.requiredVersion then
            print(Lang:t('startup.schemaBlocked', {
                applied = tostring(schemaResult.appliedVersion),
                required = tostring(schemaResult.requiredVersion),
            }))
        else
            print(Lang:t('startup.schemaMissing', { reason = schemaResult.reason }))
        end
        table.insert(result.errors, 1, { path = 'schema', message = schemaResult.reason })
    end

    printReport(result)

    GlobalState['qb-czcraft:isReady'] = result.isReady
    CZCraft.Runtime = {
        isReady = result.isReady,
        errors = copyErrors(result.errors),
        schemaVersion = {
            required = schemaResult.requiredVersion,
            applied = schemaResult.appliedVersion,
            reason = schemaResult.reason,
        },
    }
end

-- Wait for oxmysql to be connected before querying the schema-version table.
MySQL.ready(function()
    Citizen.CreateThreadNow(function()
        runBootstrap()
    end)
end)
