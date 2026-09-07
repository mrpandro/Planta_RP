-- qb-czcraft operations journal repository
-- czcraft_operations + czcraft_operation_steps. Idempotent saga tracking for
-- placement/pickup (and later deposit/withdraw). Each operation has a unique
-- operation_key; steps record idempotent stage outcomes.

CZCraft = CZCraft or {}

local OperationsRepo = {}

local function generateUuid()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or (math.random(8, 0xb))
        return string.format('%x', v)
    end)
end

-- Creates an operation row if the operation_key is not already present.
-- Returns the operation_id and whether this is a fresh start (true) or a
-- replay of an existing operation (false).
-- @param operationKey string unique idempotency key (caller-supplied)
-- @param actor table { type, id }
-- @param owner table|nil { type, id }
-- @param machineUuid string|nil
-- @param opType string e.g. 'PLACEMENT', 'PICKUP'
-- @param payloadHash string SHA-256 hex of the payload
-- @return string operationId
-- @return boolean isFresh
-- @return string|nil error
function OperationsRepo.begin(operationKey, actor, owner, machineUuid, opType, payloadHash)
    local existing = MySQL.single.await(
        'SELECT `operation_id`, `status` FROM `czcraft_operations` WHERE `operation_key` = ?',
        { operationKey }
    )
    if existing then
        return existing.operation_id, false
    end
    local opId = generateUuid()
    MySQL.insert.await([[
        INSERT INTO `czcraft_operations`
            (`operation_id`, `operation_key`, `actor_type`, `actor_id`,
             `owner_type`, `owner_id`, `machine_uuid`, `type`, `stage`,
             `payload_hash`, `status`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'PENDING', ?, 'PENDING')
    ]], {
        opId, operationKey, actor.type, actor.id,
        owner and owner.type, owner and owner.id, machineUuid, opType, payloadHash,
    })
    return opId, true
end

-- Marks a step's status idempotently. Re-marking an already-completed step is
-- a no-op (idempotent).
-- @param operationId string
-- @param stepName string e.g. 'INVENTORY_APPLIED', 'DOMAIN_COMMITTED'
-- @param status string 'PENDING'|'COMPLETED'|'FAILED'
-- @param result table|nil JSON-serializable result
function OperationsRepo.markStep(operationId, stepName, status, result)
    MySQL.prepare.await([[
        INSERT INTO `czcraft_operation_steps`
            (`operation_id`, `step_name`, `status`, `result`, `attempted_at`)
        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP(3))
        ON DUPLICATE KEY UPDATE
            `status` = IF(`status` = 'COMPLETED', `status`, VALUES(`status`)),
            `result` = IF(`status` = 'COMPLETED', `result`, VALUES(`result`)),
            `attempted_at` = CURRENT_TIMESTAMP(3)
    ]], { operationId, stepName, status, result and json.encode(result) or nil })
end

-- Marks the operation as completed.
function OperationsRepo.complete(operationId)
    MySQL.update.await(
        "UPDATE `czcraft_operations` SET `status` = 'COMPLETED', `stage` = 'COMPLETED' WHERE `operation_id` = ?",
        { operationId }
    )
end

-- Marks the operation as failed with an error message.
function OperationsRepo.fail(operationId, errorMessage)
    MySQL.update.await(
        "UPDATE `czcraft_operations` SET `status` = 'FAILED', `error` = ? WHERE `operation_id` = ?",
        { errorMessage, operationId }
    )
end

CZCraft.OperationsRepo = OperationsRepo
return OperationsRepo
