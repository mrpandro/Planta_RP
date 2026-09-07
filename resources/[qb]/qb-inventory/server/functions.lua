-- Local Functions

-- Optimistic generation counter per player identifier. Bumped by every
-- in-memory mutator (Add/Remove/Set/Clear) so ApplyIdempotentBatch can detect
-- a concurrent sync mutation that ran while it awaited the journal tx, and
-- re-snapshot/re-validate instead of silently overwriting it.
local InventoryGeneration = {}

-- Mutations whose in-memory swap already happened but whose tx_2 persist
-- step failed. A same-session retry of such a mutation must retry ONLY the
-- persist step (tx_2), never re-validate or re-swap — the in-memory state
-- already reflects the batch, so re-validation would fail or double-apply.
-- Cleared on successful persist. Cross-session retries are safe without
-- this table because LoadInventory loads the original (un-persisted) DB
-- inventory and the PENDING journal row triggers a clean re-application.
local PersistPending = {}

local function bumpGeneration(identifier)
    InventoryGeneration[identifier] = (InventoryGeneration[identifier] or 0) + 1
end

local function InitializeInventory(inventoryId, data)
    Inventories[inventoryId] = {
        items = {},
        isOpen = false,
        label = data and data.label or inventoryId,
        maxweight = data and data.maxweight or Config.StashSize.maxweight,
        slots = data and data.slots or Config.StashSize.slots
    }
    return Inventories[inventoryId]
end

local function GetFirstFreeSlot(items, maxSlots)
    for i = 1, maxSlots do
        if items[i] == nil then
            return i
        end
    end
    return nil
end

local function SetupShopItems(shopItems)
    local items = {}
    local slot = 1
    if shopItems and next(shopItems) then
        for _, item in pairs(shopItems) do
            local itemInfo = QBCore.Shared.Items[item.name:lower()]
            if itemInfo then
                items[slot] = {
                    name = itemInfo['name'],
                    amount = tonumber(item.amount),
                    info = item.info or {},
                    label = itemInfo['label'],
                    description = itemInfo['description'] or '',
                    weight = itemInfo['weight'],
                    type = itemInfo['type'],
                    unique = itemInfo['unique'],
                    useable = itemInfo['useable'],
                    price = item.price,
                    image = itemInfo['image'],
                    slot = slot,
                }
                slot = slot + 1
            end
        end
    end
    return items
end

-- Exported Functions

