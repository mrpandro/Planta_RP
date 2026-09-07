-- qb-czcraft audit repository
-- czcraft_audit_events append-only journal. Independent of mutable rows so
-- audit history survives machine/bill deletion.

CZCraft = CZCraft or {}

local AuditRepo = {}

-- Appends an audit event.
-- @param fields table {
--   actor_type, actor_id, owner_type, owner_id, machine_uuid,
--   storage_type, storage_id, bill_id, action, previous_state, next_state,
--   deltas, reason,
-- }
function AuditRepo.append(fields)
    MySQL.prepare.await([[
        INSERT INTO `czcraft_audit_events`
            (`actor_type`, `actor_id`, `owner_type`, `owner_id`, `machine_uuid`,
             `storage_type`, `storage_id`, `bill_id`, `action`,
             `previous_state`, `next_state`, `deltas`, `reason`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        fields.actor_type, fields.actor_id,
        fields.owner_type, fields.owner_id, fields.machine_uuid,
        fields.storage_type, fields.storage_id, fields.bill_id, fields.action,
        fields.previous_state and json.encode(fields.previous_state) or nil,
        fields.next_state and json.encode(fields.next_state) or nil,
        fields.deltas and json.encode(fields.deltas) or nil,
        fields.reason,
    })
end

CZCraft.AuditRepo = AuditRepo
return AuditRepo
