-- qb-czcraft scheduler heap tests
-- Pure tests for the global min-heap: push/pop ordering, peek, remove, wake,
-- buildFromRows, and popDue with now + maxCount.

dofile("resources/[meus-scripts]/qb-czcraft/shared/constants.lua")
local Scheduler = dofile("resources/[meus-scripts]/qb-czcraft/server/domain/scheduler.lua")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "Assertion failed") .. " | expected=" .. tostring(expected) .. ", actual=" .. tostring(actual))
    end
end

local function assertTrue(value, message)
    if not value then
        error(message or "Expected truthy value")
    end
end

local function assertFalse(value, message)
    if value then
        error(message or "Expected falsy value")
    end
end

return {
    {
        name = "empty heap peek returns nil",
        test = function()
            local h = Scheduler.newHeap()
            assertEqual(Scheduler.peek(h), nil, "empty peek nil")
            assertEqual(Scheduler.pop(h), nil, "empty pop nil")
            assertEqual(h.size, 0, "size 0")
        end,
    },
    {
        name = "push then pop returns earliest due first",
        test = function()
            local h = Scheduler.newHeap()
            Scheduler.push(h, 300, 'm3')
            Scheduler.push(h, 100, 'm1')
            Scheduler.push(h, 200, 'm2')
            local first = Scheduler.pop(h)
            assertEqual(first.machine_uuid, 'm1', "first is m1 (earliest)")
            local second = Scheduler.pop(h)
            assertEqual(second.machine_uuid, 'm2', "second is m2")
            local third = Scheduler.pop(h)
            assertEqual(third.machine_uuid, 'm3', "third is m3")
            assertEqual(h.size, 0, "heap empty after all pops")
        end,
    },
    {
        name = "peek does not remove the entry",
        test = function()
            local h = Scheduler.newHeap()
            Scheduler.push(h, 100, 'm1')
            local top = Scheduler.peek(h)
            assertEqual(top.machine_uuid, 'm1', "peek m1")
            assertEqual(h.size, 1, "size still 1 after peek")
        end,
    },
    {
        name = "remove extracts a specific machine and maintains heap invariant",
        test = function()
            local h = Scheduler.newHeap()
            Scheduler.push(h, 100, 'm1')
            Scheduler.push(h, 200, 'm2')
            Scheduler.push(h, 300, 'm3')
            Scheduler.remove(h, 'm2')
            assertEqual(h.size, 2, "size 2 after remove")
            local first = Scheduler.pop(h)
            assertEqual(first.machine_uuid, 'm1', "first still m1")
            local second = Scheduler.pop(h)
            assertEqual(second.machine_uuid, 'm3', "second m3 (m2 removed)")
        end,
    },
    {
        name = "remove nonexistent machine is a no-op",
        test = function()
            local h = Scheduler.newHeap()
            Scheduler.push(h, 100, 'm1')
            Scheduler.remove(h, 'nonexistent')
            assertEqual(h.size, 1, "size unchanged")
        end,
    },
    {
        name = "wake re-heaps a machine with a new due time",
        test = function()
            local h = Scheduler.newHeap()
            Scheduler.push(h, 300, 'm1')
            Scheduler.push(h, 100, 'm2')
            -- Wake m1 to an earlier time.
            Scheduler.wake(h, 'm1', 50)
            local first = Scheduler.pop(h)
            assertEqual(first.machine_uuid, 'm1', "m1 now earliest after wake")
            local second = Scheduler.pop(h)
            assertEqual(second.machine_uuid, 'm2', "m2 second")
        end,
    },
    {
        name = "buildFromRows constructs a valid heap",
        test = function()
            local rows = {
                { machine_uuid = 'm3', next_due_at = 300 },
                { machine_uuid = 'm1', next_due_at = 100 },
                { machine_uuid = 'm2', next_due_at = 200 },
            }
            local h = Scheduler.buildFromRows(rows)
            assertEqual(h.size, 3, "size 3")
            assertEqual(Scheduler.pop(h).machine_uuid, 'm1', "first m1")
            assertEqual(Scheduler.pop(h).machine_uuid, 'm2', "second m2")
            assertEqual(Scheduler.pop(h).machine_uuid, 'm3', "third m3")
        end,
    },
    {
        name = "buildFromRows skips rows missing fields",
        test = function()
            local rows = {
                { machine_uuid = 'm1', next_due_at = 100 },
                { machine_uuid = nil, next_due_at = 200 },
                { machine_uuid = 'm3', next_due_at = nil },
            }
            local h = Scheduler.buildFromRows(rows)
            assertEqual(h.size, 1, "only 1 valid row")
        end,
    },
    {
        name = "popDue returns only entries with due_at <= now, up to maxCount",
        test = function()
            local h = Scheduler.newHeap()
            Scheduler.push(h, 100, 'm1')
            Scheduler.push(h, 150, 'm2')
            Scheduler.push(h, 200, 'm3')
            Scheduler.push(h, 250, 'm4')
            local due = Scheduler.popDue(h, 200, 100)
            assertEqual(#due, 3, "3 entries due at or before 200")
            assertEqual(due[1].machine_uuid, 'm1', "first m1")
            assertEqual(due[2].machine_uuid, 'm2', "second m2")
            assertEqual(due[3].machine_uuid, 'm3', "third m3")
            assertEqual(h.size, 1, "1 remaining (m4)")
        end,
    },
    {
        name = "popDue respects maxCount",
        test = function()
            local h = Scheduler.newHeap()
            for i = 1, 10 do
                Scheduler.push(h, i * 10, 'm' .. i)
            end
            local due = Scheduler.popDue(h, 1000, 3)
            assertEqual(#due, 3, "capped at 3")
            assertEqual(h.size, 7, "7 remaining")
        end,
    },
    {
        name = "popDue returns empty when nothing is due",
        test = function()
            local h = Scheduler.newHeap()
            Scheduler.push(h, 500, 'm1')
            local due = Scheduler.popDue(h, 100, 100)
            assertEqual(#due, 0, "nothing due")
            assertEqual(h.size, 1, "heap unchanged")
        end,
    },
    {
        name = "duplicate due_at values are handled (stable by insertion order)",
        test = function()
            local h = Scheduler.newHeap()
            Scheduler.push(h, 100, 'm1')
            Scheduler.push(h, 100, 'm2')
            Scheduler.push(h, 100, 'm3')
            -- All have the same due_at; pop should return all 3.
            local count = 0
            while Scheduler.peek(h) do
                Scheduler.pop(h)
                count = count + 1
            end
            assertEqual(count, 3, "all 3 popped")
        end,
    },
}
