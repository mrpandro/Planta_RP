-- qb-czcraft E2E runner — runs inside qb-czcraft so scenarios have access
-- to CZCraft globals (repos, config, runtime, etc.).
-- Scenarios are loaded from the qb-czcraft-e2e resource via LoadResourceFile.
--
-- File-based IPC: polls e2e_command.txt, writes output to e2e_output.txt
-- and status to e2e_status.txt.
--
-- Design note: this file does NOT patch the global `print` function.
-- It uses a local `emit` function for capture. This ensures the harness
-- does not alter qb-czcraft's runtime behavior when not actively running
-- a scenario.

local E2E_RESOURCE = 'qb-czcraft-e2e'
-- IPC files live OUTSIDE the bracketed [meus-scripts] path because FiveM's
-- sandboxed io.open write-mode and os.remove silently fail on bracketed
-- paths. The e2e_ipc/ directory is at the server data root.
local IPC_DIR = 'e2e_ipc'
local COMMAND_FILE = IPC_DIR .. '/e2e_command.txt'
local OUTPUT_FILE = IPC_DIR .. '/e2e_output.txt'
local STATUS_FILE = IPC_DIR .. '/e2e_status.txt'

-- Output capture: writes to the output file AND the server console.
-- Does NOT patch the global print — that would alter qb-czcraft's behavior.
local capturing = false

local function emit(...)
    -- Always print to the server console.
    print(...)
    -- Also append to the output file when capturing.
    if capturing then
        local args = { ... }
        local parts = {}
        for i = 1, #args do parts[i] = tostring(args[i]) end
        local line = table.concat(parts, '\t')
        local f = io.open(OUTPUT_FILE, 'a')
        if f then f:write(line, '\n'); f:close() end
    end
end

-- Loads a scenario file from the qb-czcraft-e2e resource.
-- The loaded function runs in qb-czcraft's Lua state, so it has access
-- to CZCraft globals and server-side natives.
-- We prepend `local _ENV = _G` so the loaded chunk uses qb-czcraft's
-- global table (which has CZCraft and natives), not a fresh empty one.
local function loadScenario(path)
    local content = LoadResourceFile(E2E_RESOURCE, path)
    if not content then
        error('could not load scenario file: ' .. path)
    end
    -- Prepend _ENV assignment so the loaded code shares our globals.
    local wrapped = 'local _ENV = _G\n' .. content
    local fn, err = load(wrapped, '@' .. E2E_RESOURCE .. '/' .. path)
    if not fn then
        error('could not compile scenario file: ' .. path .. ': ' .. tostring(err))
    end
    return fn()
end

-- Load the SLO module from qb-czcraft-e2e into this Lua state.
-- Scenarios reference CZE2E.Slo, so we need it in our global table.
local function loadSloModule()
    local content = LoadResourceFile(E2E_RESOURCE, 'server/slo.lua')
    if not content then
        error('could not load slo.lua from qb-czcraft-e2e')
    end
    local wrapped = 'local _ENV = _G\n' .. content
    local fn, err = load(wrapped, '@' .. E2E_RESOURCE .. '/server/slo.lua')
    if not fn then
        error('could not compile slo.lua: ' .. tostring(err))
    end
    fn()
    -- CZE2E.Slo is now set in our _G.
end

-- Get QBCore via exports (the global QBCore is set by qb-core in its own
-- resource state, not shared with qb-czcraft). We make it available as a
-- global so scenarios can use it directly.
local function loadQBCore()
    local ok, result = pcall(function()
        return exports['qb-core']:GetCoreObject()
    end)
    if ok and result then
        _G.QBCore = result
    else
        -- Fallback: try the global (might work in some setups).
        if not _G.QBCore then
            print('[E2E] WARNING: could not get QBCore via exports — scenarios using QBCore will fail')
        end
    end
end

