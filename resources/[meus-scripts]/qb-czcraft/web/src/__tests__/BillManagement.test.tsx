import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { BillManagement } from '../pages/BillManagement';
import type { Bill, Recipe } from '../types';

const fetchMock = vi.fn();
vi.stubGlobal('fetch', fetchMock);

afterEach(() => {
  fetchMock.mockReset();
  cleanup();
});

const RECIPES: Recipe[] = [
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
  {
    id: 'disabled_recipe',
    machine: 'furnace',
    duration: 60,
    enabled: false,
    access: 'all',
    inputs: [],
    outputs: [],
    primaryOutput: 'nothing',
  },
];

function makeBill(overrides: Partial<Bill> = {}): Bill {
  return {
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
    ...overrides,
  };
}

function mockFetchResponse(body: unknown): void {
  fetchMock.mockResolvedValueOnce({
    json: () => Promise.resolve(body),
  });
}

describe('BillManagement — form validation', () => {
  it('shows an error when creating a bill without selecting a recipe', () => {
    render(
      <BillManagement bills={[]} recipes={RECIPES} machineUuid="m1" onBillsChanged={() => {}} />,
    );

    const createButton = screen.getByRole('button', { name: 'Create' });
    fireEvent.click(createButton);

    // The validation sets formError to t('label.recipe') = "Recipe". The same
    // text appears as a form label, so assert on the error-banner element.
    const errorBanner = document.querySelector('.error-banner');
    expect(errorBanner).not.toBeNull();
    expect(errorBanner?.textContent).toBe('Recipe');
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('shows an error when target quantity is less than 1', () => {
    render(
      <BillManagement bills={[]} recipes={RECIPES} machineUuid="m1" onBillsChanged={() => {}} />,
    );

    // Select a recipe first so we get past the recipeId check.
    const recipeSelect = screen.getByLabelText('Recipe');
    fireEvent.change(recipeSelect, { target: { value: 'iron_ingot' } });

    // Set target quantity to 0.
    const targetInput = screen.getByLabelText('Target');
    fireEvent.change(targetInput, { target: { value: '0' } });

    const createButton = screen.getByRole('button', { name: 'Create' });
    fireEvent.click(createButton);

    // The validation sets formError to t('label.target') = "Target". The same
    // text appears as a form label, so assert on the error-banner element.
    const errorBanner = document.querySelector('.error-banner');
    expect(errorBanner).not.toBeNull();
    expect(errorBanner?.textContent).toBe('Target');
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe('BillManagement — block states', () => {
  it('shows Pause and Remove buttons for an ACTIVE bill', () => {
    const bills = [makeBill({ status: 'ACTIVE' })];
    render(
      <BillManagement bills={bills} recipes={RECIPES} machineUuid="m1" onBillsChanged={() => {}} />,
    );

    // The bill card is rendered. Find buttons within the bill card actions.
    const pauseButton = screen.getByText('Pause');
    const removeButton = screen.getByText('Remove');
    expect(pauseButton).toBeInTheDocument();
    expect(removeButton).toBeInTheDocument();
    expect(screen.queryByText('Resume')).not.toBeInTheDocument();
  });

  it('shows Resume and Remove buttons for a PAUSED bill', () => {
    const bills = [makeBill({ status: 'PAUSED' })];
    render(
      <BillManagement bills={bills} recipes={RECIPES} machineUuid="m1" onBillsChanged={() => {}} />,
    );

    expect(screen.getByText('Resume')).toBeInTheDocument();
    expect(screen.getByText('Remove')).toBeInTheDocument();
    expect(screen.queryByText('Pause')).not.toBeInTheDocument();
  });

  it('shows no action buttons for a REMOVED bill', () => {
    const bills = [makeBill({ status: 'REMOVED' })];
    render(
      <BillManagement bills={bills} recipes={RECIPES} machineUuid="m1" onBillsChanged={() => {}} />,
    );

    expect(screen.queryByText('Pause')).not.toBeInTheDocument();
    expect(screen.queryByText('Resume')).not.toBeInTheDocument();
    expect(screen.queryByText('Remove')).not.toBeInTheDocument();
  });

  it('shows only Remove button for a PENDING bill', () => {
    const bills = [makeBill({ status: 'PENDING' })];
    render(
      <BillManagement bills={bills} recipes={RECIPES} machineUuid="m1" onBillsChanged={() => {}} />,
    );

    expect(screen.getByText('Remove')).toBeInTheDocument();
    expect(screen.queryByText('Pause')).not.toBeInTheDocument();
    expect(screen.queryByText('Resume')).not.toBeInTheDocument();
  });

  it('displays the block reason when a bill has one', () => {
    const bills = [makeBill({ status: 'ACTIVE', blockReason: 'missing input stock' })];
    const { container } = render(
      <BillManagement bills={bills} recipes={RECIPES} machineUuid="m1" onBillsChanged={() => {}} />,
    );

    // The block reason label and value should be rendered.
    expect(container.textContent).toContain('Blocked Reason');
    expect(container.textContent).toContain('missing input stock');
  });

  it('renders the no-data message when there are no bills', () => {
    render(
      <BillManagement bills={[]} recipes={RECIPES} machineUuid="m1" onBillsChanged={() => {}} />,
    );

    expect(screen.getByText('No data available')).toBeInTheDocument();
  });
});

describe('BillManagement — permission-denied response', () => {
  it('displays the server reason when createBill returns success: false', async () => {
    mockFetchResponse({ success: false, reason: 'permission denied' });

    render(
      <BillManagement bills={[]} recipes={RECIPES} machineUuid="m1" onBillsChanged={() => {}} />,
    );

    // Select a recipe and click create.
    const recipeSelect = screen.getByLabelText('Recipe');
    fireEvent.change(recipeSelect, { target: { value: 'iron_ingot' } });

    const createButton = screen.getByRole('button', { name: 'Create' });
    fireEvent.click(createButton);

    // Wait for the async fetch + state update to flush.
    const errorBanner = await screen.findByText('permission denied');
    expect(errorBanner).toBeInTheDocument();

    // Verify the request was sent with the expected endpoint.
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url] = fetchMock.mock.calls[0];
    expect(url).toBe('https://qb-czcraft/createBill');
  });

  it('calls onBillsChanged after a successful bill action', async () => {
    mockFetchResponse({ success: true });
    const onBillsChanged = vi.fn();

    const bills = [makeBill({ status: 'ACTIVE' })];
    render(
      <BillManagement bills={bills} recipes={RECIPES} machineUuid="m1" onBillsChanged={onBillsChanged} />,
    );

    const pauseButton = screen.getByText('Pause');
    fireEvent.click(pauseButton);

    // Wait for the async fetch to flush.
    await screen.findByText('Pause');

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe('https://qb-czcraft/pauseBill');
    const body = JSON.parse((init as RequestInit).body as string);
    expect(body).toEqual({ machineUuid: 'm1', billId: 'b1' });
    expect(onBillsChanged).toHaveBeenCalledTimes(1);
  });
});

describe('BillManagement — disabled recipes are not shown', () => {
  it('filters out disabled recipes from the select options', () => {
    render(
      <BillManagement bills={[]} recipes={RECIPES} machineUuid="m1" onBillsChanged={() => {}} />,
    );

    const recipeSelect = screen.getByLabelText('Recipe');
    const options = within(recipeSelect).getAllByRole('option');
    const optionValues = options.map((o) => (o as HTMLOptionElement).value);

    // The placeholder option + iron_ingot, but NOT disabled_recipe.
    expect(optionValues).toContain('iron_ingot');
    expect(optionValues).not.toContain('disabled_recipe');
  });
});
