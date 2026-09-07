-- qb-czcraft qb-inventory adapter
-- Wraps the ApplyIdempotentBatch export for machine-item add/remove during
-- placement commit and pickup. The export is restricted by GetInvokingResource
-- to qb-czcraft (Config.CzCraftAllowedResources in qb-inventory).

CZCraft = CZCraft or {}

local QbInventoryAdapter = {}

-- Applies a batch of removals/additions idempotently.
-- @param source number player server id
-- @param mutationId string unique idempotency key
-- @param removals table array of { item, amount, slot?, metadata? }
-- @param additions table array of { item, amount, slot?, info? }
-- @param reason string optional
-- @return table { success, replayed?, errors?, reason?, securityIncident? }
function QbInventoryAdapter.applyBatch(source, mutationId, removals, additions, reason)
    return exports['qb-inventory']:ApplyIdempotentBatch(source, mutationId, removals, additions, reason)
end

-- Convenience: removes a single unique machine item (placement commit).
-- @param source number
-- @param mutationId string
-- @param itemName string e.g. 'cz_workbench_machine'
-- @param slot number the item slot to remove from
-- @param reason string
-- @return table result
function QbInventoryAdapter.removeMachineItem(source, mutationId, itemName, slot, reason)
    return QbInventoryAdapter.applyBatch(source, mutationId, {
        { item = itemName, amount = 1, slot = slot },
    }, {}, reason)
end

-- Convenience: adds a single unique machine item with serial/condition info
-- (pickup returns the item).
-- @param source number
-- @param mutationId string
-- @param itemName string
-- @param info table { serial, condition, ... }
-- @param reason string
-- @return table result
function QbInventoryAdapter.addMachineItem(source, mutationId, itemName, info, reason)
    return QbInventoryAdapter.applyBatch(source, mutationId, {}, {
        { item = itemName, amount = 1, info = info },
    }, reason)
end

CZCraft.QbInventoryAdapter = QbInventoryAdapter
return QbInventoryAdapter