-- Initialize the shared globals that scenarios need.
CreateThread(function()
    Wait(1000)  -- wait for qb-core to be ready
    loadSloModule()
    loadQBCore()
    print('[E2E] shared modules loaded: Slo=' .. tostring(CZE2E.Slo ~= nil)
        .. ' QBCore=' .. tostring(_G.QBCore ~= nil))
end)

local SCENARIOS = {
    diag = function()
        -- Inline diagnostic: tests vehicle natives via Citizen.InvokeNative.
        return function()
            local players = GetPlayers()
            if #players == 0 then
                emit('[diag] no players online')
                return false
            end
            local src = tonumber(players[1])
            local ped = GetPlayerPed(src)
            local coords = GetEntityCoords(ped)
            local hash = GetHashKey('sultan')
            local veh = CreateVehicleServerSetter(hash, 'automobile')
            SetEntityCoords(veh, coords.x + 3.0, coords.y + 3.0, coords.z, false, false, false, true)

            if not veh or veh == 0 or not DoesEntityExist(veh) then
                emit('[diag] could not create test vehicle')
                return false
            end

            local netId = NetworkGetNetworkIdFromEntity(veh)
            emit(('[diag] test vehicle: entity=%d netId=%d type=%d'):format(veh, netId, GetEntityType(veh)))

            -- Wait for the client to load the vehicle model and sync state.
            emit('[diag] waiting 3s for client sync...')
            Wait(3000)

            -- Read initial health (after sync).
            local initEngine = GetVehicleEngineHealth(veh)
            local initBody = GetVehicleBodyHealth(veh)
            local initPetrol = GetVehiclePetrolTankHealth(veh)
            local initEntityHealth = GetEntityHealth(veh)
            emit(('[diag] health after sync: engine=%.1f body=%.1f petrol=%.1f entityHealth=%.1f'):format(
                initEngine, initBody, initPetrol, initEntityHealth))

            -- Damage the vehicle via Citizen.InvokeNative.
            -- SetVehicleEngineHealth hash: 0x45F5E363
            -- SetVehicleBodyHealth hash: 0x4B9DCD1F (already available as global)
            -- SetVehiclePetrolTankHealth hash: 0x3179DC8B
            -- SetVehicleFixed hash: 0x6806C51AD12B83B8

            local ok1, err1 = pcall(Citizen.InvokeNative, 0x45F5E363, veh, 100.0)
            emit(('[diag] InvokeNative SetVehicleEngineHealth(100): ok=%s err=%s'):format(tostring(ok1), tostring(err1)))

            local ok2, err2 = pcall(Citizen.InvokeNative, 0x3179DC8B, veh, 200.0)
            emit(('[diag] InvokeNative SetVehiclePetrolTankHealth(200): ok=%s err=%s'):format(tostring(ok2), tostring(err2)))

            local ok3, err3 = pcall(SetVehicleBodyHealth, veh, 300.0)
            emit(('[diag] global SetVehicleBodyHealth(300): ok=%s err=%s'):format(tostring(ok3), tostring(err3)))

            -- Read back after damage.
            local dmgEngine = GetVehicleEngineHealth(veh)
            local dmgBody = GetVehicleBodyHealth(veh)
            local dmgPetrol = GetVehiclePetrolTankHealth(veh)
            emit(('[diag] after damage: engine=%.1f body=%.1f petrol=%.1f'):format(dmgEngine, dmgBody, dmgPetrol))

            -- Now try to repair via Citizen.InvokeNative.
            local ok4, err4 = pcall(Citizen.InvokeNative, 0x6806C51AD12B83B8, veh)
            emit(('[diag] InvokeNative SetVehicleFixed: ok=%s err=%s'):format(tostring(ok4), tostring(err4)))

            local ok5, err5 = pcall(Citizen.InvokeNative, 0x45F5E363, veh, 1000.0)
            emit(('[diag] InvokeNative SetVehicleEngineHealth(1000): ok=%s err=%s'):format(tostring(ok5), tostring(err5)))

            local ok6, err6 = pcall(Citizen.InvokeNative, 0x3179DC8B, veh, 1000.0)
            emit(('[diag] InvokeNative SetVehiclePetrolTankHealth(1000): ok=%s err=%s'):format(tostring(ok6), tostring(err6)))

            local ok7, err7 = pcall(SetVehicleBodyHealth, veh, 1000.0)
            emit(('[diag] global SetVehicleBodyHealth(1000): ok=%s err=%s'):format(tostring(ok7), tostring(err7)))

            -- Read back after repair.
            local repEngine = GetVehicleEngineHealth(veh)
            local repBody = GetVehicleBodyHealth(veh)
            local repPetrol = GetVehiclePetrolTankHealth(veh)
            emit(('[diag] after repair: engine=%.1f body=%.1f petrol=%.1f'):format(repEngine, repBody, repPetrol))

            -- Verdict.
            local allPass = true
            local function check(label, value, expected)
                local ok = math.abs(value - expected) <= 1.0
                emit(('[diag] %s: %.1f vs %.1f -> %s'):format(label, value, expected, ok and 'PASS' or 'FAIL'))
                if not ok then allPass = false end
            end
            check('engine', repEngine, 1000.0)
            check('body', repBody, 1000.0)
            check('petrol', repPetrol, 1000.0)

            -- Cleanup.
            DeleteEntity(veh)
            emit('[diag] test vehicle deleted')
            emit(('[diag] OVERALL: %s'):format(allPass and 'PASS' or 'FAIL'))
            return allPass
        end
    end,
    repair_natives = function() return loadScenario('server/scenarios/repair_natives.lua') end,
    production_chain = function() return loadScenario('server/scenarios/production_chain.lua') end,
    concurrent = function() return loadScenario('server/scenarios/concurrent.lua') end,
    failure_injection = function() return loadScenario('server/scenarios/failure_injection.lua') end,
    downtime_catchup = function() return loadScenario('server/scenarios/downtime_catchup.lua') end,
    load_test = function() return loadScenario('server/scenarios/load_test.lua') end,
}

