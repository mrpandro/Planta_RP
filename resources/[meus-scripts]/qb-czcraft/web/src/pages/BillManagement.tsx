import { useState, type JSX } from 'react';
import { t } from '../i18n';
import { StatusBadge } from '../components/StatusBadge';
import { billStatusVariant } from '../helpers';
import { nuiFetch } from '../api';
import type { Bill, BillMode, BillStatus, Recipe } from '../types';

interface BillManagementProps {
  bills: Bill[];
  recipes: Recipe[];
  machineUuid: string;
  onBillsChanged: () => void;
}

interface CreateFormData {
  recipeId: string;
  mode: BillMode;
  targetQuantity: number;
}

const INITIAL_FORM: CreateFormData = {
  recipeId: '',
  mode: 'PRODUCE_X',
  targetQuantity: 1,
};

export function BillManagement({
  bills,
  recipes,
  machineUuid,
  onBillsChanged,
}: BillManagementProps): JSX.Element {
  const [form, setForm] = useState<CreateFormData>(INITIAL_FORM);
  const [submitting, setSubmitting] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);

  const availableRecipes = recipes.filter((r) => r.enabled);

  async function handleCreate(): Promise<void> {
    if (!form.recipeId) {
      setFormError(t('label.recipe'));
      return;
    }
    if (form.targetQuantity < 1) {
      setFormError(t('label.target'));
      return;
    }
    setSubmitting(true);
    setFormError(null);
    try {
      const resp = await nuiFetch('createBill', {
        machineUuid,
        recipeId: form.recipeId,
        mode: form.mode,
        targetQuantity: form.targetQuantity,
      });
      if (resp.success) {
        setForm(INITIAL_FORM);
        onBillsChanged();
      } else {
        setFormError(resp.reason ?? t('state.error'));
      }
    } catch (err) {
      setFormError(err instanceof Error ? err.message : String(err));
    } finally {
      setSubmitting(false);
    }
  }

  async function handleBillAction(
    billId: string,
    action: 'pauseBill' | 'resumeBill' | 'removeBill',
  ): Promise<void> {
    try {
      const resp = await nuiFetch(action, { machineUuid, billId });
      if (resp.success) {
        onBillsChanged();
      }
    } catch {
      // Action failed silently; user can retry via refresh.
    }
  }

  function renderBillActions(bill: Bill): JSX.Element {
    const actions: JSX.Element[] = [];
    if (bill.status === 'ACTIVE') {
      actions.push(
        <button
          key="pause"
          type="button"
          className="btn btn--small btn--warning"
          onClick={() => void handleBillAction(bill.billId, 'pauseBill')}
        >
          {t('action.pause')}
        </button>,
      );
    }
    if (bill.status === 'PAUSED') {
      actions.push(
        <button
          key="resume"
          type="button"
          className="btn btn--small btn--success"
          onClick={() => void handleBillAction(bill.billId, 'resumeBill')}
        >
          {t('action.resume')}
        </button>,
      );
    }
    if (bill.status !== 'REMOVED') {
      actions.push(
        <button
          key="remove"
          type="button"
          className="btn btn--small btn--danger"
          onClick={() => void handleBillAction(bill.billId, 'removeBill')}
        >
          {t('action.remove')}
        </button>,
      );
    }
    return <div className="bill-card__actions">{actions}</div>;
  }

  function renderProgress(bill: Bill): JSX.Element {
    const percent =
      bill.targetQuantity > 0
        ? Math.min(100, (bill.producedQuantity / bill.targetQuantity) * 100)
        : 0;
    return (
      <div className="bill-card__progress">
        <div className="progress-bar">
          <div className="progress-bar__fill" style={{ width: `${percent}%` }} />
        </div>
        <div className="progress-bar__text">
          {t('label.produced')}: {bill.producedQuantity} / {t('label.target')}: {bill.targetQuantity}
        </div>
      </div>
    );
  }

  return (
    <div>
      <div className="card">
        <div className="card__title">{t('action.create')}</div>
        <div className="form">
          <div className="form__row">
            <label className="form__label" htmlFor="bill-recipe">
              {t('label.recipe')}
            </label>
            <select
              id="bill-recipe"
              className="form__select"
              value={form.recipeId}
              onChange={(e) => setForm({ ...form, recipeId: e.target.value })}
            >
              <option value="">--</option>
              {availableRecipes.map((recipe) => (
                <option key={recipe.id} value={recipe.id}>
                  {recipe.id} ({recipe.primaryOutput})
                </option>
              ))}
            </select>
          </div>
          <div className="form__row">
            <label className="form__label" htmlFor="bill-mode">
              {t('label.mode')}
            </label>
            <select
              id="bill-mode"
              className="form__select"
              value={form.mode}
              onChange={(e) =>
                setForm({ ...form, mode: e.target.value as BillMode })
              }
            >
              <option value="PRODUCE_X">{t('bill.mode.PRODUCE_X')}</option>
              <option value="MAINTAIN_X">{t('bill.mode.MAINTAIN_X')}</option>
            </select>
          </div>
          <div className="form__row">
            <label className="form__label" htmlFor="bill-target">
              {t('label.target')}
            </label>
            <input
              id="bill-target"
              className="form__input"
              type="number"
              min={1}
              value={form.targetQuantity}
              onChange={(e) =>
                setForm({ ...form, targetQuantity: Number(e.target.value) })
              }
            />
          </div>
          {formError && (
            <div className="error-banner">
              <span>{formError}</span>
            </div>
          )}
          <div className="form__actions">
            <button
              type="button"
              className="btn"
              disabled={submitting}
              onClick={() => void handleCreate()}
            >
              {t('action.create')}
            </button>
          </div>
        </div>
      </div>

      {bills.length === 0 ? (
        <div className="no-data">{t('state.noData')}</div>
      ) : (
        bills.map((bill) => (
          <div key={bill.billId} className="bill-card">
            <div className="bill-card__header">
              <div>
                <div className="bill-card__title">
                  {t('label.recipe')}: {bill.recipeId}
                </div>
                <div className="machine-row__location">
                  {t('label.primaryOutput')}: {bill.primaryOutput} | {t('label.mode')}: {t(`bill.mode.${bill.mode}`)}
                </div>
              </div>
              <StatusBadge
                status={bill.status}
                variant={billStatusVariant(bill.status as BillStatus)}
                label={t(`bill.status.${bill.status}`)}
              />
            </div>
            {bill.blockReason && (
              <div className="machine-row__location" style={{ color: 'var(--color-error)' }}>
                {t('label.blockedReason')}: {bill.blockReason}
              </div>
            )}
            {renderProgress(bill)}
            {renderBillActions(bill)}
          </div>
        ))
      )}
    </div>
  );
}
