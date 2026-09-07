-- qb-czcraft recipe catalog
-- Exact ordered 15-recipe MVP catalog from recipes-config.md.
-- Ordered list so duplicate IDs can be detected and stable order preserved.
-- 12 CIVIL + 3 ORG_WEAPONS. No legacy qb-crafting recipes.

CZCraft.Config = CZCraft.Config or {}

CZCraft.Config.Recipes = {
    -- Refinery: resources -> processed
    {
        id = 'reclaim_iron',
        machine = CZCraft.MachineType.REFINERY,
        duration = 45,
        enabled = true,
        access = CZCraft.AccessTag.CIVIL,
        inputs = {
            { item = 'metalscrap', amount = 5 },
        },
        outputs = {
            { item = 'iron', amount = 2 },
        },
        primaryOutput = 'iron',
    },
    {
        id = 'smelt_steel',
        machine = CZCraft.MachineType.REFINERY,
        duration = 60,
        enabled = true,
        access = CZCraft.AccessTag.CIVIL,
        inputs = {
            { item = 'iron', amount = 5 },
            { item = 'metalscrap', amount = 2 },
        },
        outputs = {
            { item = 'steel', amount = 2 },
        },
        primaryOutput = 'steel',
    },
    {
        id = 'draw_copper_wire',
        machine = CZCraft.MachineType.REFINERY,
        duration = 45,
        enabled = true,
        access = CZCraft.AccessTag.CIVIL,
        inputs = {
            { item = 'copper', amount = 3 },
        },
        outputs = {
            { item = 'cz_copper_wire', amount = 6 },
        },
        primaryOutput = 'cz_copper_wire',
    },
    {
        id = 'roll_aluminum_sheet',
        machine = CZCraft.MachineType.REFINERY,
        duration = 50,
        enabled = true,
        access = CZCraft.AccessTag.CIVIL,
        inputs = {
            { item = 'aluminum', amount = 4 },
        },
        outputs = {
            { item = 'cz_aluminum_sheet', amount = 2 },
        },
        primaryOutput = 'cz_aluminum_sheet',
    },
    -- Fabricator: processed -> intermediaries
    {
        id = 'make_metal_parts',
        machine = CZCraft.MachineType.FABRICATOR,
        duration = 60,
        enabled = true,
        access = CZCraft.AccessTag.CIVIL,
        inputs = {
            { item = 'steel', amount = 4 },
        },
        outputs = {
            { item = 'cz_metal_parts', amount = 4 },
        },
        primaryOutput = 'cz_metal_parts',
    },
    {
        id = 'make_casing',
        machine = CZCraft.MachineType.FABRICATOR,
        duration = 60,
        enabled = true,
        access = CZCraft.AccessTag.CIVIL,
        inputs = {
            { item = 'cz_aluminum_sheet', amount = 2 },
            { item = 'plastic', amount = 4 },
        },
        outputs = {
            { item = 'cz_casing', amount = 2 },
        },
        primaryOutput = 'cz_casing',
    },
    {
        id = 'make_electronics',
        machine = CZCraft.MachineType.FABRICATOR,
        duration = 75,
        enabled = true,
        access = CZCraft.AccessTag.CIVIL,
        inputs = {
            { item = 'cz_copper_wire', amount = 4 },
            { item = 'plastic', amount = 3 },
        },
        outputs = {
            { item = 'cz_electronics', amount = 2 },
        },
        primaryOutput = 'cz_electronics',
    },
    {
        id = 'make_mechanical_parts',
        machine = CZCraft.MachineType.FABRICATOR,
        duration = 75,
        enabled = true,
        access = CZCraft.AccessTag.CIVIL,
        inputs = {
            { item = 'cz_metal_parts', amount = 3 },
            { item = 'rubber', amount = 2 },
        },
        outputs = {
            { item = 'cz_mechanical_parts', amount = 2 },
        },
        primaryOutput = 'cz_mechanical_parts',
    },
    {
        id = 'make_components',
        machine = CZCraft.MachineType.FABRICATOR,
        duration = 90,
        enabled = true,
        access = CZCraft.AccessTag.CIVIL,
        inputs = {
            { item = 'cz_metal_parts', amount = 2 },
            { item = 'cz_electronics', amount = 1 },
            { item = 'plastic', amount = 2 },
        },
        outputs = {
            { item = 'cz_components', amount = 2 },
        },
        primaryOutput = 'cz_components',
    },
    -- Workbench: basic automatic operations
    {
        id = 'assemble_screwdriverset',
        machine = CZCraft.MachineType.WORKBENCH,
        duration = 120,
        enabled = true,
        access = CZCraft.AccessTag.CIVIL,
        inputs = {
            { item = 'cz_metal_parts', amount = 3 },
            { item = 'plastic', amount = 2 },
        },
        outputs = {
            { item = 'screwdriverset', amount = 1 },
        },
        primaryOutput = 'screwdriverset',
    },
    {
        id = 'assemble_lockpick',
        machine = CZCraft.MachineType.WORKBENCH,
        duration = 75,
        enabled = true,
        access = CZCraft.AccessTag.CIVIL,
        inputs = {
            { item = 'cz_metal_parts', amount = 2 },
        },
        outputs = {
            { item = 'lockpick', amount = 2 },
        },
        primaryOutput = 'lockpick',
    },
    -- Assembly: intermediaries -> finals / ORG weapons
    {
        id = 'assemble_repairkit',
        machine = CZCraft.MachineType.ASSEMBLY,
        duration = 180,
        enabled = true,
        access = CZCraft.AccessTag.CIVIL,
        inputs = {
            { item = 'cz_components', amount = 3 },
            { item = 'cz_mechanical_parts', amount = 2 },
            { item = 'cz_casing', amount = 1 },
        },
        outputs = {
            { item = 'repairkit', amount = 1 },
        },
        primaryOutput = 'repairkit',
    },
    {
        id = 'assemble_pistol_ammo',
        machine = CZCraft.MachineType.ASSEMBLY,
        duration = 150,
        enabled = true,
        access = CZCraft.AccessTag.ORG_WEAPONS,
        inputs = {
            { item = 'cz_copper_wire', amount = 3 },
            { item = 'cz_metal_parts', amount = 2 },
        },
        outputs = {
            { item = 'pistol_ammo', amount = 1 },
        },
        primaryOutput = 'pistol_ammo',
    },
    {
        id = 'assemble_receiver',
        machine = CZCraft.MachineType.ASSEMBLY,
        duration = 240,
        enabled = true,
        access = CZCraft.AccessTag.ORG_WEAPONS,
        inputs = {
            { item = 'steel', amount = 5 },
            { item = 'cz_metal_parts', amount = 4 },
            { item = 'cz_casing', amount = 1 },
        },
        outputs = {
            { item = 'cz_receiver', amount = 1 },
        },
        primaryOutput = 'cz_receiver',
    },
    {
        id = 'assemble_pistol',
        machine = CZCraft.MachineType.ASSEMBLY,
        duration = 600,
        enabled = true,
        access = CZCraft.AccessTag.ORG_WEAPONS,
        inputs = {
            { item = 'cz_receiver', amount = 1 },
            { item = 'cz_components', amount = 3 },
            { item = 'cz_mechanical_parts', amount = 1 },
        },
        outputs = {
            { item = 'weapon_pistol', amount = 1 },
        },
        primaryOutput = 'weapon_pistol',
    },
}
