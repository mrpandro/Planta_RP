-- Freeze Player
local frozen = {}
RegisterNetEvent('ps-adminmenu:server:FreezePlayer', function(data, selectedData)
    local data = CheckDataFromKey(data)
    if not data or not CheckPerms(source, data.perms) then return end
    local src = source

    local target = tonumber(selectedData["Player"].value)
    if not target then return end

    local Player = QBCore.Functions.GetPlayer(target)
    if not Player then
        return QBCore.Functions.Notify(src, locale("not_online"), 'error', 7500)
    end

    local ped = GetPlayerPed(target)
    frozen[target] = not frozen[target]

    if frozen[target] then
        FreezeEntityPosition(ped, true)
        QBCore.Functions.Notify(src,
            locale("Frozen",
                Player.PlayerData.charinfo.firstname ..
                " " .. Player.PlayerData.charinfo.lastname .. " | " .. Player.PlayerData.citizenid), 'Success', 7500)
    else
        FreezeEntityPosition(ped, false)
        QBCore.Functions.Notify(src,
            locale("deFrozen",
                Player.PlayerData.charinfo.firstname ..
                " " .. Player.PlayerData.charinfo.lastname .. " | " .. Player.PlayerData.citizenid), 'Success', 7500)
    end
end)

-- Drunk Player
RegisterNetEvent('ps-adminmenu:server:DrunkPlayer', function(data, selectedData)
    local data = CheckDataFromKey(data)
    if not data or not CheckPerms(source, data.perms) then return end

    local src = source
    local target = tonumber(selectedData["Player"].value)
    if not target then return end
    local targetPed = GetPlayerPed(target)
    local Player = QBCore.Functions.GetPlayer(target)

    if not Player then
        return QBCore.Functions.Notify(src, locale("not_online"), 'error', 7500)
    end

    TriggerClientEvent('ps-adminmenu:client:InitiateDrunkEffect', target)
    QBCore.Functions.Notify(src,
        locale("playerdrunk",
            Player.PlayerData.charinfo.firstname ..
            " " .. Player.PlayerData.charinfo.lastname .. " | " .. Player.PlayerData.citizenid), 'Success', 7500)
end)
