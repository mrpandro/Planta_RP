import type { BillStatus, OperationalStatus } from './types';
import type { BadgeVariant } from './components/StatusBadge';

export function operationalStatusVariant(status: OperationalStatus): BadgeVariant {
  if (status === 'RUNNING') {
    return 'success';
  }
  return 'muted';
}

export function billStatusVariant(status: BillStatus): BadgeVariant {
  switch (status) {
    case 'ACTIVE':
      return 'success';
    case 'PAUSED':
      return 'warning';
    case 'PENDING':
      return 'info';
    case 'COMPLETED':
      return 'muted';
    case 'REMOVED':
      return 'error';
  }
}

export function formatWeight(weight: number): string {
  if (weight >= 1000) {
    return `${(weight / 1000).toFixed(2)} kg`;
  }
  return `${weight} g`;
}

export function formatDuration(seconds: number): string {
  if (seconds < 60) {
    return `${seconds}s`;
  }
  const minutes = Math.floor(seconds / 60);
  const remainingSeconds = seconds % 60;
  if (minutes < 60) {
    return remainingSeconds > 0 ? `${minutes}m ${remainingSeconds}s` : `${minutes}m`;
  }
  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;
  return remainingMinutes > 0 ? `${hours}h ${remainingMinutes}m` : `${hours}h`;
}
