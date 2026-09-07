type Locale = 'en' | 'pt';

type TranslationMap = Readonly<Record<string, string>>;

const translations: Readonly<Record<Locale, TranslationMap>> = {
  en: {
    'app.title': 'qb-czcraft',
    'page.overview': 'Overview',
    'page.dashboard': 'Dashboard',
    'page.stock': 'Stock',
    'page.bills': 'Bills',
    'machine.status.RUNNING': 'Running',
    'machine.status.STOPPED': 'Stopped',
    'bill.status.PENDING': 'Pending',
    'bill.status.ACTIVE': 'Active',
    'bill.status.PAUSED': 'Paused',
    'bill.status.COMPLETED': 'Completed',
    'bill.status.REMOVED': 'Removed',
    'bill.mode.PRODUCE_X': 'Produce X',
    'bill.mode.MAINTAIN_X': 'Maintain X',
    'action.create': 'Create',
    'action.pause': 'Pause',
    'action.resume': 'Resume',
    'action.remove': 'Remove',
    'action.close': 'Close',
    'action.refresh': 'Refresh',
    'state.loading': 'Loading...',
    'state.error': 'Error',
    'state.noData': 'No data available',
    'label.blockedReason': 'Blocked Reason',
    'label.quantity': 'Quantity',
    'label.reserved': 'Reserved',
    'label.target': 'Target',
    'label.produced': 'Produced',
    'label.recipe': 'Recipe',
    'label.duration': 'Duration',
    'label.inputs': 'Inputs',
    'label.outputs': 'Outputs',
    'label.primaryOutput': 'Primary Output',
    'label.stockCapacity': 'Stock Capacity',
    'label.usedWeight': 'Used Weight',
    'label.reservedWeight': 'Reserved Weight',
    'label.machineType': 'Machine Type',
    'label.serial': 'Serial',
    'label.status': 'Status',
    'label.activeCycle': 'Active Cycle',
    'label.nextDue': 'Next Due',
    'label.totalMachines': 'Total Machines',
    'label.activeBills': 'Active Bills',
    'label.totalStockItems': 'Total Stock Items',
    'label.itemName': 'Item Name',
    'label.unitCost': 'Unit Cost',
    'label.version': 'Version',
    'label.mode': 'Mode',
    'label.priority': 'Priority',
    'label.progress': 'Progress',
    'label.selectMachine': 'Select a machine from the overview',
  },
  pt: {
    'app.title': 'qb-czcraft',
    'page.overview': 'Visao Geral',
    'page.dashboard': 'Painel',
    'page.stock': 'Estoque',
    'page.bills': 'Ordens',
    'machine.status.RUNNING': 'Funcionando',
    'machine.status.STOPPED': 'Parado',
    'bill.status.PENDING': 'Pendente',
    'bill.status.ACTIVE': 'Ativa',
    'bill.status.PAUSED': 'Pausada',
    'bill.status.COMPLETED': 'Concluida',
    'bill.status.REMOVED': 'Removida',
    'bill.mode.PRODUCE_X': 'Produzir X',
    'bill.mode.MAINTAIN_X': 'Manter X',
    'action.create': 'Criar',
    'action.pause': 'Pausar',
    'action.resume': 'Retomar',
    'action.remove': 'Remover',
    'action.close': 'Fechar',
    'action.refresh': 'Atualizar',
    'state.loading': 'Carregando...',
    'state.error': 'Erro',
    'state.noData': 'Sem dados disponiveis',
    'label.blockedReason': 'Motivo de Bloqueio',
    'label.quantity': 'Quantidade',
    'label.reserved': 'Reservado',
    'label.target': 'Meta',
    'label.produced': 'Produzido',
    'label.recipe': 'Receita',
    'label.duration': 'Duracao',
    'label.inputs': 'Entradas',
    'label.outputs': 'Saidas',
    'label.primaryOutput': 'Saida Principal',
    'label.stockCapacity': 'Capacidade de Estoque',
    'label.usedWeight': 'Peso Usado',
    'label.reservedWeight': 'Peso Reservado',
    'label.machineType': 'Tipo de Maquina',
    'label.serial': 'Serial',
    'label.status': 'Status',
    'label.activeCycle': 'Ciclo Ativo',
    'label.nextDue': 'Proximo Vencimento',
    'label.totalMachines': 'Total de Maquinas',
    'label.activeBills': 'Ordens Ativas',
    'label.totalStockItems': 'Total de Itens em Estoque',
    'label.itemName': 'Nome do Item',
    'label.unitCost': 'Custo Unitario',
    'label.version': 'Versao',
    'label.mode': 'Modo',
    'label.priority': 'Prioridade',
    'label.progress': 'Progresso',
    'label.selectMachine': 'Selecione uma maquina na visao geral',
  },
};

function detectLocale(): Locale {
  if (typeof navigator !== 'undefined' && navigator.language) {
    const lang = navigator.language.toLowerCase();
    if (lang.startsWith('pt')) {
      return 'pt';
    }
  }
  return 'en';
}

const currentLocale: Locale = detectLocale();

export function t(key: string): string {
  const map = translations[currentLocale];
  return map[key] ?? translations.en[key] ?? key;
}

export function getLocale(): Locale {
  return currentLocale;
}
