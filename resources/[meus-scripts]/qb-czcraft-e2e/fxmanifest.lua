fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'qb-czcraft-e2e'
description 'qb-czcraft v0.1 staging E2E + load-test harness (server-side scenarios)'
version '0.1.0'

server_scripts {
    'server/slo.lua',
    -- Scenario files are loaded by qb-czcraft/server/e2e_runner.lua
    -- via LoadResourceFile. This resource provides the files only;
    -- it does NOT execute scenarios itself (it can't access CZCraft globals).
}
