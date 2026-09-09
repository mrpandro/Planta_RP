-- qb-czcraft-e2e file-based command runner
-- Polls a command file and executes scenarios, writing output to a result file.
-- This bypasses both RCON and HTTP handlers — it's a simple file-based IPC.
--
-- Usage:
--   1. Write scenario name to e2e_command.txt (e.g., "all" or "repair_natives")
--   2. The runner picks it up, executes the scenario, captures print output
--   3. Results are written to e2e_output.txt (appended as the scenario runs)
--   4. e2e_status.txt is set to "done" when complete

CZE2E = CZE2E or {}

local COMMAND_FILE = 'resources/[meus-scripts]/qb-czcraft-e2e/e2e_command.txt'
local OUTPUT_FILE = 'resources/[meus-scripts]/qb-czcraft-e2e/e2e_output.txt'
local STATUS_FILE = 'resources/[meus-scripts]/qb-czcraft-e2e/e2e_status.txt'

-- Wraps print to also append to the output file when capturing.
local originalPrint = print
local capturing = false

local function capturedPrint(...)
    originalPrint(...)
    if capturing then
        local args = { ... }
        local parts = {}
        for i = 1, #args do parts[i] = tostring(args[i]) end
        local line = table.concat(parts, '\t')
        local f = io.open(OUTPUT_FILE, 'a')
        if f then f:write(line, '\n'); f:close() end
    end
end
print = capturedPrint

-- Scenario loaders. FiveM doesn't have `dofile`, so we use LoadResourceFile + load.
local function loadScenario(path)
    local content = LoadResourceFile('qb-czcraft-e2e', path)
    if not content then
        error('could not load scenario file: ' .. path)
    end
    local fn, err = load(content, '@qb-czcraft-e2e/' .. path)
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
    print('[E2E] ========== RUNNING ALL SCENARIOS ==========')
    local order = { 'repair_natives', 'production_chain', 'concurrent', 'failure_injection', 'downtime_catchup', 'load_test' }
    local results = {}
    local allPass = true
    for _, name in ipairs(order) do
        print(('[E2E] >>> running scenario: %s'):format(name))
        local loader = SCENARIOS[name]
        if not loader then
            print(('[E2E] unknown scenario: %s'):format(name))
            results[name] = false
            allPass = false
        else
            local ok, runner = pcall(loader)
            if not ok then
                print(('[E2E] scenario %s failed to load: %s'):format(name, tostring(runner)))
                results[name] = false
                allPass = false
            else
                local runOk, runErr = pcall(runner)
                if not runOk then
                    print(('[E2E] scenario %s crashed: %s'):format(name, tostring(runErr)))
                    results[name] = false
                    allPass = false
                else
                    results[name] = runErr
                    if not runErr then allPass = false end
                end
            end
        end
    end
    print('[E2E] ========== SCENARIO RESULTS ==========')
    for _, name in ipairs(order) do
        print(('[E2E]   %s: %s'):format(name, results[name] and 'PASS' or 'FAIL'))
    end
    print(('[E2E] ========== OVERALL: %s =========='):format(allPass and 'PASS' or 'FAIL'))
    return allPass
end

local function runScenario(scenario)
    if not scenario or scenario == 'all' then
        return runAll()
    end
    local loader = SCENARIOS[scenario]
    if not loader then
        print(('[E2E] unknown scenario: %s'):format(scenario))
        return false
    end
    local ok, runner = pcall(loader)
    if not ok then
        print(('[E2E] scenario %s failed to load: %s'):format(scenario, tostring(runner)))
        return false
    end
    local runOk, runErr = pcall(runner)
    if not runOk then
        print(('[E2E] scenario %s crashed: %s'):format(scenario, tostring(runErr)))
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
        print('[E2E] fatal error: ' .. tostring(result))
    end
end, true)

-- File-based command poller.
CreateThread(function()
    while true do
        Wait(1000)
        local f = io.open(COMMAND_FILE, 'r')
        if f then
            local cmd = f:read('*l')
            f:close()
            -- Delete the command file so it doesn't re-trigger.
            os.remove(COMMAND_FILE)

            if cmd and cmd ~= '' then
                -- Clear output file and start capturing.
                local of = io.open(OUTPUT_FILE, 'w')
                if of then of:close() end
                local sf = io.open(STATUS_FILE, 'w')
                if sf then sf:write('running'); sf:close() end

                capturing = true
                print(('[E2E] file runner: executing "%s"'):format(cmd))
                local ok, result = pcall(runScenario, cmd)
                capturing = false

                if not ok then
                    print('[E2E] fatal error: ' .. tostring(result))
                end

                -- Write status.
                sf = io.open(STATUS_FILE, 'w')
                if sf then
                    sf:write(ok and 'done' or 'error')
                    sf:close()
                end
            end
        end
    end
end)

originalPrint('[qb-czcraft-e2e] file runner loaded. Write scenario name to e2e_command.txt to trigger.')
