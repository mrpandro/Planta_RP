import type { JSX } from 'react';
import { t } from '../i18n';
import { StatusBadge } from '../components/StatusBadge';
import { operationalStatusVariant } from '../helpers';
import type { OwnerOverview } from '../types';

interface OverviewProps {
  overview: OwnerOverview | null;
  onSelectMachine: (machineUuid: string) => void;
}

export function Overview({ overview, onSelectMachine }: OverviewProps): JSX.Element {
  if (!overview) {
    return <div className="no-data">{t('state.noData')}</div>;
  }

  return (
    <div>
      <div className="stats">
        <div className="stat">
          <div className="stat__label">{t('label.totalMachines')}</div>
          <div className="stat__value">{overview.totalMachines}</div>
        </div>
        <div className="stat">
          <div className="stat__label">{t('label.activeBills')}</div>
          <div className="stat__value">{overview.activeBills}</div>
        </div>
        <div className="stat">
          <div className="stat__label">{t('label.totalStockItems')}</div>
          <div className="stat__value">{overview.totalStockItems}</div>
        </div>
      </div>

      <div className="card">
        <div className="card__title">{t('page.overview')}</div>
        {overview.machines.length === 0 ? (
          <div className="no-data">{t('state.noData')}</div>
        ) : (
          <div className="machine-list">
            {overview.machines.map((machine) => (
              <div
                key={machine.machineUuid}
                className="machine-row"
                onClick={() => onSelectMachine(machine.machineUuid)}
                role="button"
                tabIndex={0}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    onSelectMachine(machine.machineUuid);
                  }
                }}
              >
                <div className="machine-row__info">
                  <span className="machine-row__type">{machine.machineType}</span>
                  <span className="machine-row__location">
                    {machine.locationType} / {machine.locationId}
                  </span>
                </div>
                <StatusBadge
                  status={machine.operationalStatus}
                  variant={operationalStatusVariant(machine.operationalStatus)}
                  label={t(`machine.status.${machine.operationalStatus}`)}
                />
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
