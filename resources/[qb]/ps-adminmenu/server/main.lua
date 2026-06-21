local coreResource = Config.Core == "qbx_core" and "qb-core" or Config.Core
QBCore = exports[coreResource]:GetCoreObject()

lib.addCommand('admin', {
    help = 'Open the admin menu',
    restricted = 'qbcore.mod'
}, function(source)
    if not QBCore.Functions.IsOptin(source) then TriggerClientEvent('QBCore:Notify', source, 'You are not on admin duty', 'error'); return end
    TriggerClientEvent('ps-adminmenu:client:OpenUI', source)
end)

RegisterNetEvent('ps-adminmenu:server:ValidateClientAction', function(key, selectedData, event, perms)
    local src = source
    if not CheckPerms(src, perms) then return end
    TriggerClientEvent(event, src, key, selectedData)
end)

RegisterNetEvent('ps-adminmenu:server:ValidateCommand', function(command, perms)
    local src = source
    if not CheckPerms(src, perms) then return end
    
    if command == 'vector2' or command == 'vector3' or command == 'vector4' or command == 'heading' then
        TriggerClientEvent('ps-adminmenu:client:CopyCoords', src, command)
    elseif command == 'setammo' then
        TriggerClientEvent('ps-adminmenu:client:SetAmmoCommand', src)
    end
end)
