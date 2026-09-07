-- qb-czcraft Portuguese primary locale (pt-PT)
-- Foundation-facing keys only: startup validation, readiness state, diagnostics,
-- and disabled-feature status. No NUI copy in this milestone.

local Translations = {
    machine = {
        workbench = { name = 'Bancada de Trabalho' },
        refinery = { name = 'Refinaria' },
        fabricator = { name = 'Fabricador' },
        assembly = { name = 'Maquina de Montagem' },
    },
    startup = {
        validationHeading = '[qb-czcraft] Relatorio de validacao no arranque',
        ready = '[qb-czcraft] Recurso pronto. Gameplay permanece desativado na fundacao v0.1.',
        notReady = '[qb-czcraft] Recurso NAO pronto — fail-closed. Nenhuma superficie de gameplay ou mutacao registada.',
        blocker = '[qb-czcraft] Bloqueador: %{path} — %{message}',
        bootstrapError = '[qb-czcraft] Falha inesperada do validador: %{message}',
        schemaBlocked = '[qb-czcraft] Portao de schema: versao aplicada %{applied} atrasada face a exigida %{required}',
        schemaMissing = '[qb-czcraft] Portao de schema: %{reason}',
    },
    diagnostics = {
        missingItem = 'Item QBCore em falta: %{item}',
        unresolvedOverride = 'Override obrigatorio por resolver: %{path}',
        disabledFeature = 'Funcionalidade desativada na fundacao v0.1: %{feature}',
    },
}

if GetConvar('qb_locale', 'en') == 'pt' then
    Lang = Locale:new({
        phrases = Translations,
        warnOnMissing = true,
        fallbackLang = Lang,
    })
end
