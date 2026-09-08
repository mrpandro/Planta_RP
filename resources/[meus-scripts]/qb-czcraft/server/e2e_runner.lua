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
local COMMAND_FILE = 'resources/[meus-scripts]/qb-czcraft-e2e/e2e_command.txt'
local OUTPUT_FILE = 'resources/[meus-scripts]/qb-czcraft-e2e/e2e_output.txt'
local STATUS_FILE = 'resources/[meus-scripts]/qb-czcraft-e2e/e2e_status.txt'

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

local SCENARIOS = {
    repair_natives = function() return loadScenario('server/scenarios/repair_natives.lua') end,
    production_chain = function() return loadScenario('server/scenarios/production_chain.lua') end,
    concurrent = function() return loadScenario('server/scenarios/concurrent.lua') end,
    failure_injection = function() return loadScenario('server/scenarios/failure_injection.lua') end,
    downtime_catchup = function() return loadScenario('server/scenarios/downtime_catchup.lua') end,
    load_test = function() return loadScenario('server/scenarios/load_test.lua') end,
}

local function runAll()
    emit('[E2E] ========== RUNNING ALL SCENARIOS ==========')
    local order = { 'repair_natives', 'production_chain', 'concurrent', 'failure_injection', 'downtime_catchup', 'load_test' }
    local results = {}
    local allPass = true
    for _, name in ipairs(order) do
        emit(('[E2E] >>> running scenario: %s'):format(name))
        local loader = SCENARIOS[name]
        if not loader then
            emit(('[E2E] unknown scenario: %s'):format(name))
            results[name] = false
            allPass = false
        else
            local ok, runner = pcall(loader)
            if not ok then
                emit(('[E2E] scenario %s failed to load: %s'):format(name, tostring(runner)))
                results[name] = false
                allPass = false
            else
                local runOk, runErr = pcall(runner)
                if not runOk then
                    emit(('[E2E] scenario %s crashed: %s'):format(name, tostring(runErr)))
                    results[name] = false
                    allPass = false
                else
                    results[name] = runErr
                end
            end
        end
    end
    emit('[E2E] ========== SCENARIO RESULTS ==========')
    for _, name in ipairs(order) do
        emit(('[E2E]   %s: %s'):format(name, results[name] and 'PASS' or 'FAIL'))
    end
    emit(('[E2E] ========== OVERALL: %s =========='):format(allPass and 'PASS' or 'FAIL'))
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
RegisterCommand('cze2e', function(source, args)
    if source ~= 0 then return end
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
-- Overwrites the command file with empty content after reading to mark as consumed.
CreateThread(function()
    while true do
        Wait(1000)
        local f = io.open(COMMAND_FILE, 'r')
        if f then
            local cmd = f:read('*l')
            f:close()
            -- Overwrite with empty content to mark as consumed.
            local cf = io.open(COMMAND_FILE, 'w')
            if cf then cf:close() end

            if cmd and cmd ~= '' then
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
end)

print('[qb-czcraft] E2E runner loaded. Write scenario name to e2e_command.txt to trigger.')

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
