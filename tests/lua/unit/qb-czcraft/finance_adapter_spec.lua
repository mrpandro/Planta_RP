-- Tests for the FinanceAdapter idempotent money movement saga.
-- Mocks FinanceRepo (DB journal) and the qb-core/qb-banking exports to
-- verify the PENDING/COMMITTED flow, replay handling, and failure paths.

-- ---------------------------------------------------------------------------
-- Mock state
-- ---------------------------------------------------------------------------
local repoState = {}
local qbCoreState = {}
local qbBankingState = {}

local function resetState()
    repoState = {
        beginResults = {},   -- queue of { isFresh, existing } for beginExport
        committed = {},       -- export_ids that were marked COMMITTED
    }
    qbCoreState = {
        player = nil,         -- { money = { cash = N, bank = N }, saveCalls = 0, addCalls = {}, removeCalls = {} }
    }
    qbBankingState = {
        accounts = {},        -- { [accountId] = balance }
        addCalls = {},
        removeCalls = {},
    }
end

-- ---------------------------------------------------------------------------
-- Mock FinanceRepo
-- ---------------------------------------------------------------------------
CZCraft = CZCraft or {}
CZCraft.FinanceRepo = {
    beginExport = function(params)
        if #repoState.beginResults > 0 then
            local r = table.remove(repoState.beginResults, 1)
            return true, r.isFresh, r.existing
        end
        return true, true, nil
    end,
    markCommitted = function(exportId, resultJson)
        repoState.committed[#repoState.committed + 1] = { export_id = exportId, result = resultJson }
        return true
    end,
}

-- ---------------------------------------------------------------------------
-- Mock qb-core exports
-- ---------------------------------------------------------------------------
local function makeMockPlayer(money)
    return {
        PlayerData = { money = money or { cash = 1000, bank = 5000 } },
        addCalls = {},
        removeCalls = {},
        saveCalls = 0,
        Functions = {
            AddMoney = function(account, amount, reason)
                qbCoreState.player.addCalls[#qbCoreState.player.addCalls + 1] = { account = account, amount = amount }
                qbCoreState.player.PlayerData.money[account] = (qbCoreState.player.PlayerData.money[account] or 0) + amount
            end,
            RemoveMoney = function(account, amount, reason)
                qbCoreState.player.removeCalls[#qbCoreState.player.removeCalls + 1] = { account = account, amount = amount }
                qbCoreState.player.PlayerData.money[account] = (qbCoreState.player.PlayerData.money[account] or 0) - amount
            end,
            Save = function()
                qbCoreState.player.saveCalls = qbCoreState.player.saveCalls + 1
            end,
        },
    }
end

exports = setmetatable({}, {
    __index = function(_, name)
        if name == 'qb-core' then
            return {
                GetPlayer = function(source)
                    return qbCoreState.player
                end,
            }
        elseif name == 'qb-banking' then
            return {
                AddAccountMoney = function(accountId, amount)
                    qbBankingState.addCalls[#qbBankingState.addCalls + 1] = { account = accountId, amount = amount }
                    qbBankingState.accounts[accountId] = (qbBankingState.accounts[accountId] or 0) + amount
                    return true
                end,
                RemoveAccountMoney = function(accountId, amount)
                    local balance = qbBankingState.accounts[accountId] or 0
                    if balance < amount then return false end
                    qbBankingState.removeCalls[#qbBankingState.removeCalls + 1] = { account = accountId, amount = amount }
                    qbBankingState.accounts[accountId] = balance - amount
                    return true
                end,
            }
        end
        return nil
    end,
})

-- Stub FiveM globals
json = json or {
    encode = function(t)
        if type(t) ~= 'table' then return 'null' end
        local parts = {}
        for k, v in pairs(t) do
            parts[#parts + 1] = '"' .. tostring(k) .. '":' .. tostring(v)
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end,
    decode = function(s) return {} end,
}
os = os or {}
os.time = os.time or function() return 1000000 end

-- Load constants for the FinancialDirection/SourceType enums.
dofile("resources/[meus-scripts]/qb-czcraft/shared/constants.lua")

-- Load the adapter under test.
local FinanceAdapter = dofile("resources/[meus-scripts]/qb-czcraft/server/adapters/finance.lua")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "Assertion failed") .. " | expected=" .. tostring(expected) .. ", actual=" .. tostring(actual))
    end
end

local function assertTrue(value, message)
    if not value then error(message or "Expected truthy") end
end
local function assertFalse(value, message)
    if value then error(message or "Expected falsy") end
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------
local tests = {}

tests[#tests + 1] = {
    name = "fresh DEBIT from qb-core bank removes money and saves",
    test = function()
        resetState()
        qbCoreState.player = makeMockPlayer({ cash = 1000, bank = 5000 })

        local result = FinanceAdapter.applyMovement({
            export_key = "purchase:machine-1",
            source_type = CZCraft.FinancialSourceType.QB_CORE,
            source_id = 1,
            direction = CZCraft.FinancialDirection.DEBIT,
            amount = 500,
            account = 'bank',
            reason = 'machine purchase',
        })

        assertTrue(result.success, "should succeed")
        assertFalse(result.replayed, "should not be a replay")
        assertEqual(#qbCoreState.player.removeCalls, 1, "one RemoveMoney call")
        assertEqual(qbCoreState.player.removeCalls[1].amount, 500, "removed 500")
        assertEqual(qbCoreState.player.removeCalls[1].account, 'bank', "from bank")
        assertEqual(qbCoreState.player.saveCalls, 1, "Save called once for durability")
        assertEqual(qbCoreState.player.PlayerData.money.bank, 4500, "balance reduced to 4500")
        assertEqual(#repoState.committed, 1, "export marked COMMITTED")
    end,
}

tests[#tests + 1] = {
    name = "fresh CREDIT to qb-core cash adds money and saves",
    test = function()
        resetState()
        qbCoreState.player = makeMockPlayer({ cash = 100, bank = 0 })

        local result = FinanceAdapter.applyMovement({
            export_key = "sale:machine-1:steel",
            source_type = CZCraft.FinancialSourceType.QB_CORE,
            source_id = 1,
            direction = CZCraft.FinancialDirection.CREDIT,
            amount = 250,
            account = 'cash',
            reason = 'item sale',
        })

        assertTrue(result.success, "should succeed")
        assertEqual(#qbCoreState.player.addCalls, 1, "one AddMoney call")
        assertEqual(qbCoreState.player.addCalls[1].amount, 250, "added 250")
        assertEqual(qbCoreState.player.addCalls[1].account, 'cash', "to cash")
        assertEqual(qbCoreState.player.saveCalls, 1, "Save called once")
        assertEqual(qbCoreState.player.PlayerData.money.cash, 350, "balance increased to 350")
    end,
}

tests[#tests + 1] = {
    name = "replay with COMMITTED status returns cached result without re-applying",
    test = function()
        resetState()
        qbCoreState.player = makeMockPlayer({ cash = 1000, bank = 5000 })
        repoState.beginResults = {
            { isFresh = false, existing = { export_id = "old-id", status = 'COMMITTED', result = '{"success":true}' } },
        }

        local result = FinanceAdapter.applyMovement({
            export_key = "purchase:machine-1",
            source_type = CZCraft.FinancialSourceType.QB_CORE,
            source_id = 1,
            direction = CZCraft.FinancialDirection.DEBIT,
            amount = 500,
            account = 'bank',
            reason = 'machine purchase',
        })

        assertTrue(result.success, "should succeed (cached)")
        assertTrue(result.replayed, "should signal replay")
        assertEqual(#qbCoreState.player.removeCalls, 0, "NO RemoveMoney on replay")
        assertEqual(qbCoreState.player.saveCalls, 0, "NO Save on replay")
        assertEqual(#repoState.committed, 0, "NO new COMMITTED on replay")
    end,
}

tests[#tests + 1] = {
    name = "replay with PENDING status re-applies the movement",
    test = function()
        resetState()
        qbCoreState.player = makeMockPlayer({ cash = 1000, bank = 5000 })
        repoState.beginResults = {
            { isFresh = false, existing = { export_id = "pending-id", status = 'PENDING', result = nil } },
        }

        local result = FinanceAdapter.applyMovement({
            export_key = "purchase:machine-1",
            source_type = CZCraft.FinancialSourceType.QB_CORE,
            source_id = 1,
            direction = CZCraft.FinancialDirection.DEBIT,
            amount = 500,
            account = 'bank',
            reason = 'machine purchase',
        })

        assertTrue(result.success, "should succeed (re-applied)")
        assertFalse(result.replayed, "PENDING re-apply is not a replay")
        assertEqual(#qbCoreState.player.removeCalls, 1, "RemoveMoney re-applied")
        assertEqual(qbCoreState.player.saveCalls, 1, "Save re-applied")
        assertEqual(#repoState.committed, 1, "marked COMMITTED after re-apply")
    end,
}

tests[#tests + 1] = {
    name = "insufficient balance returns failure and marks COMMITTED with error",
    test = function()
        resetState()
        qbCoreState.player = makeMockPlayer({ cash = 100, bank = 100 })

        local result = FinanceAdapter.applyMovement({
            export_key = "purchase:expensive",
            source_type = CZCraft.FinancialSourceType.QB_CORE,
            source_id = 1,
            direction = CZCraft.FinancialDirection.DEBIT,
            amount = 500,
            account = 'bank',
            reason = 'machine purchase',
        })

        assertFalse(result.success, "should fail")
        assertTrue(result.reason and string.find(result.reason, 'insufficient'),
            "reason should mention insufficient balance")
        assertEqual(#qbCoreState.player.removeCalls, 0, "NO RemoveMoney on insufficient balance")
        assertEqual(#repoState.committed, 1, "export marked COMMITTED with failure result")
    end,
}

tests[#tests + 1] = {
    name = "zero amount is a no-op success without touching the journal",
    test = function()
        resetState()
        qbCoreState.player = makeMockPlayer({ cash = 1000, bank = 5000 })

        local result = FinanceAdapter.applyMovement({
            export_key = "zero-op",
            source_type = CZCraft.FinancialSourceType.QB_CORE,
            source_id = 1,
            direction = CZCraft.FinancialDirection.CREDIT,
            amount = 0,
            account = 'cash',
            reason = 'zero',
        })

        assertTrue(result.success, "should succeed")
        assertFalse(result.replayed, "not a replay")
        assertEqual(#qbCoreState.player.addCalls, 0, "NO AddMoney for zero amount")
        assertEqual(#repoState.committed, 0, "NO journal entry for zero amount")
    end,
}

tests[#tests + 1] = {
    name = "qb-banking CREDIT adds to the bank account",
    test = function()
        resetState()
        qbBankingState.accounts = { ['gang-1'] = 10000 }

        local result = FinanceAdapter.applyMovement({
            export_key = "sale:gang-1:parts",
            source_type = CZCraft.FinancialSourceType.QB_BANKING,
            source_id = 'gang-1',
            direction = CZCraft.FinancialDirection.CREDIT,
            amount = 500,
            account = 'bank',
            reason = 'gang sale',
        })

        assertTrue(result.success, "should succeed")
        assertEqual(#qbBankingState.addCalls, 1, "one AddAccountMoney call")
        assertEqual(qbBankingState.accounts['gang-1'], 10500, "account balance increased")
    end,
}

tests[#tests + 1] = {
    name = "qb-banking DEBIT with insufficient balance fails",
    test = function()
        resetState()
        qbBankingState.accounts = { ['gang-1'] = 100 }

        local result = FinanceAdapter.applyMovement({
            export_key = "purchase:gang-1",
            source_type = CZCraft.FinancialSourceType.QB_BANKING,
            source_id = 'gang-1',
            direction = CZCraft.FinancialDirection.DEBIT,
            amount = 500,
            account = 'bank',
            reason = 'gang purchase',
        })

        assertFalse(result.success, "should fail")
        assertEqual(#qbBankingState.removeCalls, 0, "NO RemoveAccountMoney on insufficient")
        assertEqual(qbBankingState.accounts['gang-1'], 100, "balance unchanged")
    end,
}

tests[#tests + 1] = {
    name = "invalid params rejected before any DB or money call",
    test = function()
        resetState()

        local r1 = FinanceAdapter.applyMovement(nil)
        assertFalse(r1.success, "nil params rejected")

        local r2 = FinanceAdapter.applyMovement({ source_type = 'qb-core', direction = 'DEBIT', amount = 10 })
        assertFalse(r2.success, "missing export_key rejected")

        local r3 = FinanceAdapter.applyMovement({
            export_key = "x", source_type = 'invalid', direction = 'DEBIT', amount = 10,
        })
        assertFalse(r3.success, "invalid source_type rejected")

        local r4 = FinanceAdapter.applyMovement({
            export_key = "x", source_type = 'qb-core', direction = 'SIDEWAYS', amount = 10,
        })
        assertFalse(r4.success, "invalid direction rejected")

        local r5 = FinanceAdapter.applyMovement({
            export_key = "x", source_type = 'qb-core', direction = 'DEBIT', amount = -5,
        })
        assertFalse(r5.success, "negative amount rejected")
    end,
}

return tests
