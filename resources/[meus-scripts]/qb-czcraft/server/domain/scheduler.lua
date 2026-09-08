-- qb-czcraft scheduler (pure heap + wake logic)
-- Global min-heap of due times keyed by machine_uuid. No per-machine loops.
-- The heap is rebuilt at startup from czcraft_machines.next_due_at. Indexed
-- polling is a recovery safety net only.

CZCraft = CZCraft or {}

-- A binary min-heap keyed by `due_at`.
-- Entries: { due_at = number, machine_uuid = string }
local Scheduler = {}

-- Creates a new empty heap.
-- @return table heap
function Scheduler.newHeap()
    return { size = 0, entries = {} }
end

-- Swaps two heap entries.
local function swap(entries, i, j)
    entries[i], entries[j] = entries[j], entries[i]
end

-- Bubbles an entry up from index i.
local function bubbleUp(entries, i)
    while i > 1 do
        local parent = math.floor(i / 2)
        if entries[i].due_at < entries[parent].due_at then
            swap(entries, i, parent)
            i = parent
        else
            break
        end
    end
end

-- Sinks an entry down from index i.
local function sinkDown(entries, size, i)
    while true do
        local left = i * 2
        local right = left + 1
        local smallest = i
        if left <= size and entries[left].due_at < entries[smallest].due_at then
            smallest = left
        end
        if right <= size and entries[right].due_at < entries[smallest].due_at then
            smallest = right
        end
        if smallest ~= i then
            swap(entries, i, smallest)
            i = smallest
        else
            break
        end
    end
end

-- Inserts an entry into the heap.
-- @param heap table
-- @param due_at number unix timestamp
-- @param machine_uuid string
function Scheduler.push(heap, due_at, machine_uuid)
    local n = heap.size + 1
    heap.size = n
    heap.entries[n] = { due_at = due_at, machine_uuid = machine_uuid }
    bubbleUp(heap.entries, n)
end

-- Pops the earliest-due entry from the heap.
-- @param heap table
-- @return table|nil { due_at, machine_uuid }
function Scheduler.pop(heap)
    if heap.size == 0 then
        return nil
    end
    local entries = heap.entries
    local top = entries[1]
    entries[1] = entries[heap.size]
    entries[heap.size] = nil
    heap.size = heap.size - 1
    if heap.size > 0 then
        sinkDown(entries, heap.size, 1)
    end
    return top
end

-- Peeks at the earliest-due entry without removing it.
-- @param heap table
-- @return table|nil
function Scheduler.peek(heap)
    return heap.size > 0 and heap.entries[1] or nil
end

-- Removes a specific machine_uuid from the heap (for wake/re-heap).
-- Rebuilds the heap after removal. This is O(n) but wakes are infrequent
-- relative to cycle ticks.
-- @param heap table
-- @param machine_uuid string
function Scheduler.remove(heap, machine_uuid)
    local entries = heap.entries
    local found = nil
    for i = 1, heap.size do
        if entries[i].machine_uuid == machine_uuid then
            found = i
            break
        end
    end
    if not found then return end

    -- Replace with last, then rebuild.
    entries[found] = entries[heap.size]
    entries[heap.size] = nil
    heap.size = heap.size - 1
    if heap.size > 0 then
        -- Rebuild the entire heap to maintain invariant.
        for i = math.floor(heap.size / 2), 1, -1 do
            sinkDown(entries, heap.size, i)
        end
    end
end

-- Re-heap a machine with a new due time (wake on stock/cycle/bill/config change).
-- @param heap table
-- @param machine_uuid string
-- @param due_at number
function Scheduler.wake(heap, machine_uuid, due_at)
    Scheduler.remove(heap, machine_uuid)
    Scheduler.push(heap, due_at, machine_uuid)
end

-- Rebuilds the heap from a list of { machine_uuid, next_due_at } rows.
-- Called at startup.
--
-- oxmysql returns DATETIME(3) columns as millisecond timestamps (ms since
-- epoch), not strings. A numeric value >= 1e11 is treated as ms and divided
-- by 1000 to normalize to seconds (a seconds timestamp for years 2001..2286
-- is 10 digits, < 1e11). String values are parsed via the ISO regex.
-- @param rows table
-- @return table heap
function Scheduler.buildFromRows(rows)
    local heap = Scheduler.newHeap()
    if type(rows) ~= 'table' then return heap end
    for _, row in ipairs(rows) do
        if row.machine_uuid and row.next_due_at then
            local dueAt = row.next_due_at
            if type(dueAt) == 'number' then
                if dueAt >= 1e11 then dueAt = math.floor(dueAt / 1000) end
            elseif type(dueAt) == 'string' then
                local y, mo, d, h, mi, s = dueAt:match('^(%d+)-(%d+)-(%d+)%s+(%d+):(%d+):(%d+)')
                if y then
                    local year, month, day = tonumber(y), tonumber(mo), tonumber(d)
                    local yy = year - (month <= 2 and 1 or 0)
                    local era = math.floor(yy / 400)
                    if yy < 0 and (yy % 400 ~= 0) then era = era - 1 end
                    local yoe = yy - era * 400
                    local mp = month > 2 and month - 3 or month + 9
                    local doy = math.floor((153 * mp + 2) / 5) + day - 1
                    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
                    local days = era * 146097 + doe - 719468
                    dueAt = days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
                else
                    dueAt = tonumber(dueAt) or 0
                end
            else
                dueAt = 0
            end
            Scheduler.push(heap, dueAt, row.machine_uuid)
        end
    end
    return heap
end

-- Returns all machine_uuids whose due_at <= now, popping them from the heap.
-- Used by the scheduler tick to process due machines in chunks.
-- @param heap table
-- @param now number
-- @param maxCount number
-- @return table dueMachines = { { due_at, machine_uuid } }
function Scheduler.popDue(heap, now, maxCount)
    local due = {}
    local count = 0
    while count < (maxCount or 100) do
        local top = Scheduler.peek(heap)
        if not top or top.due_at > now then
            break
        end
        Scheduler.pop(heap)
        count = count + 1
        due[count] = top
    end
    return due
end

CZCraft.Scheduler = Scheduler
return Scheduler
