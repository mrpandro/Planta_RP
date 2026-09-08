import { useCallback, useEffect, useReducer, useState, type JSX } from 'react';
import { Sidebar, type PageId } from './components/Sidebar';
import { ErrorBanner } from './components/ErrorBanner';
import { Loading } from './components/Loading';
import { Overview } from './pages/Overview';
import { MachineDashboard } from './pages/MachineDashboard';
import { StockView } from './pages/StockView';
import { BillManagement } from './pages/BillManagement';
import { nuiFetch } from './api';
import { t } from './i18n';
import type {
  Bill,
  MachineData,
  OwnerOverview,
  Recipe,
  StockRow,
} from './types';

export interface AppState {
  page: PageId;
  machineUuid: string | null;
  loading: boolean;
  error: string | null;
  machineData: MachineData | null;
  stock: StockRow[];
  bills: Bill[];
  recipes: Recipe[];
  overview: OwnerOverview | null;
}

export type AppAction =
  | { type: 'SET_PAGE'; page: PageId }
  | { type: 'SET_MACHINE'; machineUuid: string | null }
  | { type: 'SET_LOADING'; loading: boolean }
  | { type: 'SET_ERROR'; error: string | null }
  | { type: 'SET_MACHINE_DATA'; machineData: MachineData | null }
  | { type: 'SET_STOCK'; stock: StockRow[] }
  | { type: 'SET_BILLS'; bills: Bill[] }
  | { type: 'SET_RECIPES'; recipes: Recipe[] }
  | { type: 'SET_OVERVIEW'; overview: OwnerOverview | null };

export const initialState: AppState = {
  page: 'overview',
  machineUuid: null,
  loading: false,
  error: null,
  machineData: null,
  stock: [],
  bills: [],
  recipes: [],
  overview: null,
};

export function reducer(state: AppState, action: AppAction): AppState {
  switch (action.type) {
    case 'SET_PAGE':
      return { ...state, page: action.page };
    case 'SET_MACHINE':
      return { ...state, machineUuid: action.machineUuid };
    case 'SET_LOADING':
      return { ...state, loading: action.loading };
    case 'SET_ERROR':
      return { ...state, error: action.error };
    case 'SET_MACHINE_DATA':
      return { ...state, machineData: action.machineData };
    case 'SET_STOCK':
      return { ...state, stock: action.stock };
    case 'SET_BILLS':
      return { ...state, bills: action.bills };
    case 'SET_RECIPES':
      return { ...state, recipes: action.recipes };
    case 'SET_OVERVIEW':
      return { ...state, overview: action.overview };
  }
}

