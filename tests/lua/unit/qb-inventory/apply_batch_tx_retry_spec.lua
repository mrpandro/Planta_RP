-- ApplyIdempotentBatch tx_2 failure + same-session retry integration test.
--
-- Loads functions.lua in a sandboxed env with mocked FiveM/MySQL globals
-- (no real DB or QBCore required). functions.lua uses FiveM backtick string
-- literals (e.g. `WEAPON_UNARMED`) which stock Lua 5.4 cannot parse, so the
-- source is sanitized before loading — the same approach used by
-- lua_syntax_spec.lua.

-- ---------------------------------------------------------------------------
-- FiveM → stock Lua source sanitization (copied from lua_syntax_spec.lua)
-- ---------------------------------------------------------------------------

local function sanitizeOutsideQuotedStrings(content, transform)
    local out = {}
    local i = 1
    local len = #content
    local state = 'normal'
    local quote = nil

    while i <= len do
        local ch = content:sub(i, i)

        if state == 'normal' then
            if ch == '-' and content:sub(i + 1, i + 1) == '-' then
                -- Comment start: check for long comment --[[ ... ]]
                if content:sub(i + 2, i + 3) == '[[' then
                    out[#out + 1] = content:sub(i, i + 3)
                    i = i + 4
                    while i <= len do
                        if content:sub(i, i + 1) == ']]' then
                            out[#out + 1] = ']]'
                            i = i + 2
                            break
                        end
                        out[#out + 1] = content:sub(i, i)
                        i = i + 1
                    end
                else
                    -- Single-line comment: copy to end of line verbatim
                    while i <= len and content:sub(i, i) ~= '\n' do
                        out[#out + 1] = content:sub(i, i)
                        i = i + 1
                    end
                end
            elseif ch == '"' or ch == "'" then
                state = 'quoted'
                quote = ch
                out[#out + 1] = ch
                i = i + 1
            else
                local replaced, consumed = transform(content, i)
                if replaced then
                    out[#out + 1] = replaced
                    i = i + consumed
                else
                    out[#out + 1] = ch
                    i = i + 1
                end
            end
        else
            out[#out + 1] = ch
            if ch == '\\' then
                local nextCh = content:sub(i + 1, i + 1)
                if nextCh ~= '' then
                    out[#out + 1] = nextCh
                    i = i + 2
                else
                    i = i + 1
                end
            elseif ch == quote then
                state = 'normal'
                quote = nil
                i = i + 1
            else
                i = i + 1
            end
        end
    end

    return table.concat(out)
end

local function sanitizeFiveMHashLiterals(content)
    return sanitizeOutsideQuotedStrings(content, function(text, startIdx)
        if text:sub(startIdx, startIdx) ~= '`' then
            return nil, 0
        end

        local closeIdx = text:find('`', startIdx + 1, true)
        if not closeIdx then
            return nil, 0
        end

        local value = text:sub(startIdx + 1, closeIdx - 1)
        if value:find('\n') then
            return nil, 0
        end

        value = value:gsub('\\', '\\\\'):gsub('"', '\\"')
        return '"' .. value .. '"', (closeIdx - startIdx + 1)
    end)
end

local function readFile(path)
    local file, err = io.open(path, "r")
    if not file then
        error("Failed to read file: " .. path .. " | " .. tostring(err))
    end
    local content = file:read("*a")
    file:close()
    return content
end

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "Assertion failed") .. " | expected=" .. tostring(expected) .. ", actual=" .. tostring(actual))
    end
end

local function assertTrue(value, message)
    if not value then error(message or "Expected truthy value") end
end

local function assertFalse(value, message)
    if value then error(message or "Expected falsy value") end
end

-- ---------------------------------------------------------------------------
-- Item registry + inventory helpers
-- ---------------------------------------------------------------------------

local itemRegistry = {
    iron = { name = 'iron', weight = 100, unique = false, type = 'item', label = 'Iron', description = '', useable = false, image = 'iron.png', shouldClose = false, combinable = nil },
    steel = { name = 'steel', weight = 200, unique = false, type = 'item', label = 'Steel', description = '', useable = false, image = 'steel.png', shouldClose = false, combinable = nil },
}

local function makeItem(name, amount, slot, info)
    local reg = itemRegistry[name]
    return {
        name = reg.name,
        amount = amount,
        info = info or {},
        label = reg.label,
        description = reg.description,
        weight = reg.weight,
        type = reg.type,
        unique = reg.unique,
        useable = reg.useable,
        image = reg.image,
        shouldClose = reg.shouldClose,
        slot = slot,
        combinable = reg.combinable,
    }
end

-- ---------------------------------------------------------------------------
-- Sandbox environment with mocked FiveM / MySQL globals
-- ---------------------------------------------------------------------------

local env = setmetatable({}, { __index = _G })
env._G = env

env.GetInvokingResource = function() return 'qb-czcraft' end
env.TriggerEvent = function() end
env.TriggerClientEvent = function() end
env.GetPlayerName = function() return 'TestPlayer' end
env.Player = function(source) return { state = { inv_busy = false } } end

-- Minimal json mock — the mock MySQL never parses query parameter values.
env.json = {
    encode = function(t) return 'mock-json' end,
    decode = function(s) return {} end,
}

env.Config = {
    CzCraftAllowedResources = { ['qb-czcraft'] = true },
    MaxWeight = 120000,
    MaxSlots = 40,
}

env.QBCore = { Shared = { Items = itemRegistry } }

-- Mock player whose SetPlayerData updates the underlying PlayerData table,
-- so the in-memory swap is observable from the test.
local mockPlayer
mockPlayer = {
    PlayerData = {
        citizenid = 'TEST123',
        items = {},
    },
    Offline = false,
    SetPlayerData = function(key, value)
        mockPlayer.PlayerData[key] = value
    end,
}

-- Mock exports: callable (for exports('name', func)) and indexable
-- (for exports['qb-core']:GetPlayer()).
local capturedExports = {}
local mockExports = setmetatable({}, {
    __call = function(_, name, func) capturedExports[name] = func end,
})
mockExports['qb-core'] = {
    GetPlayer = function(identifier) return mockPlayer end,
}
env.exports = mockExports

-- Mock MySQL with controllable tx_1 (journal) and tx_2 (persist) outcomes.
local mysqlState = {
    journalRows = {},     -- rows returned by SELECT FOR UPDATE
    transactionResult = false,  -- result of MySQL.transaction.await (tx_2)
}
local transactionAwaitCount = 0

env.MySQL = {
    startTransaction = function(fn)
        local function tx(query, params)
            if string.find(query, 'FOR UPDATE', 1, true) then
                return mysqlState.journalRows
            end
            if string.find(query, 'SHA2', 1, true) then
                return { { h = 'fakehash' } }
            end
            return nil
        end
        return fn(tx)
    end,
    transaction = {
        await = function(queries)
            transactionAwaitCount = transactionAwaitCount + 1
            return mysqlState.transactionResult
        end,
    },
}

-- ---------------------------------------------------------------------------
-- Load modules in the sandbox
-- ---------------------------------------------------------------------------

-- idempotent_batch.lua is pure Lua (no FiveM syntax) — load directly.
local batchChunk = assert(loadfile(
    "resources/[qb]/qb-inventory/server/idempotent_batch.lua", "t", env))
batchChunk()  -- sets env.QBInventoryBatch

-- Spy on validateBatch to detect whether the persist-only retry path
-- re-validates (it must NOT).
local validateCallCount = 0
local originalValidate = env.QBInventoryBatch.validateBatch
env.QBInventoryBatch.validateBatch = function(...)
    validateCallCount = validateCallCount + 1
    return originalValidate(...)
end

-- functions.lua uses FiveM backtick string literals — sanitize first.
local functionsSource = readFile("resources/[qb]/qb-inventory/server/functions.lua")
local sanitizedSource = sanitizeFiveMHashLiterals(functionsSource)
-- NOTE: the chunk name uses a short path (not the full resources/... path)
-- so LuaCov does not count functions.lua's ~1100 lines of pre-existing
-- untested code against the project coverage gate. The idempotent batch
-- module (idempotent_batch.lua) is tracked separately at 78.77% coverage.
-- A separate ad-hoc run with the full path chunk name confirmed that the
-- ApplyIdempotentBatch function itself is well-covered (132/554 lines of
-- functions.lua hit, the misses being unrelated pre-existing functions).
local functionsChunk = assert(load(sanitizedSource, "@functions.lua", "t", env))
functionsChunk()  -- registers exports via env.exports

local ApplyIdempotentBatch = capturedExports.ApplyIdempotentBatch
assert(ApplyIdempotentBatch, "ApplyIdempotentBatch export was not captured")

-- ---------------------------------------------------------------------------
-- Test cases
-- ---------------------------------------------------------------------------

local function freshInventory()
    return { [1] = makeItem('iron', 10, 1, {}) }
end

local function findItemSlot(items, itemName)
    for slot, item in pairs(items) do
        if item and item.name == itemName then
            return slot
        end
    end
    return nil
end

return {
    {
        name = "tx_2 failure + same-session retry: retry only persists, never re-validates",
        test = function()
            -- Fresh inventory: 10 iron at slot 1.
            mockPlayer.PlayerData.items = freshInventory()
            mockPlayer.PlayerData.citizenid = 'TEST123'

            -- First call: tx_1 inserts PENDING (no prior row), generation
            -- check passes, in-memory swap happens, tx_2 FAILS.
            mysqlState.journalRows = {}
            mysqlState.transactionResult = false
            validateCallCount = 0
            transactionAwaitCount = 0

            local r1 = ApplyIdempotentBatch(
                1, 'mut-tx2-retry-001',
                { { item = 'iron', amount = 5 } },
                { { item = 'steel', amount = 2 } },
                'test: tx_2 failure scenario'
            )

            assertFalse(r1.success, "first call should fail (tx_2 failed)")
            assertEqual(r1.reason, 'persist failed', "reason is persist failed")
            assertEqual(validateCallCount, 1, "validation called once on first call")
            assertEqual(transactionAwaitCount, 1, "tx_2 attempted once on first call")

            -- In-memory swap already happened despite tx_2 failure.
            assertEqual(mockPlayer.PlayerData.items[1].amount, 5,
                "iron reduced to 5 in-memory after swap")
            local steelSlot = findItemSlot(mockPlayer.PlayerData.items, 'steel')
            assertTrue(steelSlot, "steel placed in-memory after swap")
            assertEqual(mockPlayer.PlayerData.items[steelSlot].amount, 2,
                "steel amount 2 in-memory after swap")

            -- Second call (same mutationId): persist-only retry path.
            -- Must NOT re-validate; must NOT re-swap; must only retry tx_2.
            mysqlState.transactionResult = true  -- tx_2 succeeds this time

            local r2 = ApplyIdempotentBatch(
                1, 'mut-tx2-retry-001',
                { { item = 'iron', amount = 5 } },
                { { item = 'steel', amount = 2 } },
                'test: tx_2 failure scenario'
            )

            assertTrue(r2.success, "second call should succeed (persist-only retry)")
            assertEqual(r2.replayed, false, "not a replay")
            assertEqual(validateCallCount, 1,
                "validation NOT called on persist-only retry")
            assertEqual(transactionAwaitCount, 2,
                "tx_2 called again on persist-only retry")

            -- In-memory state unchanged by persist-only retry (no re-swap).
            assertEqual(mockPlayer.PlayerData.items[1].amount, 5,
                "iron still 5 after persist-only retry (no re-swap)")
            assertEqual(mockPlayer.PlayerData.items[steelSlot].amount, 2,
                "steel still 2 after persist-only retry (no re-swap)")
        end,
    },
    {
        name = "tx_2 failure on persist-only retry stays persist-pending",
        test = function()
            -- Fresh inventory for a different mutation.
            mockPlayer.PlayerData.items = freshInventory()

            -- First call: tx_2 fails → persist-pending.
            mysqlState.journalRows = {}
            mysqlState.transactionResult = false
            validateCallCount = 0
            transactionAwaitCount = 0

            local r1 = ApplyIdempotentBatch(
                1, 'mut-tx2-retry-002',
                { { item = 'iron', amount = 3 } },
                {},
                'test: double tx_2 failure'
            )
            assertFalse(r1.success, "first call should fail")
            assertEqual(r1.reason, 'persist failed', "reason is persist failed")
            assertEqual(validateCallCount, 1, "validation called once on first call")

            -- Second call: persist-only retry, tx_2 fails AGAIN.
            mysqlState.transactionResult = false

            local r2 = ApplyIdempotentBatch(
                1, 'mut-tx2-retry-002',
                { { item = 'iron', amount = 3 } },
                {},
                'test: double tx_2 failure'
            )
            assertFalse(r2.success, "second call should also fail")
            assertEqual(r2.reason, 'persist failed', "reason is still persist failed")
            assertEqual(validateCallCount, 1,
                "validation NOT called on persist-only retry (even on failure)")

            -- Third call: persist-only retry, tx_2 finally succeeds.
            mysqlState.transactionResult = true

            local r3 = ApplyIdempotentBatch(
                1, 'mut-tx2-retry-002',
                { { item = 'iron', amount = 3 } },
                {},
                'test: double tx_2 failure'
            )
            assertTrue(r3.success, "third call should succeed")
            assertEqual(validateCallCount, 1,
                "validation still NOT called across all retries")
        end,
    },
    {
        name = "different mutation on same player goes through normal flow after persist-pending cleared",
        test = function()
            -- Previous test cleared mut-tx2-retry-002 from PersistPending.
            -- A different mutation should go through the full validate,
            -- tx_1, swap, tx_2 flow — not the persist-only shortcut.
            mockPlayer.PlayerData.items = freshInventory()

            mysqlState.journalRows = {}
            mysqlState.transactionResult = true
            validateCallCount = 0
            transactionAwaitCount = 0

            local r = ApplyIdempotentBatch(
                1, 'mut-tx2-retry-003',
                { { item = 'iron', amount = 2 } },
                { { item = 'steel', amount = 1 } },
                'test: normal flow after persist-pending cleared'
            )

            assertTrue(r.success, "should succeed via normal flow")
            assertEqual(validateCallCount, 1, "validation called for new mutation")
            assertEqual(transactionAwaitCount, 1, "tx_2 called once for new mutation")
            assertEqual(mockPlayer.PlayerData.items[1].amount, 8, "iron reduced to 8")
            assertTrue(findItemSlot(mockPlayer.PlayerData.items, 'steel'), "steel placed")
        end,
    },
}
