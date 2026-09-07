import { afterEach, describe, expect, it, vi } from 'vitest';
import { nuiFetch, closeNUI } from '../api';
import type { NUIResponse } from '../types';

const fetchMock = vi.fn();

// Install a global fetch mock so tests do not hit the network.
vi.stubGlobal('fetch', fetchMock);

afterEach(() => {
  fetchMock.mockReset();
});

describe('nuiFetch', () => {
  it('posts JSON to the resource endpoint and returns the parsed response', async () => {
    const payload: NUIResponse<{ value: number }> = {
      success: true,
      data: { value: 42 },
    };
    fetchMock.mockResolvedValueOnce({
      json: () => Promise.resolve(payload),
    });

    const result = await nuiFetch<{ value: number }>('getOwnerOverview');

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe('https://qb-czcraft/getOwnerOverview');
    expect(init).toEqual({
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify({}),
    });
    expect(result).toEqual(payload);
    expect(result.success).toBe(true);
    expect(result.data?.value).toBe(42);
  });

  it('sends the provided data object as the request body', async () => {
    fetchMock.mockResolvedValueOnce({
      json: () => Promise.resolve({ success: true }),
    });

    await nuiFetch('createBill', {
      machineUuid: 'abc-123',
      recipeId: 'iron_ingot',
      mode: 'PRODUCE_X',
      targetQuantity: 10,
    });

    const init = fetchMock.mock.calls[0][1] as RequestInit;
    expect(JSON.parse(init.body as string)).toEqual({
      machineUuid: 'abc-123',
      recipeId: 'iron_ingot',
      mode: 'PRODUCE_X',
      targetQuantity: 10,
    });
  });

  it('propagates the failure reason when the response is unsuccessful', async () => {
    fetchMock.mockResolvedValueOnce({
      json: () =>
        Promise.resolve({ success: false, reason: 'machine not found' }),
    });

    const result = await nuiFetch<unknown>('getMachineData', {
      machineUuid: 'missing',
    });

    expect(result.success).toBe(false);
    expect(result.reason).toBe('machine not found');
    expect(result.data).toBeUndefined();
  });
});

describe('closeNUI', () => {
  it('fires a fetch to the close endpoint without throwing', async () => {
    fetchMock.mockResolvedValueOnce({
      json: () => Promise.resolve({ success: true }),
    });

    // closeNUI is fire-and-forget; it should not throw.
    closeNUI();

    // Wait for the microtask queue to flush so the fetch is observed.
    await Promise.resolve();
    await Promise.resolve();

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe('https://qb-czcraft/close');
  });

  it('swallows fetch errors silently', async () => {
    fetchMock.mockRejectedValueOnce(new Error('network down'));

    // Should not throw even when fetch rejects.
    closeNUI();

    await Promise.resolve();
    await Promise.resolve();

    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
});