export default function App(): JSX.Element | null {
  const [state, dispatch] = useReducer(reducer, initialState);
  const [visible, setVisible] = useState(false);

  // Listen for open/close NUI messages from the client Lua.
  // The NUI frame is always loaded; it must stay hidden until the
  // client sends { action: 'open' } and hide again on { action: 'close' }.
  useEffect(() => {
    const handler = (event: MessageEvent): void => {
      const data = event.data;
      if (!data || typeof data.action !== 'string') return;
      if (data.action === 'open') {
        setVisible(true);
        if (typeof data.machineUuid === 'string') {
          dispatch({ type: 'SET_MACHINE', machineUuid: data.machineUuid });
        }
      } else if (data.action === 'close') {
        setVisible(false);
      }
    };
    window.addEventListener('message', handler);
    return () => window.removeEventListener('message', handler);
  }, []);

  const fetchOverview = useCallback(async (): Promise<void> => {
    dispatch({ type: 'SET_LOADING', loading: true });
    dispatch({ type: 'SET_ERROR', error: null });
    try {
      const resp = await nuiFetch<OwnerOverview>('getOwnerOverview');
      if (resp.success && resp.data) {
        dispatch({ type: 'SET_OVERVIEW', overview: resp.data });
      } else {
        dispatch({ type: 'SET_ERROR', error: resp.reason ?? t('state.error') });
      }
    } catch (err) {
      dispatch({
        type: 'SET_ERROR',
        error: err instanceof Error ? err.message : String(err),
      });
    } finally {
      dispatch({ type: 'SET_LOADING', loading: false });
    }
  }, []);

  const fetchMachineData = useCallback(async (uuid: string): Promise<void> => {
    dispatch({ type: 'SET_LOADING', loading: true });
    dispatch({ type: 'SET_ERROR', error: null });
    try {
      const resp = await nuiFetch<MachineData>('getMachineData', { machineUuid: uuid });
      if (resp.success && resp.data) {
        dispatch({ type: 'SET_MACHINE_DATA', machineData: resp.data });
      } else {
        dispatch({ type: 'SET_ERROR', error: resp.reason ?? t('state.error') });
      }
    } catch (err) {
      dispatch({
        type: 'SET_ERROR',
        error: err instanceof Error ? err.message : String(err),
      });
    } finally {
      dispatch({ type: 'SET_LOADING', loading: false });
    }
  }, []);

  const fetchStock = useCallback(async (uuid: string): Promise<void> => {
    try {
      const resp = await nuiFetch<StockRow[]>('getStock', { machineUuid: uuid });
      if (resp.success && resp.data) {
        dispatch({ type: 'SET_STOCK', stock: resp.data });
      }
    } catch {
      // Stock fetch is non-critical; leave existing stock unchanged.
    }
  }, []);

  const fetchBills = useCallback(async (uuid: string): Promise<void> => {
    try {
      const resp = await nuiFetch<Bill[]>('getBills', { machineUuid: uuid });
      if (resp.success && resp.data) {
        dispatch({ type: 'SET_BILLS', bills: resp.data });
      }
    } catch {
      // Bill fetch is non-critical; leave existing bills unchanged.
    }
  }, []);

  const fetchRecipes = useCallback(async (uuid: string): Promise<void> => {
    try {
      const resp = await nuiFetch<Recipe[]>('getRecipes', { machineUuid: uuid });
      if (resp.success && resp.data) {
        dispatch({ type: 'SET_RECIPES', recipes: resp.data });
      }
    } catch {
      // Recipe fetch is non-critical; leave existing recipes unchanged.
    }
  }, []);

  const fetchAllMachineData = useCallback(
    async (uuid: string): Promise<void> => {
      await Promise.all([
        fetchMachineData(uuid),
        fetchStock(uuid),
        fetchBills(uuid),
        fetchRecipes(uuid),
      ]);
    },
    [fetchMachineData, fetchStock, fetchBills, fetchRecipes],
  );

  // Only fetch owner overview when the NUI becomes visible.
  useEffect(() => {
    if (visible) {
      void fetchOverview();
    }
  }, [visible, fetchOverview]);

  // When machineUuid is set: fetch machine data, stock, bills, recipes
  useEffect(() => {
    if (state.machineUuid) {
      void fetchAllMachineData(state.machineUuid);
    }
  }, [state.machineUuid, fetchAllMachineData]);

  const handleSelectMachine = useCallback((machineUuid: string): void => {
    dispatch({ type: 'SET_MACHINE', machineUuid });
    dispatch({ type: 'SET_PAGE', page: 'dashboard' });
  }, []);

  const handleNavigate = useCallback((page: PageId): void => {
    dispatch({ type: 'SET_PAGE', page });
  }, []);

  const handleRefresh = useCallback((): void => {
    if (state.page === 'overview') {
      void fetchOverview();
    } else if (state.machineUuid) {
      void fetchAllMachineData(state.machineUuid);
    }
  }, [state.page, state.machineUuid, fetchOverview, fetchAllMachineData]);

  const handleDismissError = useCallback((): void => {
    dispatch({ type: 'SET_ERROR', error: null });
  }, []);

  const hasMachine = state.machineUuid !== null;

  if (!visible) {
    return null;
  }

  function renderPage(): JSX.Element {
    switch (state.page) {
      case 'overview':
        return (
          <Overview
            overview={state.overview}
            onSelectMachine={handleSelectMachine}
          />
        );
      case 'dashboard':
        if (!hasMachine) {
          return <div className="empty-hint">{t('label.selectMachine')}</div>;
        }
        return <MachineDashboard machineData={state.machineData} />;
      case 'stock':
        if (!hasMachine) {
          return <div className="empty-hint">{t('label.selectMachine')}</div>;
        }
        return <StockView stock={state.stock} />;
      case 'bills': {
        const uuid = state.machineUuid;
        if (uuid === null) {
          return <div className="empty-hint">{t('label.selectMachine')}</div>;
        }
        return (
          <BillManagement
            bills={state.bills}
            recipes={state.recipes}
            machineUuid={uuid}
            onBillsChanged={() => {
              void fetchBills(uuid);
            }}
          />
        );
      }
    }
  }

  return (
    <div className="app-shell">
      <Sidebar
        currentPage={state.page}
        hasMachine={hasMachine}
        onNavigate={handleNavigate}
      />
      <main className="main">
        <div className="main__header">
          <h1 className="main__title">{t(`page.${state.page}`)}</h1>
          <button type="button" className="btn btn--small" onClick={handleRefresh}>
            {t('action.refresh')}
          </button>
        </div>
        {state.error && (
          <ErrorBanner message={state.error} onDismiss={handleDismissError} />
        )}
        {state.loading ? <Loading /> : renderPage()}
      </main>
    </div>
  );
}
