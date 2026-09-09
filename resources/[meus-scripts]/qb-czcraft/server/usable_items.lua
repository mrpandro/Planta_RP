-- qb-czcraft server usable item registration
-- Registers cz_*_machine items and repairkit as QBCore usable items.
-- When a player uses one of these items from their inventory, QBCore
-- calls the server-side callback registered here, which triggers a
-- client event that the client module handles.
--
-- This file exists because the previous client code listened for
-- 'QBCore:Client:UseItem' — an event that no resource in the server
-- actually fires. The correct QBCore flow is:
--   1. Player clicks "Use" in inventory
--   2. qb-inventory server calls QBCore.Functions.CanUseItem(name)
--   3. If a callback was registered via CreateUseableItem, it runs
--   4. The callback triggers a client event the client handles

local QBCore = exports['qb-core']:GetCoreObject()

-- Register each machine item. The client starts placement when it
-- receives the 'qb-czcraft:client:useMachineItem' event.
for _, machine in ipairs(CZCraft.Config.Machines) do
    QBCore.Functions.CreateUseableItem(machine.item, function(source, itemData)
        TriggerClientEvent('qb-czcraft:client:useMachineItem', source, itemData.name, itemData)
    end)
end

-- Register the repairkit. The client starts the repair flow when it
-- receives the 'qb-czcraft:client:useRepairkit' event.
QBCore.Functions.CreateUseableItem('repairkit', function(source, itemData)
    TriggerClientEvent('qb-czcraft:client:useRepairkit', source, itemData)
end)

print('[qb-czcraft] Usable items registered: ' ..
    table.concat((function()
        local names = {}
        for _, m in ipairs(CZCraft.Config.Machines) do names[#names + 1] = m.item end
        names[#names + 1] = 'repairkit'
        return names
    end)(), ', '))