-- Executes a set of scenarios and returns per-scenario results + overall verdict.
-- Extracted from runAll for testability: the verdict aggregation logic is subtle
-- (pcall returns true,false when a scenario returns false) and had a bug where
-- allPass was never updated on false returns — every prior "OVERALL: PASS" was
-- unverified because the code path that would set allPass=false on a scenario
-- returning false did not exist.
local function executeScenarios(scenarios, order, emitFn)
    local results = {}
    local allPass = true
    for _, name in ipairs(order) do
        emitFn(('[E2E] >>> running scenario: %s'):format(name))
        local loader = scenarios[name]
        if not loader then
            emitFn(('[E2E] unknown scenario: %s'):format(name))
            results[name] = false
            allPass = false
        else
            local ok, runner = pcall(loader)
            if not ok then
                emitFn(('[E2E] scenario %s failed to load: %s'):format(name, tostring(runner)))
                results[name] = false
                allPass = false
            else
                local runOk, runErr = pcall(runner)
                if not runOk then
                    emitFn(('[E2E] scenario %s crashed: %s'):format(name, tostring(runErr)))
                    results[name] = false
                    allPass = false
                else
                    results[name] = runErr
                    if not runErr then allPass = false end
                end
            end
        end
    end
    return results, allPass
end

local function runAll()
    -- Precondition: require at least one player online. Scenarios need a
    -- player to anchor vehicle spawns and provide an owner citizenid for
    -- test machines. Without one, every scenario silently no-ops with
    -- "no players online" — running the full suite is meaningless.
    local players = GetPlayers()
    if not players or #players == 0 then
        emit('[E2E] ========== PRECONDITION FAILED ==========')
        emit('[E2E] REFUSING TO RUN: no players online.')
        emit('[E2E] Scenarios require a player for vehicle spawning and owner context.')
        emit('[E2E] ========== OVERALL: FAIL ==========')
        return false
    end

    emit('[E2E] ========== RUNNING ALL SCENARIOS ==========')

    -- Clean up any stale e2e-prefixed rows from previous runs before
    -- starting. The harness previously did not clean up its own rows,
    -- causing dirty-state flapping (duplicate bill IDs, stale machines).
    if CZE2E and CZE2E.Slo and CZE2E.Slo.cleanup then
        CZE2E.Slo.cleanup()
    end

    local order = { 'repair_natives', 'production_chain', 'concurrent', 'failure_injection', 'downtime_catchup', 'load_test' }
    local results, allPass = executeScenarios(SCENARIOS, order, emit)
    emit('[E2E] ========== SCENARIO RESULTS ==========')
    for _, name in ipairs(order) do
        emit(('[E2E]   %s: %s'):format(name, results[name] and 'PASS' or 'FAIL'))
    end
    emit(('[E2E] ========== OVERALL: %s =========='):format(allPass and 'PASS' or 'FAIL'))

    -- Clean up e2e-prefixed rows after the run too, so the load_test
    -- machines (1000+) don't pollute the production tables.
    if CZE2E and CZE2E.Slo and CZE2E.Slo.cleanup then
        CZE2E.Slo.cleanup()
    end

    return allPass
