import type { JSX } from 'react';
import { t } from '../i18n';
import type { StockRow } from '../types';

interface StockViewProps {
  stock: StockRow[];
}

export function StockView({ stock }: StockViewProps): JSX.Element {
  if (stock.length === 0) {
    return <div className="no-data">{t('state.noData')}</div>;
  }

  return (
    <div className="card">
      <table className="table">
        <thead>
          <tr>
            <th>{t('label.itemName')}</th>
            <th>{t('label.quantity')}</th>
            <th>{t('label.reserved')}</th>
            <th>{t('label.unitCost')}</th>
            <th>{t('label.version')}</th>
          </tr>
        </thead>
        <tbody>
          {stock.map((row) => (
            <tr key={`${row.itemName}:${row.metadataKey}`}>
              <td>{row.itemName}</td>
              <td>{row.quantity}</td>
              <td>{row.reservedQuantity}</td>
              <td>{row.standardUnitCost}</td>
              <td>{row.version}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
