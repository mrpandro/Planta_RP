-- qb-czcraft event bus
-- Thin wrapper over TriggerClientEvent/TriggerEvent for sanitized projections
-- sent to clients (machine prop streaming) and internal wake events (stock
-- change, cycle complete, bill edit). No recipe/state data is ever sent to the
-- NUI/client beyond intent + IDs + projections.

CZCraft = CZCraft or {}

local EventBus = {}

-- Broadcasts a machine projection so nearby clients can stream a local prop.
-- Sends only machine_uuid, machine_type, transform — never network IDs.
-- @param projection table { machine_uuid, machine_type, pos_x, pos_y, pos_z, heading }
function EventBus.broadcastMachineProjection(projection)
    TriggerClientEvent('qb-czcraft:client:streamMachine', -1, projection)
end

-- Tells clients to remove a streamed prop (machine picked up or removed).
-- @param machineUuid string
function EventBus.broadcastMachineRemoval(machineUuid)
    TriggerClientEvent('qb-czcraft:client:removeMachine', -1, machineUuid)
end

-- Internal wake: a machine's state changed and the scheduler should re-heap it.
-- @param machineUuid string
function EventBus.wakeScheduler(machineUuid)
    TriggerEvent('qb-czcraft:internal:wake', machineUuid)
end

CZCraft.EventBus = EventBus
return EventBus