end

local function runScenario(scenario)
    if not scenario or scenario == 'all' then
        return runAll()
    end
    local loader = SCENARIOS[scenario]
    if not loader then
        emit(('[E2E] unknown scenario: %s'):format(scenario))
        return false
    end
    local ok, runner = pcall(loader)
    if not ok then
        emit(('[E2E] scenario %s failed to load: %s'):format(scenario, tostring(runner)))
        return false
    end
    local runOk, runErr = pcall(runner)
    if not runOk then
        emit(('[E2E] scenario %s crashed: %s'):format(scenario, tostring(runErr)))
        return false
    end
    return runErr
end

-- Also register the console command.
-- Gated by the qb-czcraft-e2e resource state: if qb-czcraft-e2e is not
-- running, the command is disabled. This allows the manual playtest to
-- stop qb-czcraft-e2e and be confident the harness is fully disabled,
-- even though e2e_run.lua lives inside qb-czcraft.
RegisterCommand('cze2e', function(source, args)
    if source ~= 0 then return end
    if GetResourceState('qb-czcraft-e2e') ~= 'started' then
        print('[E2E] cze2e command disabled: qb-czcraft-e2e resource is not running.')
        print('[E2E] To enable: ensure qb-czcraft-e2e. To do the manual playtest: keep it stopped.')
        return
    end
    local scenario = args[1] or 'all'
    capturing = true
    local f = io.open(OUTPUT_FILE, 'w')
    if f then f:close() end
    local ok, result = pcall(runScenario, scenario)
    capturing = false
    if not ok then
        emit('[E2E] fatal error: ' .. tostring(result))
    end
end, true)

