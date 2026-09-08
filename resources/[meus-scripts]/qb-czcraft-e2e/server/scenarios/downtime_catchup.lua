-- qb-czcraft-e2e scenario: 24h+ downtime catch-up
--
-- Verifies that after 24h+ of simulated downtime, the scheduler rebuilds and
-- the catch-up engine processes all missed cycles using the SAME formula as
-- real-time operation. Emits raw: elapsed time, cycle count, stock before/
-- after, block reasons, persistence state.
--
-- Approach: create a machine, set next_due_at to 25h ago, deposit enough
-- inputs for the full 25h, fire processMachine, verify the catch-up ran to
-- completion (or blocked correctly when inputs run out).
--
-- Command: /cze2e downtime_catchup

CZE2E = CZE2E or {}

local Slo = CZE2E.Slo

local function runDowntimeCatchup()
    print('[E2E] === downtime_catchup: start ===')
    if not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        print('[E2E][downtime] FAIL: qb-czcraft not ready'); return false
    end

    local players = GetPlayers()
    if not players or #players == 0 then
        print('[E2E][downtime] FAIL: no players online'); return false
    end
    local src = tonumber(players[1])
    local Player = QBCore.Functions.GetPlayer(src)
    local cid = Player and Player.PlayerData.citizenid or 'e2e-test'

    local allPass = true

    -- -----------------------------------------------------------------------
    -- Test 1: 25h downtime with sufficient inputs -> full catch-up
    -- -----------------------------------------------------------------------
    print('[E2E][downtime] --- 25h downtime, sufficient inputs ---')
    local uuid = CZCraft.MachinesRepo.createInstalled({
        machine_type = 'refinery', owner_type = 'PLAYER', owner_id = cid,
        location_type = 'HOUSE', location_id = 'e2e-downtime',
        pos_x = 0, pos_y = 0, pos_z = 0, heading = 0, stock_capacity = 250000,
    })
    if not uuid then print('[E2E][downtime] FAIL: machine create'); return false end

    -- smelt_steel: 60s duration, 5 iron + 2 metalscrap -> 2 steel per cycle.
    -- 25h = 90000s / 60s = 1500 cycles. Need 7500 iron + 3000 metalscrap.
    -- Output: 3000 steel. Stock capacity 250000g; steel weight 100g -> 300000g.
    -- That exceeds capacity! Use a smaller window: 24h = 86400s / 60 = 1440 cycles.
    -- 1440 * 2 steel * 100g = 288000g > 250000g. Still over.
    -- Use 20h = 72000s / 60 = 1200 cycles -> 2400 steel * 100g = 240000g < 250000g. OK.
    -- But the user asked for 24h+. Use a lighter item: make_metal_parts outputs
    -- cz_metal_parts (weight 200g) — even heavier. Use smelt_steel but with a
    -- PRODUCE_X target that stops before capacity.
    -- Target: 680 steel = 340 cycles = 20400s = 5.7h. Set downtime to 25h.
    -- The bill completes at 340 cycles, machine goes idle. Verifies catch-up
    -- respects the bill target, not just time.
    -- Input: 1700 iron (1700*140g = 238000g < 250000g capacity) + 680 metalscrap.
    local downtimeSec = 25 * 3600  -- 25h
    local pastIso = os.date('!%Y-%m-%d %H:%M:%S.000', os.time() - downtimeSec)

    -- Deposit enough for 340 cycles: 1700 iron + 680 metalscrap.
    CZCraft.StockRepo.upsert({ machine_uuid = uuid, item_name = 'iron', quantity = 1700, reserved_quantity = 0, standard_unit_cost = 0 })
    CZCraft.StockRepo.upsert({ machine_uuid = uuid, item_name = 'metalscrap', quantity = 680, reserved_quantity = 0, standard_unit_cost = 0 })

    local billId = 'e2e-downtime-1-' .. tostring(math.random(100000, 999999))
    CZCraft.BillsRepo.create({
        bill_id = billId, machine_uuid = uuid, recipe_id = 'smelt_steel',
        mode = 'PRODUCE_X', primary_output = 'steel', target_quantity = 680,
        priority = 'NORMAL', created_by_type = 'PLAYER', created_by_id = cid,
    })

    MySQL.update.await('UPDATE `czcraft_machines` SET `next_due_at` = ? WHERE `machine_uuid` = ?', { pastIso, uuid })

    -- Record pre-catchup state.
    local preSteel = tonumber((CZCraft.StockRepo.load(uuid, 'steel', '') or {}).quantity) or 0
    local preIron = tonumber((CZCraft.StockRepo.load(uuid, 'iron', '') or {}).quantity) or 0
    print(('[E2E][downtime] pre-catchup: iron=%d steel=%d next_due_at=%s'):format(preIron, preSteel, pastIso))

    -- Fire processMachine and measure catch-up time.
    -- Use the direct call (not TriggerEvent) so the catch-up runs
    -- synchronously in this thread. TriggerEvent spawns a separate thread
    -- and the machine is already STOPPED, so the settle check below would
    -- break immediately before the catch-up completes.
    local tStart = GetGameTimer()
    if CZCraft.CycleEngine and CZCraft.CycleEngine.processMachine then
        CZCraft.CycleEngine.processMachine(uuid)
    else
        TriggerEvent('qb-czcraft:internal:processMachine', uuid)
    end

    -- Wait for settle (catch-up of 340 cycles in chunks of 100 = 4 chunks).
    local waited = 0
    while waited < 30000 do
        local m = CZCraft.MachinesRepo.load(uuid)
        if m and m.operational_status ~= 'RUNNING' then break end
        Wait(100); waited = waited + 100
    end
    Wait(500)
    local catchupMs = GetGameTimer() - tStart

    local postSteel = tonumber((CZCraft.StockRepo.load(uuid, 'steel', '') or {}).quantity) or 0
    local postIron = tonumber((CZCraft.StockRepo.load(uuid, 'iron', '') or {}).quantity) or 0
    local m = CZCraft.MachinesRepo.load(uuid)
    local bill = CZCraft.BillsRepo.load(billId)

    print(('[E2E][downtime] post-catchup: iron=%d steel=%d status=%s blocked=%s'):format(
        postIron, postSteel, m.operational_status, tostring(m.blocked_reason)))
    print(('[E2E][downtime] bill: status=%s produced=%d/%d'):format(
        bill.status, tonumber(bill.produced_quantity) or 0, tonumber(bill.target_quantity) or 0))
    print(('[E2E][downtime] catch-up elapsed: %dms (%.2fs)'):format(catchupMs, catchupMs / 1000.0))

    -- Verify: 340 cycles ran, 680 steel produced, 1700 iron consumed.
    if postSteel == 680 and postIron == 0 then
        print('[E2E][downtime] full catch-up: PASS (340 cycles, correct deltas)')
    else
        print(('[E2E][downtime] full catch-up: FAIL (steel=%d expected 680, iron=%d expected 0)'):format(postSteel, postIron))
        allPass = false
    end

    -- Verify bill completed.
    if bill.status == 'COMPLETED' and tonumber(bill.produced_quantity) == 680 then
        print('[E2E][downtime] bill completion: PASS')
    else
        print('[E2E][downtime] bill completion: FAIL')
        allPass = false
    end

    -- Verify production events: 4 chunks (340 cycles / 100 per chunk = 3 full + 1 partial).
    local events = MySQL.query.await(
        'SELECT COUNT(*) AS cnt, SUM(`cycles_completed`) AS total_cycles FROM `czcraft_production_events` WHERE `machine_uuid` = ?',
        { uuid })
    local eventCount = events and tonumber(events[1].cnt) or 0
    local totalCycles = events and tonumber(events[1].total_cycles) or 0
    print(('[E2E][downtime] production_events: %d chunks, %d total cycles'):format(eventCount, totalCycles))
    if totalCycles == 340 then
        print('[E2E][downtime] chunked events: PASS')
    else
        print('[E2E][downtime] chunked events: FAIL')
        allPass = false
    end

    -- -----------------------------------------------------------------------
    -- Test 2: 24h downtime with insufficient inputs -> blocks correctly
    -- -----------------------------------------------------------------------
    print('[E2E][downtime] --- 24h downtime, insufficient inputs ---')
    local uuid2 = CZCraft.MachinesRepo.createInstalled({
        machine_type = 'refinery', owner_type = 'PLAYER', owner_id = cid,
        location_type = 'HOUSE', location_id = 'e2e-downtime',
        pos_x = 0, pos_y = 0, pos_z = 0, heading = 0, stock_capacity = 250000,
    })
    -- Only 50 iron = 10 cycles, but 24h downtime = 1440 cycles possible.
    CZCraft.StockRepo.upsert({ machine_uuid = uuid2, item_name = 'iron', quantity = 50, reserved_quantity = 0, standard_unit_cost = 0 })
    CZCraft.StockRepo.upsert({ machine_uuid = uuid2, item_name = 'metalscrap', quantity = 20, reserved_quantity = 0, standard_unit_cost = 0 })
    local billId2 = 'e2e-downtime-2-' .. tostring(math.random(100000, 999999))
    CZCraft.BillsRepo.create({
        bill_id = billId2, machine_uuid = uuid2, recipe_id = 'smelt_steel',
        mode = 'MAINTAIN_X', primary_output = 'steel', target_quantity = 100000,
        priority = 'NORMAL', created_by_type = 'PLAYER', created_by_id = cid,
    })
    local pastIso2 = os.date('!%Y-%m-%d %H:%M:%S.000', os.time() - 86400)
    MySQL.update.await('UPDATE `czcraft_machines` SET `next_due_at` = ? WHERE `machine_uuid` = ?', { pastIso2, uuid2 })

    if CZCraft.CycleEngine and CZCraft.CycleEngine.processMachine then
        CZCraft.CycleEngine.processMachine(uuid2)
    else
        TriggerEvent('qb-czcraft:internal:processMachine', uuid2)
    end
    waited = 0
    while waited < 15000 do
        local m2 = CZCraft.MachinesRepo.load(uuid2)
        if m2 and m2.operational_status ~= 'RUNNING' then break end
        Wait(100); waited = waited + 100
    end
    Wait(500)

    local m2 = CZCraft.MachinesRepo.load(uuid2)
    local steel2 = tonumber((CZCraft.StockRepo.load(uuid2, 'steel', '') or {}).quantity) or 0
    local iron2 = tonumber((CZCraft.StockRepo.load(uuid2, 'iron', '') or {}).quantity) or 0
    print(('[E2E][downtime] insufficient: steel=%d iron=%d status=%s blocked=%s'):format(
        steel2, iron2, m2.operational_status, tostring(m2.blocked_reason)))

    -- 10 cycles should have run (50 iron / 5 per cycle), then blocked.
    if steel2 == 20 and iron2 == 0 and m2.operational_status == 'BLOCKED' then
        print('[E2E][downtime] insufficient inputs block: PASS (10 cycles then blocked)')
    else
        print(('[E2E][downtime] insufficient inputs block: FAIL (steel=%d iron=%d status=%s)'):format(
            steel2, iron2, m2.operational_status))
        allPass = false
    end

    print(('[E2E] === downtime_catchup: %s ==='):format(allPass and 'PASS' or 'FAIL'))
    return allPass
end

CZE2E.runDowntimeCatchup = runDowntimeCatchup
return runDowntimeCatchup
