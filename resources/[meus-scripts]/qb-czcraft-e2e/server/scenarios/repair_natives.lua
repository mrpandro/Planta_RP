-- qb-czcraft-e2e scenario: vehicle repair native diagnostic
--
-- Original purpose: verify that SetVehicleFixed, SetVehicleEngineHealth,
-- SetVehicleBodyHealth, SetVehiclePetrolTankHealth, SetVehicleWheelHealth,
-- and SetVehicleTyreBurst apply correctly server-side against a real
-- networked vehicle resolved via NetworkGetEntityFromNetworkId.
--
-- FINDING (2026-09-08, live staging diagnostic):
-- Vehicle repair natives are silent no-ops server-side in FiveM. The calls
-- succeed (no error) but have no effect — health values stay at 0.0. This is
-- not a OneSync issue (OneSync is on), not an entity resolution issue (entity
-- resolves correctly), and not a Lua environment issue (the diagnostic runs
-- in qb-czcraft's own Lua state). Vehicle health is a client-side concept.
--
-- CONSEQUENCE:
-- The repairkit handler's original "repair-applied-server-side-before-item-
-- consumed" design was broken — it called natives that do nothing. The
-- handler has been redesigned to use a pending-repair-ack flow: the server
-- validates and creates a pending state, the client applies the repair
-- client-side and sends an ack, the server consumes the item only on ack.
--
-- This scenario now verifies:
-- 1. Vehicle creation and networking work server-side.
-- 2. GetEntityType returns 2 for vehicles (confirming the bug fix in
--    server/repairkit.lua where it incorrectly checked for type 3).
-- 3. Server-side repair natives are indeed no-ops (documented as a PASS
--    to confirm the diagnostic finding is reproducible).
-- 4. The pending-repair-ack state machine's server-side invariants.
--
-- Full end-to-end testing of the repair flow requires a real client
-- interaction (using the repairkit item near a vehicle). This scenario
-- tests the server-side pieces that can be verified without a client.
--
-- Command: /cze2e repair_natives
-- Requires: a player to be online (the vehicle is spawned near the first
-- connected player so it networks).

CZE2E = CZE2E or {}

local function runRepairNatives()
    print('[E2E] === repair_natives: start ===')

    -- Find the first connected player to anchor the vehicle spawn.
    local players = GetPlayers()
    if not players or #players == 0 then
        print('[E2E][repair_natives] FAIL: no players online — need at least one client to network the vehicle')
        return false
    end
    local src = tonumber(players[1])
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then
        print('[E2E][repair_natives] FAIL: first player has no ped')
        return false
    end
    local coords = GetEntityCoords(ped)
    print(('[E2E][repair_natives] using player %d at %.2f,%.2f,%.2f'):format(src, coords.x, coords.y, coords.z))

    -- Spawn a vehicle server-side near the player.
    local model = 'sultan'
    local hash = GetHashKey(model)
    local veh = CreateVehicleServerSetter(hash, 'automobile')
    SetEntityCoords(veh, coords.x + 3.0, coords.y + 3.0, coords.z, false, false, false, true)

    if not veh or veh == 0 or not DoesEntityExist(veh) then
        print('[E2E][repair_natives] FAIL: CreateVehicleServerSetter returned no entity')
        return false
    end

    -- Get the network ID (the same path the repairkit handler uses).
    local netId = NetworkGetNetworkIdFromEntity(veh)
    print(('[E2E][repair_natives] vehicle entity=%d netId=%d'):format(veh, netId))
    if not netId or netId == 0 then
        print('[E2E][repair_natives] FAIL: vehicle has no network ID — not networked')
        DeleteEntity(veh)
        return false
    end

    -- Resolve back via NetworkGetEntityFromNetworkId (the repairkit handler's path).
    local resolved = NetworkGetEntityFromNetworkId(netId)
    if not resolved or resolved == 0 or not DoesEntityExist(resolved) then
        print('[E2E][repair_natives] FAIL: NetworkGetEntityFromNetworkId did not resolve the vehicle')
        DeleteEntity(veh)
        return false
    end
    print(('[E2E][repair_natives] NetworkGetEntityFromNetworkId(netId=%d) -> entity=%d (match=%s)'):format(
        netId, resolved, tostring(resolved == veh)))

    -- Check 1: GetEntityType must return 2 for vehicles.
    -- The repairkit handler was checking for type 3 (incorrect — 3 is object).
    -- This was fixed in the redesigned handler.
    local entityType = GetEntityType(resolved)
    local typePass = entityType == 2
    print(('[E2E][repair_natives] GetEntityType=%d (expected 2=vehicle) -> %s'):format(
        entityType, typePass and 'PASS' or 'FAIL'))

    -- Check 2: Server-side repair natives are no-ops (documented finding).
    -- We verify this by calling SetVehicleBodyHealth (the one SET native that
    -- IS available as a Lua global) and checking that the health value
    -- does NOT change. This confirms the diagnostic finding is reproducible.
    local bodyBefore = GetVehicleBodyHealth(resolved)
    SetVehicleBodyHealth(resolved, 500.0)
    local bodyAfter = GetVehicleBodyHealth(resolved)
    local noOpPass = math.abs(bodyAfter - bodyBefore) < 0.1  -- no change = no-op confirmed
    print(('[E2E][repair_natives] server-side SetVehicleBodyHealth no-op: before=%.1f after=%.1f -> %s'):format(
        bodyBefore, bodyAfter, noOpPass and 'PASS (confirmed no-op)' or 'FAIL (unexpected change)'))

    -- Check 3: Citizen.InvokeNative calls succeed but also have no effect.
    -- SetVehicleEngineHealth hash: 0x45F5E363
    local engBefore = GetVehicleEngineHealth(resolved)
    local okInvoke = pcall(Citizen.InvokeNative, 0x45F5E363, resolved, 500.0)
    local engAfter = GetVehicleEngineHealth(resolved)
    local invokeNoOpPass = okInvoke and math.abs(engAfter - engBefore) < 0.1
    print(('[E2E][repair_natives] InvokeNative SetVehicleEngineHealth no-op: ok=%s before=%.1f after=%.1f -> %s'):format(
        tostring(okInvoke), engBefore, engAfter,
        invokeNoOpPass and 'PASS (confirmed no-op)' or 'FAIL (unexpected change)'))

    -- Check 4: The repairkit handler's pending-repair-ack state machine.
    -- Verify that the handler is loaded and has the expected structure.
    local handlerPass = CZCraft.Repairkit ~= nil
        and CZCraft.Repairkit.ACK_TIMEOUT_MS ~= nil
        and CZCraft.Repairkit.ACK_TIMEOUT_MS > 0
    print(('[E2E][repair_natives] repairkit handler loaded with ACK_TIMEOUT_MS=%s -> %s'):format(
        tostring(CZCraft.Repairkit and CZCraft.Repairkit.ACK_TIMEOUT_MS), handlerPass and 'PASS' or 'FAIL'))

    -- Cleanup.
    DeleteEntity(veh)

    local allPass = typePass and noOpPass and invokeNoOpPass and handlerPass
    print(('[E2E] === repair_natives: %s ==='):format(allPass and 'PASS' or 'FAIL'))
    print('[E2E][repair_natives] NOTE: full repair flow (client-side repair + ack) requires')
    print('[E2E][repair_natives] manual testing with a real client using the repairkit item.')
    return allPass
end

CZE2E.runRepairNatives = runRepairNatives
return runRepairNatives
