import type { JSX } from 'react';
import { t } from '../i18n';
import { StatusBadge } from '../components/StatusBadge';
import { operationalStatusVariant, formatWeight } from '../helpers';
import type { MachineData } from '../types';

interface MachineDashboardProps {
  machineData: MachineData | null;
}

export function MachineDashboard({ machineData }: MachineDashboardProps): JSX.Element {
  if (!machineData) {
    return <div className="no-data">{t('state.noData')}</div>;
  }

  const isBlocked = machineData.blockedReason !== null;

  return (
    <div>
      <div className="card">
        <div className="card__title">{t('label.machineType')}: {machineData.machineType}</div>
        <div className="detail-list">
          <span className="detail-list__label">{t('label.serial')}</span>
          <span className="detail-list__value">{machineData.serial}</span>

          <span className="detail-list__label">{t('label.status')}</span>
          <span className="detail-list__value">
            <StatusBadge
              status={machineData.operationalStatus}
              variant={operationalStatusVariant(machineData.operationalStatus)}
              label={t(`machine.status.${machineData.operationalStatus}`)}
            />
          </span>

          {isBlocked && (
            <>
              <span className="detail-list__label">{t('label.blockedReason')}</span>
              <span className="detail-list__value">
                {machineData.blockedReason}
                {machineData.blockedDetail ? ` - ${machineData.blockedDetail}` : ''}
              </span>
            </>
          )}

          <span className="detail-list__label">{t('label.stockCapacity')}</span>
          <span className="detail-list__value">{formatWeight(machineData.stockCapacity)}</span>

          <span className="detail-list__label">{t('label.usedWeight')}</span>
          <span className="detail-list__value">{formatWeight(machineData.usedWeight)}</span>

          <span className="detail-list__label">{t('label.reservedWeight')}</span>
          <span className="detail-list__value">{formatWeight(machineData.reservedWeight)}</span>

          <span className="detail-list__label">{t('label.activeCycle')}</span>
          <span className="detail-list__value">
            {machineData.activeCycleId ?? '--'}
          </span>

          <span className="detail-list__label">{t('label.nextDue')}</span>
          <span className="detail-list__value">
            {machineData.nextDueAt ?? '--'}
          </span>
        </div>
      </div>
    </div>
  );
}
