fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Planta RP'
description 'qb-czcraft — Dynamic Industry System (v0.1 foundation)'
version '0.1.0'

dependencies {
    'qb-core',
    'qb-inventory',
    'qb-houses',
    'qb-shops',
    'qb-banking',
    'oxmysql',
    'ox_lib',
    'PolyZone',
    'qb-target',
}

shared_scripts {
    '@ox_lib/init.lua',
    '@qb-core/shared/locale.lua',
    'locales/en.lua',
    'locales/pt.lua',
    'shared/constants.lua',
    'config/general.lua',
    'config/machines.lua',
    'config/access.lua',
    'config/plots.lua',
    'config/recipes.lua',
    'shared/recipe_catalog.lua',
    'shared/recipe_snapshot.lua',
    'shared/validation.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/schema_gate.lua',
    'server/bootstrap.lua',
    -- Adapters before domain before repositories before api.
    'server/adapters/qb_core.lua',
    'server/adapters/qb_inventory.lua',
    'server/adapters/qb_houses.lua',
    'server/domain/owners.lua',
    'server/domain/permissions.lua',
    'server/domain/machines.lua',
    'server/domain/storage.lua',
    'server/repositories/machines.lua',
    'server/repositories/operations.lua',
    'server/repositories/audit.lua',
    'server/event_bus.lua',
    'server/api.lua',
}

client_scripts {
    'client/main.lua',
    'client/placement.lua',
    'client/interaction.lua',
    'client/streaming.lua',
}
