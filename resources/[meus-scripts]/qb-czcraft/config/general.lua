-- qb-czcraft general configuration
-- v0.1 foundation: all gameplay flags disabled, fixture caps as pre-gate defaults,
-- and required production overrides represented as explicit unresolved sentinels.

CZCraft.Config = CZCraft.Config or {}

CZCraft.Config.General = {
    resourceName = 'qb-czcraft',
    version = '0.1.0',

    -- v0.1 feature flags. Every gameplay flag is disabled at scaffold time.
    -- The resource loads and validates but registers no mutation surface.
    features = {
        placement = true,
        storageTransfers = false,
        bills = false,
        production = false,
        scheduler = false,
        nui = false,
        repairkit = false,
        admin = false,
    },

    -- Fixture location caps are pre-gate test defaults explicitly called out by the spec.
    -- Production overrides still require review before the v0.1 gate.
    fixtureCaps = {
        HOUSE = 4,
        ORG = 20,
    },

    -- Maximum bills per machine. Pre-gate default; production may override before the v0.1 gate.
    maxBillsPerMachine = 5,
}
