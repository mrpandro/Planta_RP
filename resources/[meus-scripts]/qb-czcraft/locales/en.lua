-- qb-czcraft English fallback locale
-- Foundation-facing keys only: startup validation, readiness state, diagnostics,
-- and disabled-feature status. No NUI copy in this milestone.

local Translations = {
    machine = {
        workbench = { name = 'Workbench' },
        refinery = { name = 'Refinery' },
        fabricator = { name = 'Fabricator' },
        assembly = { name = 'Assembly Machine' },
    },
    startup = {
        validationHeading = '[qb-czcraft] Startup validation report',
        ready = '[qb-czcraft] Resource is ready. Gameplay remains disabled at v0.1 foundation.',
        notReady = '[qb-czcraft] Resource is NOT ready — fail-closed. No gameplay or mutation surface registered.',
        blocker = '[qb-czcraft] Blocker: %{path} — %{message}',
        bootstrapError = '[qb-czcraft] Unexpected validator failure: %{message}',
        schemaBlocked = '[qb-czcraft] Schema gate: applied %{applied} is behind required %{required}',
        schemaMissing = '[qb-czcraft] Schema gate: %{reason}',
    },
    diagnostics = {
        missingItem = 'Missing QBCore item: %{item}',
        unresolvedOverride = 'Required override unresolved: %{path}',
        disabledFeature = 'Feature disabled at v0.1 foundation: %{feature}',
    },
}

Lang = Lang or Locale:new({
    phrases = Translations,
    warnOnMissing = true,
})
