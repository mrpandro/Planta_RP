import { describe, expect, it } from 'vitest';
import { reducer, initialState, type AppState } from '../App';
import type { Bill, MachineData, OwnerOverview, Recipe, StockRow } from '../types';

describe('reducer — initialState', () => {
  it('has the expected default values', () => {
    expect(initialState.page).toBe('overview');
    expect(initialState.machineUuid).toBeNull();
    expect(initialState.loading).toBe(false);
    expect(initialState.error).toBeNull();
    expect(initialState.machineData).toBeNull();
    expect(initialState.stock).toEqual([]);
    expect(initialState.bills).toEqual([]);
    expect(initialState.recipes).toEqual([]);
    expect(initialState.overview).toBeNull();
  });
});

describe('reducer — SET_PAGE', () => {
  it('updates the active page', () => {
    const next = reducer(initialState, { type: 'SET_PAGE', page: 'dashboard' });
    expect(next.page).toBe('dashboard');
  });

  it('does not mutate the original state', () => {
    const next = reducer(initialState, { type: 'SET_PAGE', page: 'stock' });
    expect(initialState.page).toBe('overview');
    expect(next).not.toBe(initialState);
  });
});

describe('reducer — SET_MACHINE', () => {
  it('sets the machine UUID', () => {
    const next = reducer(initialState, { type: 'SET_MACHINE', machineUuid: 'abc-123' });
    expect(next.machineUuid).toBe('abc-123');
  });

  it('clears the machine UUID when null', () => {
    const state: AppState = { ...initialState, machineUuid: 'abc-123' };
    const next = reducer(state, { type: 'SET_MACHINE', machineUuid: null });
    expect(next.machineUuid).toBeNull();
  });
});

describe('reducer — SET_LOADING', () => {
  it('sets loading to true', () => {
    const next = reducer(initialState, { type: 'SET_LOADING', loading: true });
    expect(next.loading).toBe(true);
  });

  it('sets loading to false', () => {
    const state: AppState = { ...initialState, loading: true };
    const next = reducer(state, { type: 'SET_LOADING', loading: false });
    expect(next.loading).toBe(false);
  });
});

describe('reducer — SET_ERROR', () => {
  it('sets an error message', () => {
    const next = reducer(initialState, { type: 'SET_ERROR', error: 'something went wrong' });
    expect(next.error).toBe('something went wrong');
  });

  it('clears the error when null', () => {
    const state: AppState = { ...initialState, error: 'previous error' };
    const next = reducer(state, { type: 'SET_ERROR', error: null });
    expect(next.error).toBeNull();
  });
});

describe('reducer — SET_MACHINE_DATA', () => {
  it('stores machine data', () => {
    const machine: MachineData = {
      machineUuid: 'm1',
      machineType: 'furnace',
      serial: 'S001',
      operationalStatus: 'RUNNING',
      blockedReason: null,
      blockedDetail: null,
      stockCapacity: 1000,
      usedWeight: 100,
      reservedWeight: 50,
      activeBillId: null,
      activeCycleId: null,
      nextDueAt: null,
      ownerType: 'PLAYER',
      ownerId: 'citizen1',
      locationType: 'HOUSE',
      locationId: 'house1',
      version: 1,
    };
    const next = reducer(initialState, { type: 'SET_MACHINE_DATA', machineData: machine });
    expect(next.machineData).toBe(machine);
  });

  it('clears machine data when null', () => {
    const state: AppState = { ...initialState, machineData: {} as MachineData };
    const next = reducer(state, { type: 'SET_MACHINE_DATA', machineData: null });
    expect(next.machineData).toBeNull();
  });
});

describe('reducer — SET_STOCK', () => {
  it('replaces the stock array', () => {
    const stock: StockRow[] = [
      { itemName: 'iron_ingot', metadataKey: '', quantity: 10, reservedQuantity: 0, standardUnitCost: 5, version: 1 },
    ];
    const next = reducer(initialState, { type: 'SET_STOCK', stock });
    expect(next.stock).toBe(stock);
    expect(next.stock).toHaveLength(1);
  });
});

describe('reducer — SET_BILLS', () => {
  it('replaces the bills array', () => {
    const bills: Bill[] = [
      {
        billId: 'b1',
        machineUuid: 'm1',
        recipeId: 'iron_ingot',
        mode: 'PRODUCE_X',
        primaryOutput: 'iron_ingot',
        targetQuantity: 10,
        producedQuantity: 0,
        enabled: true,
        status: 'ACTIVE',
        blockReason: null,
        priority: 'normal',
        version: 1,
      },
    ];
    const next = reducer(initialState, { type: 'SET_BILLS', bills });
    expect(next.bills).toBe(bills);
    expect(next.bills).toHaveLength(1);
  });
});

describe('reducer — SET_RECIPES', () => {
  it('replaces the recipes array', () => {
    const recipes: Recipe[] = [
      {
        id: 'iron_ingot',
        machine: 'furnace',
        duration: 30,
        enabled: true,
        access: 'all',
        inputs: [{ item: 'iron_ore', amount: 2 }],
        outputs: [{ item: 'iron_ingot', amount: 1 }],
        primaryOutput: 'iron_ingot',
      },
    ];
    const next = reducer(initialState, { type: 'SET_RECIPES', recipes });
    expect(next.recipes).toBe(recipes);
    expect(next.recipes).toHaveLength(1);
  });
});

describe('reducer — SET_OVERVIEW', () => {
  it('stores the owner overview', () => {
    const overview: OwnerOverview = {
      machines: [],
      totalMachines: 0,
      activeBills: 0,
      totalStockItems: 0,
    };
    const next = reducer(initialState, { type: 'SET_OVERVIEW', overview });
    expect(next.overview).toBe(overview);
  });

  it('clears the overview when null', () => {
    const state: AppState = { ...initialState, overview: {} as OwnerOverview };
    const next = reducer(state, { type: 'SET_OVERVIEW', overview: null });
    expect(next.overview).toBeNull();
  });
});

describe('reducer — immutability', () => {
  it('preserves untouched fields when setting one field', () => {
    const state: AppState = { ...initialState, stock: [{ itemName: 'x', metadataKey: '', quantity: 1, reservedQuantity: 0, standardUnitCost: 1, version: 1 }] };
    const next = reducer(state, { type: 'SET_PAGE', page: 'bills' });
    expect(next.stock).toBe(state.stock);
    expect(next.machineUuid).toBe(state.machineUuid);
    expect(next.loading).toBe(state.loading);
  });
});