-- File-based command poller.
-- Consumes the command file by deletion (os.remove) before executing, with
-- io.open truncation as a fallback. If both fail, execution is skipped to
-- prevent infinite re-execution loops — the prior code used io.open write-
-- mode truncation which silently fails on bracketed paths ([meus-scripts])
-- in FiveM, causing the poller to re-execute the same command every second
-- indefinitely.
CreateThread(function()
    while true do
        Wait(1000)
        -- Only poll when the E2E resource is running. This allows the
        -- manual playtest to stop qb-czcraft-e2e and be confident the
        -- poller is not watching for commands.
        if GetResourceState('qb-czcraft-e2e') ~= 'started' then
            goto continue
        end
        local f = io.open(COMMAND_FILE, 'r')
        if f then
            local cmd = f:read('*l')
            f:close()

            -- Consume the command file before executing. Try os.remove
            -- first (more reliable than io.open write-mode on bracketed
            -- paths), then fall back to truncation. If both fail, skip
            -- execution to prevent infinite re-execution loops.
            -- NOTE: pcall(os.remove, ...) returns true even when os.remove
            -- returns nil, err (failure without throwing). Must check the
            -- second return value (os.remove's actual return) too.
            local consumed = false
            local rmOk, rmRes = pcall(os.remove, COMMAND_FILE)
            if rmOk and rmRes then
                consumed = true
            end
            if not consumed then
                local cf = io.open(COMMAND_FILE, 'w')
                if cf then
                    cf:close()
                    consumed = true
                end
            end

            if cmd and cmd ~= '' then
                if not consumed then
                    emit('[E2E] WARNING: could not consume command file (os.remove and io.open both failed)')
                    emit('[E2E] WARNING: skipping execution to prevent infinite loop')
                else
                    local of = io.open(OUTPUT_FILE, 'w')
                    if of then of:close() end
                    local sf = io.open(STATUS_FILE, 'w')
                    if sf then sf:write('running'); sf:close() end

                    capturing = true
                    emit(('[E2E] e2e runner: executing "%s"'):format(cmd))
                    local ok, result = pcall(runScenario, cmd)
                    capturing = false

                    if not ok then
                        emit('[E2E] fatal error: ' .. tostring(result))
                    end

                    sf = io.open(STATUS_FILE, 'w')
                    if sf then
                        sf:write(ok and 'done' or 'error')
                        sf:close()
                    end
                end
            end
        end
        ::continue::
    end
end)

print('[qb-czcraft] E2E runner loaded. Write scenario name to e2e_command.txt to trigger.')

-- Export for unit testing (the executeScenarios function is pure: it takes
-- a scenarios table, an order list, and an emit function, and returns
-- results + allPass. The verdict aggregation logic is tested in
-- tests/lua/unit/qb-czcraft/e2e_verdict_spec.lua.)
-- CZE2E may be nil if qb-czcraft-e2e hasn't loaded yet (load order: qb-czcraft
-- loads first). Initialize it defensively so the export doesn't error.
CZE2E = CZE2E or {}
CZE2E._executeScenarios = executeScenarios

