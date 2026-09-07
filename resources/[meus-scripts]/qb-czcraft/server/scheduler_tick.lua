-- qb-czcraft scheduler tick
-- Wires the pure scheduler heap to the database. At startup, rebuilds the heap
-- from czcraft_machines.next_due_at. Each tick, pops due machines and processes
-- them in bounded chunks. Indexed polling is a recovery safety net.

CZCraft = CZCraft or {}

local SchedulerTick = {}

local TICK_INTERVAL_MS = 1000      -- 1 second
local MAX_MACHINES_PER_TICK = 100  -- chunk size to bound lock duration

-- The global heap, built at startup.
local heap = nil

-- Rebuilds the heap at startup from the database.
function SchedulerTick.rebuildAtStartup()
    local rows = MySQL.query.await([[
        SELECT `machine_uuid`, `next_due_at`
        FROM `czcraft_machines`
        WHERE `lifecycle` = 'INSTALLED'
          AND `next_due_at` IS NOT NULL
        ORDER BY `next_due_at` ASC
    ]]) or {}
    heap = CZCraft.Scheduler.buildFromRows(rows)
    print(('[qb-czcraft] Scheduler heap rebuilt: %d machines queued'):format(heap.size))
end

-- Wakes a machine (re-heaps it with a new due time).
-- Called on stock, cycle, bill, config, or admin changes.
-- @param machineUuid string
-- @param dueAtUnix number unix timestamp (seconds)
function SchedulerTick.wake(machineUuid, dueAtUnix)
    if not heap then return end
    CZCraft.Scheduler.wake(heap, machineUuid, dueAtUnix)
end

-- Processes due machines in a bounded chunk. Called each tick.
function SchedulerTick.processDue()
    if not heap or not CZCraft.Runtime or not CZCraft.Runtime.isReady then
        return
    end
    if not CZCraft.Config.General.features.scheduler then
        return
    end

    local now = os.time()
    local due = CZCraft.Scheduler.popDue(heap, now, MAX_MACHINES_PER_TICK)

    if #due == 0 then
        return
    end

    for _, entry in ipairs(due) do
        -- Trigger the machine processing event. The cycle engine handler
        -- (to be wired in the api layer) will load the machine, select a bill,
        -- start/complete cycles, and re-heap the machine with its next due time.
        TriggerEvent('qb-czcraft:internal:processMachine', entry.machine_uuid)
    end
end

-- Starts the scheduler tick loop. Called once at resource start after the
-- schema gate passes.
function SchedulerTick.start()
    if not CZCraft.Config.General.features.scheduler then
        print('[qb-czcraft] Scheduler disabled by feature flag')
        return
    end

    SchedulerTick.rebuildAtStartup()

    CreateThread(function()
        while true do
            Wait(TICK_INTERVAL_MS)
            SchedulerTick.processDue()
        end
    end)

    -- Recovery safety net: indexed polling every 30 seconds in case the heap
    -- drifts from the database (e.g. external mutation, crash recovery).
    CreateThread(function()
        while true do
            Wait(30000)
            if CZCraft.Runtime and CZCraft.Runtime.isReady then
                local nowIso = os.date('!%Y-%m-%d %H:%M:%S', os.time())
                local rows = CZCraft.CyclesRepo.listDueMachines(nowIso, MAX_MACHINES_PER_TICK)
                for _, row in ipairs(rows) do
                    SchedulerTick.wake(row.machine_uuid, os.time())
                end
            end
        end
    end)

    print('[qb-czcraft] Scheduler tick started')
end

-- Internal wake event handler (called by the api layer on stock/cycle/bill changes).
RegisterNetEvent('qb-czcraft:internal:wake', function(machineUuid)
    SchedulerTick.wake(machineUuid, os.time())
end)

CZCraft.SchedulerTick = SchedulerTick
return SchedulerTick
