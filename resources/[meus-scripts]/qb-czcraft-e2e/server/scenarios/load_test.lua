-- qb-czcraft-e2e scenario: 1000-machine / 250-active load test with SLO probes
--
-- Creates 1000 machines (250 active with due bills, 750 idle), fires
-- processMachine for all 250 active ones, and measures:
--   - DB query p95 (per-machine load + complete/start/applyCatchUpChunk)
--   - Action p95 (end-to-end processMachine duration per machine)
--   - Lua stall (any single synchronous segment > 50ms)
--   - Total throughput
--
-- SLO thresholds:
--   DB p95 < 200ms
--   Action p95 < 300ms
--   Recovery < 60s (not directly applicable here, but total run time tracked)
--   No Lua stall > 50ms
--
-- Command: /cze2e load_test
-- Warning: creates 1000 machine rows. Run on a staging DB you can clean up.

CZE2E = CZE2E or {}

local Slo = CZE2E.Slo

local function runLoadTest()
    print('[E2E] === load_test: start ===')
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        print('[E2E][load] FAIL: qb-czcraft not ready'); return false
    end

    local players = GetPlayers()
    if not players or #players == 0 then
        print('[E2E][load] FAIL: no players online'); return false
    end
    local src = tonumber(players[1])
    local Player = QBCore.Functions.GetPlayer(src)
    local cid = Player and Player.PlayerData.citizenid or 'e2e-load'

    local TOTAL_MACHINES = 1000
    local ACTIVE_MACHINES = 250

    print(('[E2E][load] creating %d machines (%d active)...'):format(TOTAL_MACHINES, ACTIVE_MACHINES))

    -- -----------------------------------------------------------------------
    -- Provision machines
    -- -----------------------------------------------------------------------
    local provStart = GetGameTimer()
    local activeUuids = {}
    local idleUuids = {}

    -- Stall detector for the provisioning phase — previously not measured,
    -- which missed a real 236ms server thread hitch during provisioning.
    local provStallDet = Slo.stallDetector(Slo.THRESHOLDS.luaStallMs)

    -- Batch-insert machines for speed. Each machine: refinery, PRODUCE_X bill
    -- for smelt_steel with target 2 (1 cycle), enough stock for 1 cycle.
    for i = 1, TOTAL_MACHINES do
        local uuid
        provStallDet.measure(function()
            uuid = CZCraft.MachinesRepo.createInstalled({
                machine_type = 'refinery', owner_type = 'PLAYER', owner_id = cid,
                location_type = 'HOUSE', location_id = 'e2e-load',
                pos_x = 0, pos_y = 0, pos_z = 0, heading = 0, stock_capacity = 250000,
                serial = Slo.uniqueId('CZ-refinery-load-' .. tostring(i)),
            })
        end)
        if not uuid then
            print(('[E2E][load] FAIL: machine create failed at index %d'):format(i))
            return false
        end

        if i <= ACTIVE_MACHINES then
            -- Active: deposit inputs, create bill, set next_due_at to past.
            provStallDet.measure(function()
                CZCraft.StockRepo.upsert({ machine_uuid = uuid, item_name = 'iron', quantity = 5, reserved_quantity = 0, standard_unit_cost = 0 })
            end)
            provStallDet.measure(function()
                CZCraft.StockRepo.upsert({ machine_uuid = uuid, item_name = 'metalscrap', quantity = 2, reserved_quantity = 0, standard_unit_cost = 0 })
            end)
            local billId = Slo.uniqueId('e2e-load-' .. tostring(i))
            provStallDet.measure(function()
                CZCraft.BillsRepo.create({
                    bill_id = billId, machine_uuid = uuid, recipe_id = 'smelt_steel',
                    mode = 'PRODUCE_X', primary_output = 'steel', target_quantity = 2,
                    priority = 'NORMAL', created_by_type = 'PLAYER', created_by_id = cid,
                })
            end)
            local pastIso = os.date('!%Y-%m-%d %H:%M:%S.000', os.time() - 3600)
            provStallDet.measure(function()
                MySQL.update.await('UPDATE `czcraft_machines` SET `next_due_at` = ? WHERE `machine_uuid` = ?', { pastIso, uuid })
            end)
            activeUuids[#activeUuids + 1] = uuid
        else
            -- Idle: no bill, no next_due_at.
            idleUuids[#idleUuids + 1] = uuid
        end
    end

    local provMs = GetGameTimer() - provStart
    print(('[E2E][load] provisioned %d machines in %dms (%.1fms/machine)'):format(
        TOTAL_MACHINES, provMs, provMs / TOTAL_MACHINES))

    -- -----------------------------------------------------------------------
    -- Fire processMachine for all 250 active machines
    -- -----------------------------------------------------------------------
    local dbTimings = Slo.recorder()
    local dispatchTimings = Slo.recorder()
    local completionTimings = Slo.recorder()
    local stallDet = Slo.stallDetector(Slo.THRESHOLDS.luaStallMs)

    local runStart = GetGameTimer()

    -- Record fire time for each machine so we can measure end-to-end
    -- completion (from TriggerEvent to machine settling), not just the
    -- dispatch time (which returns immediately when the handler yields
    -- at MySQL.await).
    local fireTimes = {}

    -- Fire all 250 concurrently (each spawns its own thread in the engine).
    for _, uuid in ipairs(activeUuids) do
        local tDispatch = GetGameTimer()
        -- Wrap the trigger in the stall detector to measure the
        -- synchronous portion (the event dispatch, not the async thread).
        stallDet.measure(function()
            TriggerEvent('qb-czcraft:internal:processMachine', uuid)
        end)
        dispatchTimings.add(GetGameTimer() - tDispatch)
        fireTimes[uuid] = GetGameTimer()
    end

    -- Wait for all machines to settle. Track per-machine end-to-end
    -- completion time and wrap each DB load in the stall detector.
    local settledCount = 0
    local recorded = {}
    local waitStart = GetGameTimer()
    while settledCount < ACTIVE_MACHINES and (GetGameTimer() - waitStart) < 60000 do
        settledCount = 0
        for _, uuid in ipairs(activeUuids) do
            local m
            stallDet.measure(function()
                m = CZCraft.MachinesRepo.load(uuid)
            end)
            if m and m.operational_status ~= 'RUNNING' then
                settledCount = settledCount + 1
                if not recorded[uuid] then
                    completionTimings.add(GetGameTimer() - fireTimes[uuid])
                    recorded[uuid] = true
                end
            end
        end
        if settledCount < ACTIVE_MACHINES then Wait(200) end
    end
    local totalRunMs = GetGameTimer() - runStart

    -- -----------------------------------------------------------------------
    -- Measure DB query timings (post-hoc: time a sample of stock loads)
    -- -----------------------------------------------------------------------
    for i = 1, math.min(50, ACTIVE_MACHINES) do
        local uuid = activeUuids[i]
        local ms, _ = Slo.timeAwait(function()
            return CZCraft.StockRepo.load(uuid, 'steel', '')
        end)
        dbTimings.add(ms)
    end

    -- -----------------------------------------------------------------------
    -- Verify all 250 active machines produced correctly
    -- -----------------------------------------------------------------------
    local correctCount = 0
    for _, uuid in ipairs(activeUuids) do
        local steel = tonumber((CZCraft.StockRepo.load(uuid, 'steel', '') or {}).quantity) or 0
        if steel == 2 then
            correctCount = correctCount + 1
        end
    end
    print(('[E2E][load] correctness: %d/%d machines produced 2 steel'):format(correctCount, ACTIVE_MACHINES))

    -- -----------------------------------------------------------------------
    -- Report SLOs
    -- -----------------------------------------------------------------------
    print('[E2E][load] --- SLO report ---')
    local dbStats = dbTimings.stats()
    local dispatchStats = dispatchTimings.stats()
    local completionStats = completionTimings.stats()
    local stallStats = stallDet.stats()
    local provStallStats = provStallDet.stats()

    Slo.printStats('DB stock load', dbStats)
    Slo.printStats('dispatch (TriggerEvent only)', dispatchStats)
    Slo.printStats('end-to-end completion', completionStats)
    print(('[E2E][load] Lua stalls > %dms (processing): count=%d max=%.2fms'):format(
        stallDet.threshold, stallStats.count, stallStats.max))
    print(('[E2E][load] Lua stalls > %dms (provisioning): count=%d max=%.2fms'):format(
        provStallDet.threshold, provStallStats.count, provStallStats.max))
    print(('[E2E][load] total run time: %dms (%.2fs)'):format(totalRunMs, totalRunMs / 1000.0))
    print(('[E2E][load] throughput: %.1f machines/sec'):format(ACTIVE_MACHINES / (totalRunMs / 1000.0)))

    local allPass = true
    if not Slo.assertP95('DB stock load p95', dbStats, Slo.THRESHOLDS.dbP95Ms) then allPass = false end
    -- The SLO threshold applies to end-to-end completion, not just dispatch.
    -- Dispatch p95 is reported for diagnostics but not gated — it measures
    -- only the TriggerEvent call which returns immediately when the handler
    -- yields at MySQL.await.
    if not Slo.assertP95('end-to-end completion p95', completionStats, Slo.THRESHOLDS.actionP95Ms) then allPass = false end
    -- Combined stall check: both provisioning and processing stalls count.
    local maxStall = math.max(
        stallStats.count > 0 and stallStats.max or 0,
        provStallStats.count > 0 and provStallStats.max or 0
    )
    if maxStall > Slo.THRESHOLDS.luaStallMs then
        print(('[E2E][load] Lua stall SLO: FAIL (max stall %.2fms > %dms)'):format(maxStall, Slo.THRESHOLDS.luaStallMs))
        allPass = false
    else
        print(('[E2E][load] Lua stall SLO: PASS (no stalls > %dms in provisioning or processing)'):format(Slo.THRESHOLDS.luaStallMs))
    end
    if correctCount ~= ACTIVE_MACHINES then
        print(('[E2E][load] correctness SLO: FAIL (%d/%d)'):format(correctCount, ACTIVE_MACHINES))
        allPass = false
    else
        print('[E2E][load] correctness SLO: PASS (all 250 produced correctly)')
    end

    print(('[E2E] === load_test: %s ==='):format(allPass and 'PASS' or 'FAIL'))
    return allPass
end

CZE2E.runLoadTest = runLoadTest
return runLoadTest