-- Diagnostic: verify what's accessible in this environment.
-- Checks CZCraft globals, vehicle natives via multiple access methods,
-- and whether the _ENV hack is hiding natives that exist on the real _G.
CreateThread(function()
    Wait(2000)  -- wait for all qb-czcraft scripts to load

    -- CZCraft globals.
    print('[diag] CZCraft=' .. tostring(CZCraft ~= nil)
        .. ' MachinesRepo=' .. tostring(CZCraft.MachinesRepo ~= nil)
        .. ' Runtime=' .. tostring(CZCraft.Runtime ~= nil))

    -- Check vehicle natives as direct globals (the way repairkit.lua calls them).
    local natives = {
        'SetVehicleFixed', 'SetVehicleEngineHealth', 'SetVehicleBodyHealth',
        'SetVehiclePetrolTankHealth', 'SetVehicleWheelHealth', 'SetVehicleTyreBurst',
        'GetVehicleNumberOfWheels', 'GetVehicleEngineHealth', 'GetVehicleBodyHealth',
        'GetVehiclePetrolTankHealth', 'GetVehicleWheelHealth',
        'GetEntityHealth', 'GetEntityCoords', 'DoesEntityExist', 'GetEntityType',
        'NetworkGetEntityFromNetworkId', 'NetworkGetNetworkIdFromEntity',
        'CreateVehicleServerSetter', 'GetHashKey', 'GetPlayers', 'GetPlayerPed',
        'DeleteEntity', 'SetEntityCoords',
    }
    local parts = {}
    for _, name in ipairs(natives) do
        local v = _G[name]
        parts[#parts + 1] = name .. '=' .. (type(v) == 'function' and 'fn' or tostring(v))
    end
    print('[diag] natives: ' .. table.concat(parts, ' '))

    -- Check if Citizen.InvokeNative is available (alternative calling convention).
    print('[diag] Citizen=' .. tostring(Citizen ~= nil)
        .. ' InvokeNative=' .. tostring(Citizen and Citizen.InvokeNative ~= nil))

    -- Check if _G has a metatable that might intercept native lookups.
    local mt = getmetatable(_G)
    print('[diag] _G metatable=' .. tostring(mt ~= nil)
        .. ' __index=' .. tostring(mt and mt.__index ~= nil))

    -- Check if there's a separate native table (some FiveM versions use this).
    print('[diag] _ENV=_G=' .. tostring(_ENV == _G)
        .. ' rawget SetVehicleFixed=' .. tostring(rawget(_G, 'SetVehicleFixed') ~= nil))

    -- Check if natives are accessible via Citizen.InvokeNative with hash.
    -- SetVehicleFixed hash: 0x6806C51AD12B83B8
    if Citizen and Citizen.InvokeNative then
        print('[diag] Citizen.InvokeNative available — testing native calls via hash')

        -- Test: spawn a vehicle, try to call SetVehicleFixed via InvokeNative.
        local players = GetPlayers()
        if #players > 0 then
            local src = tonumber(players[1])
            local ped = GetPlayerPed(src)
            local coords = GetEntityCoords(ped)
            local hash = GetHashKey('sultan')
            local veh = CreateVehicleServerSetter(hash, 'automobile')
            SetEntityCoords(veh, coords.x + 3.0, coords.y + 3.0, coords.z, false, false, false, true)

            if veh and veh ~= 0 and DoesEntityExist(veh) then
                local netId = NetworkGetNetworkIdFromEntity(veh)
                print(('[diag] test vehicle: entity=%d netId=%d type=%d'):format(veh, netId, GetEntityType(veh)))

                -- Read initial health values.
                local initEngine = GetVehicleEngineHealth(veh)
                local initBody = GetVehicleBodyHealth(veh)
                local initPetrol = GetVehiclePetrolTankHealth(veh)
                print(('[diag] initial health: engine=%.1f body=%.1f petrol=%.1f'):format(initEngine, initBody, initPetrol))

                -- Try SetVehicleFixed via Citizen.InvokeNative.
                -- Hash: 0x6806C51AD12B83B8
                local okFix, errFix = pcall(Citizen.InvokeNative, 0x6806C51AD12B83B8, veh)
                print(('[diag] InvokeNative SetVehicleFixed: ok=%s err=%s'):format(tostring(okFix), tostring(errFix)))

                -- Try SetVehicleEngineHealth via Citizen.InvokeNative.
                -- Hash: 0x45F5E363
                local okEng, errEng = pcall(Citizen.InvokeNative, 0x45F5E363, veh, 500.0)
                print(('[diag] InvokeNative SetVehicleEngineHealth(500): ok=%s err=%s'):format(tostring(okEng), tostring(errEng)))

                -- Read back after InvokeNative calls.
                local afterEngine = GetVehicleEngineHealth(veh)
                local afterBody = GetVehicleBodyHealth(veh)
                local afterPetrol = GetVehiclePetrolTankHealth(veh)
                print(('[diag] after InvokeNative: engine=%.1f body=%.1f petrol=%.1f'):format(afterEngine, afterBody, afterPetrol))

                -- Also try the Lua global SetVehicleBodyHealth (which IS available).
                local okBody, errBody = pcall(SetVehicleBodyHealth, veh, 500.0)
                print(('[diag] global SetVehicleBodyHealth(500): ok=%s err=%s'):format(tostring(okBody), tostring(errBody)))
                local afterBody2 = GetVehicleBodyHealth(veh)
                print(('[diag] after SetVehicleBodyHealth: body=%.1f'):format(afterBody2))

                -- Cleanup.
                DeleteEntity(veh)
                print('[diag] test vehicle deleted')
            else
                print('[diag] could not create test vehicle')
            end
        else
            print('[diag] no players online for vehicle test')
        end
    else
        print('[diag] Citizen.InvokeNative NOT available')
    end
end)
