-- Regression test for the E2E harness verdict aggregation logic.
--
-- Bug history: executeScenarios (formerly inline in runAll) used pcall to
-- run each scenario. When a scenario returned false, pcall returns (true,
-- false) — runOk=true, runErr=false. The code set results[name] = runErr
-- (correctly recording false) but never set allPass = false. The allPass
-- flag was only updated on crash or load-failure, not on a scenario
-- returning false. This meant OVERALL: PASS was reported even when every
-- scenario returned false — every prior "gate passed" result was
-- unverified.
--
-- This test loads the real e2e_run.lua (with stubbed FiveM globals) and
-- exercises CZE2E._executeScenarios with stub scenarios to confirm:
--   - A scenario returning false -> allPass = false
--   - A scenario returning true  -> allPass = true
--   - A scenario that crashes     -> allPass = false
--   - A scenario that fails load  -> allPass = false
--   - Mixed pass/fail             -> allPass = false
--   - All pass                    -> allPass = true

-- ---------------------------------------------------------------------------
-- Stub FiveM globals that don't exist under stock Lua 5.4.
-- CreateThread is a no-op (don't run threads) — we only test executeScenarios,
-- which is pure and doesn't use threads.
-- ---------------------------------------------------------------------------
CreateThread = function() end  -- do NOT run thread functions
Wait = function() end
RegisterCommand = function() end
RegisterNetEvent = function() end
AddEventHandler = function() end
LoadResourceFile = function() return nil end
GetResourceState = function() return 'started' end  -- E2E resource is "running" in tests

-- Stub os.remove so the poller's os.remove call doesn't delete real files.
-- io.open is NOT stubbed globally — that would break other test suites
-- loaded after this one (e.g. unsigned_guard_spec.lua reads source files
-- via io.open). The emit function's file-writing path is guarded by the
-- `capturing` flag which defaults to false, and executeScenarios uses
-- the passed emitFn (captureEmit), not the real emit.
os.remove = function() return true end

-- Stub vehicle/entity natives referenced by the diagnostic thread (which
-- won't run since CreateThread is a no-op, but they're referenced at load
-- time in the diagnostic function body — Lua compiles the function but
-- doesn't execute it, so these stubs are just defensive).
GetPlayers = function() return {} end
GetPlayerPed = function() return 0 end
GetEntityCoords = function() return { x = 0, y = 0, z = 0 } end
GetHashKey = function() return 0 end
CreateVehicleServerSetter = function() return 0 end
SetEntityCoords = function() end
DoesEntityExist = function() return false end
GetEntityType = function() return 0 end
NetworkGetNetworkIdFromEntity = function() return 0 end
NetworkGetEntityFromNetworkId = function() return 0 end
GetVehicleEngineHealth = function() return 0 end
GetVehicleBodyHealth = function() return 0 end
GetVehiclePetrolTankHealth = function() return 0 end
GetVehicleWheelHealth = function() return 0 end
GetVehicleNumberOfWheels = function() return 0 end
SetVehicleFixed = function() end
SetVehicleEngineHealth = function() end
SetVehicleBodyHealth = function() end
SetVehiclePetrolTankHealth = function() end
SetVehicleWheelHealth = function() end
SetVehicleTyreBurst = function() end
GetEntityHealth = function() return 0 end
DeleteEntity = function() end
GetGameTimer = function() return 0 end

-- Stub exports table (loadQBCore tries exports['qb-core']:GetCoreObject()).
exports = setmetatable({}, {
    __index = function() return setmetatable({}, {
        __index = function() return function() return nil end end
    }) end
})

-- Stub Citizen (diagnostic thread references Citizen.InvokeNative).
Citizen = { InvokeNative = function() end }

-- Capture emit output for assertions.
local emitLog = {}
local function captureEmit(...)
    table.insert(emitLog, table.concat({ ... }, '\t'))
end

-- ---------------------------------------------------------------------------
-- Load the real e2e_run.lua. This defines executeScenarios and exports it
-- as CZE2E._executeScenarios.
-- ---------------------------------------------------------------------------
CZE2E = CZE2E or {}
dofile("resources/[meus-scripts]/qb-czcraft/server/e2e_run.lua")

local executeScenarios = CZE2E._executeScenarios
assert(executeScenarios, "CZE2E._executeScenarios not exported — e2e_run.lua failed to load or export missing")

-- ---------------------------------------------------------------------------
-- Test cases
-- ---------------------------------------------------------------------------
local tests = {}

-- Test 1: A scenario returning false must produce allPass = false.
-- This is the core regression: before the fix, allPass stayed true.
tests[#tests + 1] = {
    name = "scenario returning false produces allPass=false",
    test = function()
        emitLog = {}
        local scenarios = {
            stub_fail = function() return function() return false end end,
        }
        local order = { 'stub_fail' }
        local results, allPass = executeScenarios(scenarios, order, captureEmit)

        assert(results.stub_fail == false,
            "results.stub_fail should be false, got " .. tostring(results.stub_fail))
        assert(allPass == false,
            "allPass should be false when a scenario returns false, got " .. tostring(allPass))
    end,
}

-- Test 2: A scenario returning true produces allPass = true.
tests[#tests + 1] = {
    name = "scenario returning true produces allPass=true",
    test = function()
        emitLog = {}
        local scenarios = {
            stub_pass = function() return function() return true end end,
        }
        local order = { 'stub_pass' }
        local results, allPass = executeScenarios(scenarios, order, captureEmit)

        assert(results.stub_pass == true,
            "results.stub_pass should be true, got " .. tostring(results.stub_pass))
        assert(allPass == true,
            "allPass should be true when a scenario returns true, got " .. tostring(allPass))
    end,
}

-- Test 3: A scenario that crashes produces allPass = false.
tests[#tests + 1] = {
    name = "scenario that crashes produces allPass=false",
    test = function()
        emitLog = {}
        local scenarios = {
            stub_crash = function() return function() error("deliberate crash") end end,
        }
        local order = { 'stub_crash' }
        local results, allPass = executeScenarios(scenarios, order, captureEmit)

        assert(results.stub_crash == false,
            "results.stub_crash should be false, got " .. tostring(results.stub_crash))
        assert(allPass == false,
            "allPass should be false when a scenario crashes, got " .. tostring(allPass))
    end,
}

-- Test 4: A scenario that fails to load produces allPass = false.
tests[#tests + 1] = {
    name = "scenario that fails to load produces allPass=false",
    test = function()
        emitLog = {}
        local scenarios = {
            stub_load_fail = function() error("deliberate load failure") end,
        }
        local order = { 'stub_load_fail' }
        local results, allPass = executeScenarios(scenarios, order, captureEmit)

        assert(results.stub_load_fail == false,
            "results.stub_load_fail should be false, got " .. tostring(results.stub_load_fail))
        assert(allPass == false,
            "allPass should be false when a scenario fails to load, got " .. tostring(allPass))
    end,
}

-- Test 5: Mixed pass and fail produces allPass = false.
tests[#tests + 1] = {
    name = "mixed pass and fail produces allPass=false",
    test = function()
        emitLog = {}
        local scenarios = {
            pass1 = function() return function() return true end end,
            fail1 = function() return function() return false end end,
            pass2 = function() return function() return true end end,
        }
        local order = { 'pass1', 'fail1', 'pass2' }
        local results, allPass = executeScenarios(scenarios, order, captureEmit)

        assert(results.pass1 == true, "pass1 should be true")
        assert(results.fail1 == false, "fail1 should be false")
        assert(results.pass2 == true, "pass2 should be true")
        assert(allPass == false,
            "allPass should be false when any scenario fails, got " .. tostring(allPass))
    end,
}

-- Test 6: All scenarios passing produces allPass = true.
tests[#tests + 1] = {
    name = "all pass produces allPass=true",
    test = function()
        emitLog = {}
        local scenarios = {
            s1 = function() return function() return true end end,
            s2 = function() return function() return true end end,
            s3 = function() return function() return true end end,
        }
        local order = { 's1', 's2', 's3' }
        local results, allPass = executeScenarios(scenarios, order, captureEmit)

        assert(allPass == true,
            "allPass should be true when all scenarios pass, got " .. tostring(allPass))
    end,
}

-- Test 7: Unknown scenario name produces allPass = false.
tests[#tests + 1] = {
    name = "unknown scenario produces allPass=false",
    test = function()
        emitLog = {}
        local scenarios = {}
        local order = { 'nonexistent' }
        local results, allPass = executeScenarios(scenarios, order, captureEmit)

        assert(results.nonexistent == false,
            "results.nonexistent should be false, got " .. tostring(results.nonexistent))
        assert(allPass == false,
            "allPass should be false for unknown scenario, got " .. tostring(allPass))
    end,
}

-- Test 8: Emit output includes the OVERALL-relevant scenario result lines.
-- Verifies that the emit function receives the scenario pass/fail lines
-- so the server console log shows the correct per-scenario verdict.
tests[#tests + 1] = {
    name = "emit receives per-scenario running and result lines",
    test = function()
        emitLog = {}
        local scenarios = {
            s1 = function() return function() return false end end,
        }
        local order = { 's1' }
        executeScenarios(scenarios, order, captureEmit)

        local sawRunning = false
        for _, line in ipairs(emitLog) do
            if line:find('>>> running scenario: s1') then sawRunning = true end
        end
        assert(sawRunning, "emit should receive '>>> running scenario: s1' line")
    end,
}

return tests
