import type { JSX } from 'react';

export type BadgeVariant = 'success' | 'warning' | 'error' | 'muted' | 'info';

interface StatusBadgeProps {
  status: string;
  variant: BadgeVariant;
  label?: string;
}

export function StatusBadge({ status, variant, label }: StatusBadgeProps): JSX.Element {
  const className = `badge badge--${variant}`;
  return <span className={className}>{label ?? status}</span>;
}
