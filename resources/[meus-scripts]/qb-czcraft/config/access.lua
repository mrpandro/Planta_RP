-- qb-czcraft access configuration
-- Owner/permission vocabulary, empty deny-all grade grant maps, and the documented
-- ORG_WEAPONS organization allow-list. The allow-list establishes catalog eligibility
-- only; no grade receives operational permissions until the owner/access policy task
-- supplies reviewed mappings.

CZCraft.Config = CZCraft.Config or {}

CZCraft.Config.Access = {
    -- Owner types accepted by the access system.
    ownerTypes = {
        CZCraft.OwnerType.PLAYER,
        CZCraft.OwnerType.JOB,
        CZCraft.OwnerType.GANG,
    },

    -- The six industrial permissions. Grade grants map to these keys.
    permissions = {
        CZCraft.Permission.OWNER,
        CZCraft.Permission.MANAGER,
        CZCraft.Permission.PRODUCTION,
        CZCraft.Permission.WITHDRAW,
        CZCraft.Permission.DEPOSIT,
        CZCraft.Permission.VIEW,
    },

    -- Grade-to-permission grants for jobs. Empty = deny-all at scaffold time.
    -- Reviewed mappings are supplied by the owner/access policy task.
    jobGrades = {},

    -- Grade-to-permission grants for gangs. Empty = deny-all at scaffold time.
    gangGrades = {},

    -- Access tags and their organization allow-lists.
    -- ORG_WEAPONS allows job police and the documented gangs; this does not itself
    -- grant any of the six permissions — it only establishes recipe eligibility.
    tags = {
        CIVIL = {
            jobs = {},
            gangs = {},
        },
        ORG_WEAPONS = {
            jobs = { 'police' },
            gangs = { 'lostmc', 'ballas', 'vagos', 'cartel', 'families', 'triads' },
        },
    },
}
