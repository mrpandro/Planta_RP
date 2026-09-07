local QBCore = exports['qb-core']:GetCoreObject()

local Config = {
    Custo = 0, 
    ItemNecessario = 'repairkit', 
    ConsumirItem = true 
}

-- Disabled: repairkit is now handled by qb-czcraft (server-authoritative).
-- Keeping this active caused a double-handler conflict with qb-czcraft's
-- QBCore:Client:UseItem hook.
-- QBCore.Functions.CreateUseableItem(Config.ItemNecessario, function(source, item)
--     local Player = QBCore.Functions.GetPlayer(source)
--     if not Player then return end
--
--     TriggerClientEvent('simple-repair:client:VerificarCarro', source)
-- end)

-- 2. FINALIZAR: Remover o item e aplicar reparação
RegisterNetEvent('simple-repair:server:CobrarEFinalizar')
AddEventHandler('simple-repair:server:CobrarEFinalizar', function(vehicleNetId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)

    if not Player then
        TriggerClientEvent('QBCore:Notify', src, "Erro ao reparar!", "error")
        return
    end

    -- Validar vehicleNetId
    vehicleNetId = tonumber(vehicleNetId)
    if not vehicleNetId or vehicleNetId <= 0 then
        TriggerClientEvent('QBCore:Notify', src, "Veículo inválido!", "error")
        return
    end

    local vehEntity = NetworkGetEntityFromNetworkId(vehicleNetId)
    if not vehEntity or vehEntity == 0 or not DoesEntityExist(vehEntity) then
        TriggerClientEvent('QBCore:Notify', src, "Veículo não encontrado!", "error")
        return
    end

    -- Validar item ANTES de fazer qualquer coisa
    if Config.ConsumirItem then
        if not Player.Functions.GetItemByName(Config.ItemNecessario) then
            TriggerClientEvent('QBCore:Notify', src, "Não tens o kit de reparação!", "error")
            return
        end

        -- Remover item
        Player.Functions.RemoveItem(Config.ItemNecessario, 1)
        TriggerClientEvent('inventory:client:ItemBox', src, QBCore.Shared.Items[Config.ItemNecessario], "remove")
    end

    -- SÓ DEPOIS confirmar a reparação
    TriggerClientEvent('simple-repair:client:AplicarFix', src, vehicleNetId)
end)