function LoadInventory(source, citizenid)
    local inventory = MySQL.prepare.await('SELECT inventory FROM players WHERE citizenid = ?', { citizenid })
    local loadedInventory = {}
    local missingItems = {}
    inventory = json.decode(inventory)
    if not inventory or not next(inventory) then return loadedInventory end

    for _, item in pairs(inventory) do
        if item then
            local itemInfo = QBCore.Shared.Items[item.name:lower()]

            if itemInfo then
                loadedInventory[item.slot] = {
                    name = itemInfo['name'],
                    amount = item.amount,
                    info = item.info or '',
                    label = itemInfo['label'],
                    description = itemInfo['description'] or '',
                    weight = itemInfo['weight'],
                    type = itemInfo['type'],
                    unique = itemInfo['unique'],
                    useable = itemInfo['useable'],
                    image = itemInfo['image'],
                    shouldClose = itemInfo['shouldClose'],
                    slot = item.slot,
                    combinable = itemInfo['combinable']
                }
            else
                missingItems[#missingItems + 1] = item.name:lower()
            end
        end
    end

    if #missingItems > 0 then
        print(('The following items were removed for player %s as they no longer exist: %s'):format(source and GetPlayerName(source) or citizenid, table.concat(missingItems, ', ')))
    end

    return loadedInventory
end

exports('LoadInventory', LoadInventory)

function SaveInventory(source, offline)
    local PlayerData
    if offline then
        PlayerData = source
    else
        local Player = exports['qb-core']:GetPlayer(source)
        if not Player then return end
        PlayerData = Player.PlayerData
    end

    local items = PlayerData.items
    local ItemsJson = {}

    if items and next(items) then
        for slot, item in pairs(items) do
            if item then
                ItemsJson[#ItemsJson + 1] = {
                    name = item.name,
                    amount = item.amount,
                    info = item.info,
                    type = item.type,
                    slot = slot,
                }
            end
        end
        MySQL.prepare('UPDATE players SET inventory = ? WHERE citizenid = ?', { json.encode(ItemsJson), PlayerData.citizenid })
    else
        MySQL.prepare('UPDATE players SET inventory = ? WHERE citizenid = ?', { '[]', PlayerData.citizenid })
    end
end

exports('SaveInventory', SaveInventory)

-- Sets the items in a inventory.
--- @param identifier string The identifier of the player or inventory.
--- @param items table The items to set in the inventory.
--- @param reason string The reason for setting the items.
function SetInventory(identifier, items, reason)
    local player = exports['qb-core']:GetPlayer(identifier)

    print('Setting inventory for ' .. identifier)

    if not player and not Inventories[identifier] and not Drops[identifier] then
        print('SetInventory: Inventory not found')
        return
    end

    if player then
        player.SetPlayerData('items', items)
        bumpGeneration(identifier)
        if not player.Offline then
            local logMessage = string.format('**%s (citizenid: %s | id: %s)** items set: %s', GetPlayerName(identifier), player.PlayerData.citizenid, identifier, json.encode(items))
            TriggerEvent('qb-log:server:CreateLog', 'playerinventory', 'SetInventory', 'blue', logMessage)
        end
    elseif Drops[identifier] then
        Drops[identifier].items = items
    elseif Inventories[identifier] then
        Inventories[identifier].items = items
    end

    local invName = player and GetPlayerName(identifier) .. ' (' .. identifier .. ')' or identifier
    local setReason = reason or 'No reason specified'
    local resourceName = GetInvokingResource() or 'qb-inventory'
    TriggerEvent(
        'qb-log:server:CreateLog',
        'playerinventory',
        'Inventory Set',
        'blue',
        '**Inventory:** ' .. invName .. '\n' ..
        '**Items:** ' .. json.encode(items) .. '\n' ..
        '**Reason:** ' .. setReason .. '\n' ..
        '**Resource:** ' .. resourceName
    )
end

exports('SetInventory', SetInventory)

-- Sets the value of a specific key in the data of an item for a player.
--- @param source number The player's server ID.
--- @param itemName string The name of the item.
--- @param key string The key to set the value for.
--- @param val any The value to set for the key.
--- @param slot number (optional) The slot number of the item. If not provided, it will search by name.
--- @return boolean|nil - Returns true if the value was set successfully, false otherwise.
function SetItemData(source, itemName, key, val, slot)
    if not itemName or not key then return false end
    local Player = exports['qb-core']:GetPlayer(source)
    if not Player then return end
    local item
    if slot then
        item = Player.PlayerData.items[tonumber(slot)]
        if not item or item.name:lower() ~= itemName:lower() then return false end
    else
        item = GetItemByName(source, itemName)
        if not item then return false end
    end
    item[key] = val
    Player.PlayerData.items[item.slot] = item
    Player.SetPlayerData('items', Player.PlayerData.items)
    return true
end

exports('SetItemData', SetItemData)

function UseItem(itemName, ...)
    local itemData = QBCore.Functions.CanUseItem(itemName)
    if type(itemData) == 'table' and itemData.func then
        itemData.func(...)
    end
end

exports('UseItem', UseItem)

-- Retrieves the slots in the items table that contain a specific item.
--- @param items table The table containing the items.
--- @param itemName string The name of the item to search for.
--- @return table A table containing the slots where the item was found.
function GetSlotsByItem(items, itemName)
    local slotsFound = {}
    if not items then return slotsFound end
    for slot, item in pairs(items) do
        if item.name:lower() == itemName:lower() then
            slotsFound[#slotsFound + 1] = slot
        end
    end
    return slotsFound
end

exports('GetSlotsByItem', GetSlotsByItem)

-- Retrieves the first slot number that contains an item with the specified name.
--- @param items table The table of items to search through.
--- @param itemName string The name of the item to search for.
--- @return number|nil - The slot number of the first matching item, or nil if no match is found.
function GetFirstSlotByItem(items, itemName)
    if not items then return end
    for slot, item in pairs(items) do
        if item.name:lower() == itemName:lower() then
            return tonumber(slot)
        end
    end
    return nil
end

exports('GetFirstSlotByItem', GetFirstSlotByItem)

--- Retrieves an item from a player's inventory based on the specified slot.
--- @param source number The player's server ID.
--- @param slot number The slot number of the item.
--- @return table|nil - item data if found, or nil if not found.
function GetItemBySlot(source, slot)
    local Player = exports['qb-core']:GetPlayer(source)
    if not Player then return end
    local items = Player.PlayerData.items
    return items[tonumber(slot)]
end

exports('GetItemBySlot', GetItemBySlot)

function GetTotalWeight(items)
    if not items then return 0 end
    local weight = 0
    for _, item in pairs(items) do
        local amount = item.amount
        if type(amount) ~= 'number' then
            amount = 1
        end

        weight = weight + (item.weight * amount)
    end
    return tonumber(weight)
end

exports('GetTotalWeight', GetTotalWeight)

-- Retrieves an item from a player's inventory by its name.
--- @param source number - The player's server ID.
--- @param item string - The name of the item to retrieve.
--- @return table|nil - item data if found, nil otherwise.
function GetItemByName(source, item)
    local Player = exports['qb-core']:GetPlayer(source)
    if not Player then return end
    local items = Player.PlayerData.items
    local slot = GetFirstSlotByItem(items, tostring(item):lower())
    return items[slot]
end

exports('GetItemByName', GetItemByName)

-- Retrieves a list of items with a specific name from a player's inventory.
--- @param source number The player's server ID.
--- @param item string The name of the item to search for.
--- @return table|nil - containing the items with the specified name.
function GetItemsByName(source, item)
    local Player = exports['qb-core']:GetPlayer(source)
    if not Player then return end
    local PlayerItems = Player.PlayerData.items
    item = tostring(item):lower()
    local items = {}
    for _, slot in pairs(GetSlotsByItem(PlayerItems, item)) do
        if slot then
            items[#items + 1] = PlayerItems[slot]
        end
    end
    return items
end

exports('GetItemsByName', GetItemsByName)

--- Retrieves the total count of used and free slots for a player or an inventory.
--- @param identifier number|string The player's identifier or the identifier of an inventory or drop.
--- @return number, number - The total count of used slots and the total count of free slots. If no inventory is found, returns 0 and the maximum slots.
function GetSlots(identifier)
    local inventory, maxSlots
    local player = exports['qb-core']:GetPlayer(identifier)
    if player then
        inventory = player.PlayerData.items
        maxSlots = Config.MaxSlots
    elseif Inventories[identifier] then
        inventory = Inventories[identifier].items
        maxSlots = Inventories[identifier].slots
    elseif Drops[identifier] then
        inventory = Drops[identifier].items
        maxSlots = Drops[identifier].slots
    end
    if not inventory then return 0, maxSlots end
    local slotsUsed = 0
    for _, v in pairs(inventory) do
        if v then
            slotsUsed = slotsUsed + 1
        end
    end
    local slotsFree = maxSlots - slotsUsed
    return slotsUsed, slotsFree
end

exports('GetSlots', GetSlots)

--- Retrieves the total count of specified items for a player.
--- @param source number The player's source ID.
--- @param items table|string The items to count. Can be either a table of item names or a single item name.
--- @return number|nil - The total count of the specified items.
function GetItemCount(source, items)
    local Player = exports['qb-core']:GetPlayer(source)
    if not Player then return end
    local isTable = type(items) == 'table'
    local itemsSet = isTable and {} or nil
    if isTable then
        for _, item in pairs(items) do
            itemsSet[item] = true
        end
    end
    local count = 0
    for _, item in pairs(Player.PlayerData.items) do
        if (isTable and itemsSet[item.name]) or (not isTable and items == item.name) then
            count = count + item.amount
        end
    end
    return count
end

exports('GetItemCount', GetItemCount)

--- Checks if an item can be added to a inventory based on the weight and slots available.
--- @param identifier string The identifier of the player or inventory.
--- @param item string The item name.
--- @param amount number The amount of the item.
--- @return boolean - Returns true if the item can be added, false otherwise.
--- @return string|nil - Returns a string indicating the reason why the item cannot be added (e.g., 'weight' or 'slots'), or nil if it can be added.
function CanAddItem(identifier, item, amount)
    local Player = exports['qb-core']:GetPlayer(identifier)

    local itemData = QBCore.Shared.Items[item:lower()]
    if not itemData then return false end

    local inventory, items
    if Player then
        inventory = {
            maxweight = Config.MaxWeight,
            slots = Config.MaxSlots
        }
        items = Player.PlayerData.items
    elseif Inventories[identifier] then
        inventory = Inventories[identifier]
        items = Inventories[identifier].items
    end

    if not inventory then
        print('CanAddItem: Inventory not found')
        return false
    end

    local weight = itemData.weight * amount
    local totalWeight = GetTotalWeight(items) + weight
    if totalWeight > inventory.maxweight then
        return false, 'weight'
    end

    local slotsUsed, _ = GetSlots(identifier)

    if slotsUsed >= inventory.slots then
        for _, v in pairs(items) do
            if v.name == itemData.name then
                if itemData.unique then break end
                print(('CanAddItem: Player %s has no free slots for item %s, but has %d of it already'):format(identifier, itemData.name, v.amount))
                goto continue
            end
        end
        return false, 'slots'
    end

    ::continue::

    return true
end

exports('CanAddItem', CanAddItem)

--- Gets the total free weight of the player's inventory.
--- @param source number The player's server ID.
--- @return number - Returns the free weight of the players inventory. Error will return 0
function GetFreeWeight(source)
    if not source then
        warn('Source was not passed into GetFreeWeight')
        return 0
    end
    local Player = exports['qb-core']:GetPlayer(source)
    if not Player then return 0 end

    local totalWeight = GetTotalWeight(Player.PlayerData.items)
    local freeWeight = Config.MaxWeight - totalWeight
    return freeWeight
end

exports('GetFreeWeight', GetFreeWeight)

function ClearInventory(source, filterItems)
    local player = exports['qb-core']:GetPlayer(source)
    local savedItemData = {}
    if filterItems then
        if type(filterItems) == 'string' then
            local item = GetItemByName(source, filterItems)
            if item then savedItemData[item.slot] = item end
        elseif type(filterItems) == 'table' then
            for _, itemName in ipairs(filterItems) do
                local item = GetItemByName(source, itemName)
                if item then savedItemData[item.slot] = item end
            end
        end
    end
    player.SetPlayerData('items', savedItemData)
    bumpGeneration(source)
    if not player.Offline then
        local logMessage = string.format('**%s (citizenid: %s | id: %s)** inventory cleared', GetPlayerName(source), player.PlayerData.citizenid, source)
        TriggerEvent('qb-log:server:CreateLog', 'playerinventory', 'ClearInventory', 'red', logMessage)
        local ped = GetPlayerPed(source)
        local weapon = GetSelectedPedWeapon(ped)
        if weapon ~= `WEAPON_UNARMED` then
            RemoveWeaponFromPed(ped, weapon)
        end
        if Player(source).state.inv_busy then TriggerClientEvent('qb-inventory:client:updateInventory', source) end
    end
end

exports('ClearInventory', ClearInventory)

--- Checks if a player has a certain item or items in their inventory.
--- @param source number The player's server ID.
--- @param items string|table The name of the item or a table of item names.
--- @param amount number (optional) The minimum amount required for each item.
--- @return boolean - Returns true if the player has the item(s) with the specified amount, false otherwise.
function HasItem(source, items, amount)
    local Player = exports['qb-core']:GetPlayer(source)
    if not Player then return false end
    local isTable = type(items) == 'table'
    local isArray = isTable and table.type(items) == 'array' or false
    local totalItems = isArray and #items or 0
    local count = 0

    if isTable and not isArray then
        for _ in pairs(items) do totalItems = totalItems + 1 end
    end

    for _, itemData in pairs(Player.PlayerData.items) do
        if isTable then
            for k, v in pairs(items) do
                if itemData and itemData.name == (isArray and v or k) and ((amount and itemData.amount >= amount) or (not isArray and itemData.amount >= v) or (not amount and isArray)) then
                    count = count + 1
                    if count == totalItems then
                        return true
                    end
                end
            end
        else -- Single item as string
            if itemData and itemData.name == items and (not amount or (itemData and amount and itemData.amount >= amount)) then
                return true
            end
        end
    end

    return false
end

exports('HasItem', HasItem)

-- CloseInventory function closes the inventory for a given source and identifier.
-- It sets the isOpen flag of the inventory identified by the given identifier to false.
-- It also sets the inv_busy flag of the player identified by the given source to false.
-- Finally, it triggers the 'qb-inventory:client:closeInv' event for the given source.
function CloseInventory(source, identifier)
    if identifier and Inventories[identifier] then
        Inventories[identifier].isOpen = false
    end
    Player(source).state.inv_busy = false
    TriggerClientEvent('qb-inventory:client:closeInv', source)
end

exports('CloseInventory', CloseInventory)

-- Opens the inventory of a player by their ID.
--- @param source number - The player's server ID.
--- @param targetId number - The ID of the player whose inventory will be opened.
function OpenInventoryById(source, targetId)
    local QBPlayer = exports['qb-core']:GetPlayer(source)
    local TargetPlayer = exports['qb-core']:GetPlayer(tonumber(targetId))
    if not QBPlayer or not TargetPlayer then return end
    if Player(targetId).state.inv_busy then CloseInventory(targetId) end
    local playerItems = QBPlayer.PlayerData.items
    local targetItems = TargetPlayer.PlayerData.items
    local formattedInventory = {
        name = 'otherplayer-' .. targetId,
        label = GetPlayerName(targetId),
        maxweight = Config.MaxWeight,
        slots = Config.MaxSlots,
        inventory = targetItems
    }
    Wait(1500)
    Player(targetId).state.inv_busy = true
    TriggerClientEvent('qb-inventory:client:openInventory', source, playerItems, formattedInventory)
end

exports('OpenInventoryById', OpenInventoryById)

-- Clears a given stash of all items inside
--- @param identifier string
function ClearStash(identifier)
    if not identifier then return end
    local inventory = Inventories[identifier]
    if not inventory then return end
    inventory.items = {}
    MySQL.prepare('UPDATE inventories SET items = ? WHERE identifier = ?', { json.encode(inventory.items), identifier })
end

exports('ClearStash', ClearStash)

--- @param shopData table The data of the shop to create.
function CreateShop(shopData)
    if shopData.name then
        RegisteredShops[shopData.name] = {
            name = shopData.name,
            label = shopData.label,
            coords = shopData.coords,
            slots = #shopData.items,
            items = SetupShopItems(shopData.items)
        }
    else
        for key, data in pairs(shopData) do
            if type(data) == 'table' then
                if data.name then
                    local shopName = type(key) == 'number' and data.name or key
                    RegisteredShops[shopName] = {
                        name = shopName,
                        label = data.label,
                        coords = data.coords,
                        slots = #data.items,
                        items = SetupShopItems(data.items)
                    }
                else
                    CreateShop(data)
                end
            end
        end
    end
end

exports('CreateShop', CreateShop)

--- @param source number The player's server ID.
--- @param name string The identifier of the inventory to open.
function OpenShop(source, name)
    if not name then return end
    local Player = exports['qb-core']:GetPlayer(source)
    if not Player then return end
    if not RegisteredShops[name] then return end
    local playerPed = GetPlayerPed(source)
    local playerCoords = GetEntityCoords(playerPed)
    if RegisteredShops[name].coords then
        local shopDistance = vector3(RegisteredShops[name].coords.x, RegisteredShops[name].coords.y, RegisteredShops[name].coords.z)
        if shopDistance then
            local distance = #(playerCoords - shopDistance)
            if distance > 5.0 then return end
        end
    end
    local formattedInventory = {
        name = 'shop-' .. RegisteredShops[name].name,
        label = RegisteredShops[name].label,
        maxweight = 5000000,
        slots = #RegisteredShops[name].items,
        inventory = RegisteredShops[name].items
    }
    TriggerClientEvent('qb-inventory:client:openInventory', source, Player.PlayerData.items, formattedInventory)
end

exports('OpenShop', OpenShop)

--- @param source number The player's server ID.
--- @param identifier string|nil The identifier of the inventory to open.
--- @param data table|nil Additional data for initializing the inventory.
function OpenInventory(source, identifier, data)
    if Player(source).state.inv_busy then return end
    local QBPlayer = exports['qb-core']:GetPlayer(source)
    if not QBPlayer then return end

    if not identifier then
        Player(source).state.inv_busy = true
        TriggerClientEvent('qb-inventory:client:openInventory', source, QBPlayer.PlayerData.items)
        return
    end

    if type(identifier) ~= 'string' then
        print('Inventory tried to open an invalid identifier')
        return
    end

    local inventory = Inventories[identifier]

    if inventory and inventory.isOpen then
        TriggerClientEvent('QBCore:Notify', source, Lang:t('notify.invinuse'), 'error')
        return
    end

    if not inventory then inventory = InitializeInventory(identifier, data) end
    inventory.maxweight = (data and data.maxweight) or (inventory and inventory.maxweight) or Config.StashSize.maxweight
    inventory.slots = (data and data.slots) or (inventory and inventory.slots) or Config.StashSize.slots
    inventory.label = (data and data.label) or (inventory and inventory.label) or identifier
    inventory.isOpen = source

    local formattedInventory = {
        name = identifier,
        label = inventory.label,
        maxweight = inventory.maxweight,
        slots = inventory.slots,
        inventory = inventory.items
    }
    TriggerClientEvent('qb-inventory:client:openInventory', source, QBPlayer.PlayerData.items, formattedInventory)
end

exports('OpenInventory', OpenInventory)

--- Creates a new inventory and returns the inventory object.
--- @param identifier string The identifier of the inventory to create.
--- @param data table Additional data for initializing the inventory.
function CreateInventory(identifier, data)
    if Inventories[identifier] then return end
    if not identifier then return end
    Inventories[identifier] = InitializeInventory(identifier, data)
end

exports('CreateInventory', CreateInventory)

--- Retrieves an inventory by its identifier.
--- @param identifier string The identifier of the inventory to retrieve.
--- @return table|nil - The inventory object if found, nil otherwise.
function GetInventory(identifier)
    return Inventories[identifier]
end

exports('GetInventory', GetInventory)

--- Removes an inventory by its identifier.
--- @param identifier string The identifier of the inventory to remove.
function RemoveInventory(identifier)
    if Inventories[identifier] then
        Inventories[identifier] = nil
    end
end

exports('RemoveInventory', RemoveInventory)

--- Adds an item to the player's inventory or a specific inventory.
--- @param identifier string The identifier of the player or inventory.
--- @param item string The name of the item to add.
--- @param amount number The amount of the item to add.
--- @param slot number (optional) The slot to add the item to. If not provided, it will find the first available slot.
--- @param info table (optional) Additional information about the item.
--- @param reason string (optional) The reason for adding the item.
--- @return boolean Returns true if the item was successfully added, false otherwise.
function AddItem(identifier, item, amount, slot, info, reason)
    local itemInfo = QBCore.Shared.Items[item:lower()]
    if not itemInfo then
        print('AddItem: Invalid item')
        return false
    end
    local inventory, inventoryWeight, inventorySlots
    local player = exports['qb-core']:GetPlayer(identifier)

    if player then
        inventory = player.PlayerData.items
        inventoryWeight = Config.MaxWeight
        inventorySlots = Config.MaxSlots
    elseif Inventories[identifier] then
        inventory = Inventories[identifier].items
        inventoryWeight = Inventories[identifier].maxweight
        inventorySlots = Inventories[identifier].slots
    elseif Drops[identifier] then
        inventory = Drops[identifier].items
        inventoryWeight = Drops[identifier].maxweight
        inventorySlots = Drops[identifier].slots
    end

    if not inventory then
        print('AddItem: Inventory not found')
        return false
    end

    local totalWeight = GetTotalWeight(inventory)
    if totalWeight + (itemInfo.weight * amount) > inventoryWeight then
        print('AddItem: Not enough weight available')
        return false
    end

    amount = tonumber(amount) or 1
    local updated = false

    if not itemInfo.unique then
        slot = slot or GetFirstSlotByItem(inventory, item)
        if slot then
            for _, invItem in pairs(inventory) do
                if invItem.slot == slot then
                    invItem.amount = invItem.amount + amount
                    updated = true
                    break
                end
            end
        end
    end

    if not updated then
        slot = slot or GetFirstFreeSlot(inventory, inventorySlots)
        if not slot then
            print('AddItem: No free slot available')
            return false
        end

        inventory[slot] = {
            name = item,
            amount = amount,
            info = info or {},
            label = itemInfo.label,
            description = itemInfo.description or '',
            weight = itemInfo.weight,
            type = itemInfo.type,
            unique = itemInfo.unique,
            useable = itemInfo.useable,
            image = itemInfo.image,
            shouldClose = itemInfo.shouldClose,
            slot = slot,
            combinable = itemInfo.combinable
        }

        if itemInfo.type == 'weapon' then
            if not inventory[slot].info.serie then
                inventory[slot].info.serie = tostring(QBCore.Shared.RandomInt(2) .. QBCore.Shared.RandomStr(3) .. QBCore.Shared.RandomInt(1) .. QBCore.Shared.RandomStr(2) .. QBCore.Shared.RandomInt(3) .. QBCore.Shared.RandomStr(4))
            end
            if not inventory[slot].info.quality then
                inventory[slot].info.quality = 100
            end
        end
    end

    if player then player.SetPlayerData('items', inventory) end
    if player then bumpGeneration(identifier) end
    local invName = player and GetPlayerName(identifier) .. ' (' .. identifier .. ')' or identifier
    local addReason = reason or 'No reason specified'
    local resourceName = GetInvokingResource() or 'qb-inventory'
    TriggerEvent(
        'qb-log:server:CreateLog',
        'playerinventory',
        'Item Added',
        'green',
        '**Inventory:** ' .. invName .. ' (Slot: ' .. slot .. ')\n' ..
        '**Item:** ' .. item .. '\n' ..
        '**Amount:** ' .. amount .. '\n' ..
        '**Reason:** ' .. addReason .. '\n' ..
        '**Resource:** ' .. resourceName
    )
    return true
end

exports('AddItem', AddItem)

-- Removes an item from a player's inventory.
--- @param identifier string - The identifier of the player.
--- @param item string - The name of the item to remove.
--- @param amount number - The amount of the item to remove.
--- @param slot number - The slot number of the item in the inventory. If not provided, it will find the first slot with the item.
--- @param reason string - The reason for removing the item. Defaults to 'No reason specified' if not provided.
--- @return boolean - Returns true if the item was successfully removed, false otherwise.
function RemoveItem(identifier, item, amount, slot, reason)
    if not QBCore.Shared.Items[item:lower()] then
        print('RemoveItem: Invalid item')
        return false
    end

    local inventory
    local player = exports['qb-core']:GetPlayer(identifier)

    if player then
        inventory = player.PlayerData.items
    elseif Inventories[identifier] then
        inventory = Inventories[identifier].items
    elseif Drops[identifier] then
        inventory = Drops[identifier].items
    end

    if not inventory then
        print('RemoveItem: Inventory not found')
        return false
    end

    slot = tonumber(slot) or GetFirstSlotByItem(inventory, item)

    if not slot then
        print('RemoveItem: Slot not found')
        return false
    end

    local inventoryItem = nil
    local itemKey = nil

    for key, invItem in pairs(inventory) do
        if invItem.slot == slot then
            inventoryItem = invItem
            itemKey = key
            break
        end
    end

    if not inventoryItem or inventoryItem.name:lower() ~= item:lower() then
        print('RemoveItem: Item not found in slot')
        return false
    end

    amount = tonumber(amount)
    if inventoryItem.amount < amount then
        print('RemoveItem: Not enough items in slot')
        return false
    end

    inventoryItem.amount = inventoryItem.amount - amount
    if inventoryItem.amount <= 0 then
        inventory[itemKey] = nil
    else
        inventory[itemKey] = inventoryItem
    end

    if player then
        player.SetPlayerData('items', inventory)
        bumpGeneration(identifier)

        local itemInfo = QBCore.Shared.Items[item:lower()]
        if itemInfo and itemInfo.type == 'weapon' and inventoryItem.amount <= 0 then
            checkWeapon(identifier, item)
        end
    end

    local invName = player and GetPlayerName(identifier) .. ' (' .. identifier .. ')' or identifier
    local removeReason = reason or 'No reason specified'
    local resourceName = GetInvokingResource() or 'qb-inventory'

    TriggerEvent(
        'qb-log:server:CreateLog',
        'playerinventory',
        'Item Removed',
        'red',
        '**Inventory:** ' .. invName .. ' (Slot: ' .. slot .. ')\n' ..
        '**Item:** ' .. item .. '\n' ..
        '**Amount:** ' .. amount .. '\n' ..
        '**Reason:** ' .. removeReason .. '\n' ..
        '**Resource:** ' .. resourceName
    )
    return true
end

exports('RemoveItem', RemoveItem)

-- Serializes an items table (keyed by slot) into the { name, amount, info, type,
-- slot } array shape that SaveInventory writes, so a subsequent LoadInventory
-- round-trips identically.
local function serializeForSave(items)
    local out = {}
    for slot, item in pairs(items) do
        if item then
            out[#out + 1] = {
                name = item.name,
                amount = item.amount,
                info = item.info,
                type = item.type,
                slot = slot,
            }
        end
    end
    return out
end

-- Atomically validates + persists a batch of removals/additions against a
-- player's inventory with idempotent replay detection. Restricted to the
-- CzCraft allow-list. Uses an optimistic generation counter to serialize
-- against concurrent sync mutators (AddItem/RemoveItem/Set/Clear) without
-- changing their synchronous signatures.
--
-- Concurrency model (PENDING/COMMITTED split):
--   tx_1 writes ONLY the journal row as PENDING (or detects a true replay /
--   hash mismatch). players.inventory is NOT touched in tx_1.
--   After tx_1, a synchronous generation check gates the in-memory swap. Only
--   when no sync mutator ran during tx_1's await do we swap in-memory and run
--   tx_2, which atomically writes players.inventory + marks the row COMMITTED.
--   PENDING therefore unambiguously means "DB inventory not yet written", so a
--   cross-session retry re-applies safely against the original DB inventory.
--   A concurrent sync mutation during tx_1 triggers a re-snapshot/re-validate
--   retry (max 3); a COMMITTED row with matching hash is a true replay.
--   If tx_2 fails after the in-memory swap, the mutation is tracked as
--   persist-pending so a same-session retry retries ONLY tx_2 (never
--   re-validates or re-swaps — the in-memory state already has the batch).
--
-- @param identifier string|number player source (as used by AddItem/RemoveItem)
-- @param mutationId string unique mutation id (caller-supplied, idempotency key)
-- @param removals table array of { item, amount, slot?, metadata? }
-- @param additions table array of { item, amount, slot?, info? }
-- @param reason string optional human-readable reason for the log
-- @return table { success, replayed?, result?, errors?, reason?, securityIncident? }
function ApplyIdempotentBatch(identifier, mutationId, removals, additions, reason)
    local caller = GetInvokingResource()
    if not caller or not Config.CzCraftAllowedResources[caller] then
        TriggerEvent('qb-log:server:CreateLog', 'playerinventory', 'ApplyIdempotentBatch blocked', 'red',
            '**Caller:** ' .. tostring(caller) .. '\n**Mutation:** ' .. tostring(mutationId) .. '\n**Reason:** unauthorized caller')
        return { success = false, reason = 'unauthorized caller' }
    end

    if type(mutationId) ~= 'string' or mutationId == '' then
        return { success = false, reason = 'mutationId must be a non-empty string' }
    end

    local Player = exports['qb-core']:GetPlayer(identifier)
    if not Player then
        return { success = false, reason = 'player not found' }
    end

    local citizenid = Player.PlayerData.citizenid
    removals = removals or {}
    additions = additions or {}

    -- Persist-only retry: a prior attempt of this mutation completed the
    -- in-memory swap but tx_2 (persist + commit) failed. The in-memory state
    -- already reflects the batch, so we must NOT re-validate (would fail or
    -- double-apply) or re-swap. Retry only the persist step.
    if PersistPending[identifier] and PersistPending[identifier][mutationId] then
        local resultMeta = { appliedAt = os.time(), caller = caller, reason = reason }
        local persistOk = MySQL.transaction.await({
            { query = 'UPDATE `players` SET `inventory` = ? WHERE `citizenid` = ?', values = { json.encode(serializeForSave(Player.PlayerData.items)), citizenid } },
            { query = 'UPDATE `czcraft_inventory_mutations` SET `status` = ?, `result` = ? WHERE `mutation_id` = ?', values = { 'COMMITTED', json.encode(resultMeta), mutationId } },
        })

        if persistOk then
            PersistPending[identifier][mutationId] = nil
            return { success = true, replayed = false }
        end
        return { success = false, reason = 'persist failed' }
    end

    local MAX_RETRIES = 3
    local attempt = 0
    ::retry::
    attempt = attempt + 1
    if attempt > MAX_RETRIES then
        return { success = false, reason = 'inventory changed during apply' }
    end

    local savedGen = InventoryGeneration[identifier] or 0
    local result = QBInventoryBatch.validateBatch(
        Player.PlayerData.items,
        removals,
        additions,
        { maxWeight = Config.MaxWeight, maxSlots = Config.MaxSlots },
        QBCore.Shared.Items
    )
    if not result.ok then
        return { success = false, errors = result.errors }
    end

    local canonical = QBInventoryBatch.canonicalPayload(citizenid, removals, additions)

    local txOutcome
    local replayedResult

    local journalOk = MySQL.startTransaction(function(tx)
        local rows = tx(
            'SELECT `mutation_id`, `batch_hash`, `status`, `result` FROM `czcraft_inventory_mutations` WHERE `mutation_id` = ? FOR UPDATE',
            { mutationId }
        )
        if rows and #rows > 0 then
            local row = rows[1]
            local hashRows = tx('SELECT SHA2(?, 256) AS `h`', { canonical })
            local computed = hashRows and hashRows[1] and hashRows[1].h
            if row.batch_hash ~= computed then
                txOutcome = 'mismatch'
                return false
            end
            if row.status == 'COMMITTED' then
                txOutcome = 'replay'
                replayedResult = row.result and json.decode(row.result) or nil
                return true
            end
            -- PENDING: a prior attempt of this same mutation that did not reach
            -- COMMITTED. Re-apply against the current (re-snapshotted) items.
            txOutcome = 'pending'
            return true
        end
        -- No prior row: record the intent as PENDING. players.inventory is
        -- persisted in tx_2 only after the generation check passes.
        tx(
            'INSERT INTO `czcraft_inventory_mutations` (`mutation_id`, `batch_hash`, `identifier`, `removals`, `additions`, `status`) VALUES (?, SHA2(?, 256), ?, ?, ?, "PENDING")',
            { mutationId, canonical, citizenid, json.encode(removals), json.encode(additions) }
        )
        txOutcome = 'pending'
        return true
    end)

    if not journalOk then
        if txOutcome == 'mismatch' then
            TriggerEvent('qb-log:server:CreateLog', 'playerinventory', 'ApplyIdempotentBatch replay mismatch', 'red',
                '**Player:** ' .. tostring(identifier) .. '\n**Mutation:** ' .. mutationId .. '\n**Reason:** same mutation id submitted with a different payload')
            return { success = false, securityIncident = true }
        end
        return { success = false, reason = 'journal transaction failed' }
    end

    if txOutcome == 'replay' then
        return { success = true, replayed = true, result = replayedResult }
    end

    -- txOutcome == 'pending': synchronous check-then-swap. No yield is allowed
    -- between the generation check and the in-memory swap, otherwise a sync
    -- mutator could slip in and be silently overwritten.
    if (InventoryGeneration[identifier] or 0) ~= savedGen then
        goto retry
    end

    Player.SetPlayerData('items', result.items)
    bumpGeneration(identifier)

    if not Player.Offline and Player(identifier).state.inv_busy then
        TriggerClientEvent('qb-inventory:client:updateInventory', identifier)
    end

    TriggerEvent('qb-log:server:CreateLog', 'playerinventory', 'ApplyIdempotentBatch applied', 'green',
        '**Player:** ' .. tostring(identifier) .. '\n**Mutation:** ' .. mutationId .. '\n**Removals:** ' .. json.encode(removals) .. '\n**Additions:** ' .. json.encode(additions) .. '\n**Reason:** ' .. tostring(reason) .. '\n**Resource:** ' .. caller)

    -- tx_2: atomically persist the new inventory + mark the mutation COMMITTED.
    -- If this fails, the in-memory swap already happened but the DB inventory
    -- and journal remain PENDING. We mark the mutation as persist-pending so a
    -- same-session retry retries only tx_2 (never re-validates/re-swaps). A
    -- cross-session retry re-applies against the original DB inventory safely
    -- (PENDING => DB inventory not yet written).
    local resultMeta = { appliedAt = os.time(), caller = caller, reason = reason }
    local persistOk = MySQL.transaction.await({
        { query = 'UPDATE `players` SET `inventory` = ? WHERE `citizenid` = ?', values = { json.encode(serializeForSave(result.items)), citizenid } },
        { query = 'UPDATE `czcraft_inventory_mutations` SET `status` = ?, `result` = ? WHERE `mutation_id` = ?', values = { 'COMMITTED', json.encode(resultMeta), mutationId } },
    })

    if not persistOk then
        PersistPending[identifier] = PersistPending[identifier] or {}
        PersistPending[identifier][mutationId] = true
        return { success = false, reason = 'persist failed' }
    end

    return { success = true, replayed = false }
end

exports('ApplyIdempotentBatch', ApplyIdempotentBatch)
