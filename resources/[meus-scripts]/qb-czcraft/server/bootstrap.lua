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
        Balance = CZCraft.Config.Balance,
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

    -- Startup reconciliation: fix any machines left with a stale owner_id
    -- after a crash between a house transfer (player_houses UPDATE) and
    -- transferHouseMachines completing. risks.md flags this as non-atomic
    -- by design; this pass makes the result convergent at the next startup.
    -- Only runs when the schema gate passed and the machines repo is loaded.
    if result.isReady and CZCraft.MachinesRepo and CZCraft.MachinesRepo.reconcileHouseMachineOwners then
        local ok, count, details = pcall(CZCraft.MachinesRepo.reconcileHouseMachineOwners)
        if ok and count and count > 0 then
            print(('[qb-czcraft] House-transfer reconciliation: %d machine(s) reassigned to current house owner'):format(count))
            if CZCraft.AuditRepo and CZCraft.AuditRepo.append then
                CZCraft.AuditRepo.append({
                    actor_type = 'SYSTEM', actor_id = 'startup-reconciliation',
                    action = 'HOUSE_TRANSFER_RECONCILIATION',
                    next_state = { machines_reconciled = count, details = details },
                    reason = 'startup reconciliation for stale machine owners',
                })
            end
        elseif not ok then
            print(('[qb-czcraft] House-transfer reconciliation failed: %s'):format(tostring(count)))
        end
    end
end

-- Wait for oxmysql to be connected before querying the schema-version table.
MySQL.ready(function()
    Citizen.CreateThreadNow(function()
        runBootstrap()
    end)
end)
