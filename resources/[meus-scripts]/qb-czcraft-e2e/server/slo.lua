-- qb-czcraft-e2e SLO measurement utilities
-- Timing, percentile, and Lua-stall detection helpers shared by all scenarios.
-- All measurements are in milliseconds. Raw numbers are printed, not summarized.

CZE2E = CZE2E or {}

local Slo = {}

-- High-resolution monotonic timer in milliseconds. Uses GetGameTimer (ms,
-- monotonic since server start) on FiveM; falls back to os.clock in tests.
local function nowMs()
    if GetGameTimer then return GetGameTimer() end
    return math.floor((os.clock() * 1000))
end
Slo.nowMs = nowMs

-- Records a sample and returns a latency recorder.
-- Usage: local r = Slo.recorder(); r.add(ms); r.report("label")
function Slo.recorder()
    local samples = {}
    return {
        add = function(ms)
            samples[#samples + 1] = tonumber(ms) or 0
        end,
        count = function() return #samples end,
        -- Returns p50/p95/p99/max/mean as raw numbers.
        stats = function()
            if #samples == 0 then
                return { count = 0, p50 = 0, p95 = 0, p99 = 0, max = 0, mean = 0 }
            end
            local sorted = {}
            for i, v in ipairs(samples) do sorted[i] = v end
            table.sort(sorted)
            local function pct(p)
                local idx = math.max(1, math.ceil(#sorted * p / 100))
                return sorted[idx]
            end
            local sum = 0
            for _, v in ipairs(sorted) do sum = sum + v end
            return {
                count = #sorted,
                p50 = pct(50),
                p95 = pct(95),
                p99 = pct(99),
                max = sorted[#sorted],
                mean = sum / #sorted,
            }
        end,
        -- Prints raw stats with a label. Does NOT summarize pass/fail — the
        -- caller compares against the SLO threshold and prints the verdict.
        report = function(label)
            Slo.printStats(label, samples and (function()
                if #samples == 0 then
                    return { count = 0, p50 = 0, p95 = 0, p99 = 0, max = 0, mean = 0 }
                end
                local sorted = {}
                for i, v in ipairs(samples) do sorted[i] = v end
                table.sort(sorted)
                local function pct(p)
                    local idx = math.max(1, math.ceil(#sorted * p / 100))
                    return sorted[idx]
                end
                local sum = 0
                for _, v in ipairs(sorted) do sum = sum + v end
                return {
                    count = #sorted, p50 = pct(50), p95 = pct(95),
                    p99 = pct(99), max = sorted[#sorted], mean = sum / #sorted,
                }
            end)())
        end,
    }
end

-- Prints a stats table as raw numbers.
-- @param label string
-- @param stats table from recorder.stats()
function Slo.printStats(label, stats)
    print(('[E2E][SLO] %s: count=%d p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms mean=%.2fms'):format(
        label, stats.count, stats.p50, stats.p95, stats.p99, stats.max, stats.mean
    ))
end

-- SLO thresholds (from the v0.1 gate criteria).
Slo.THRESHOLDS = {
    dbP95Ms = 200,
    actionP95Ms = 300,
    recoverySec = 60,
    luaStallMs = 50,
}

-- Compares a stats table against a threshold and prints a PASS/FAIL verdict.
-- @param label string
-- @param stats table
-- @param thresholdMs number
-- @return boolean passed
function Slo.assertP95(label, stats, thresholdMs)
    local passed = stats.p95 <= thresholdMs
    print(('[E2E][SLO] %s: p95=%.2fms %s %dms -> %s'):format(
        label, stats.p95, passed and '<=' or '>', thresholdMs, passed and 'PASS' or 'FAIL'
    ))
    return passed
end

-- Lua stall detector: wraps a function and measures the wall-clock time it
-- takes. If the duration exceeds the stall threshold, records it. Returns the
-- recorder of stall durations so the caller can report p95/max.
-- @param thresholdMs number (default 50)
function Slo.stallDetector(thresholdMs)
    local stalls = Slo.recorder()
    local threshold = thresholdMs or Slo.THRESHOLDS.luaStallMs
    return {
        -- Wraps a synchronous fn and records its duration if it stalls.
        measure = function(fn)
            local start = nowMs()
            local result = fn()
            local duration = nowMs() - start
            if duration > threshold then
                stalls.add(duration)
            end
            return result
        end,
        stats = function() return stalls.stats() end,
        threshold = threshold,
    }
end

-- Times a single async (MySQL.await) operation and returns the duration in ms.
-- Usage: local ms, result = Slo.timeAwait(function() return MySQL.query.await(...) end)
function Slo.timeAwait(fn)
    local start = nowMs()
    local result = fn()
    return nowMs() - start, result
end

CZE2E.Slo = Slo
return Slo
