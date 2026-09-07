import type { JSX } from 'react';
import { t } from '../i18n';

export function Loading(): JSX.Element {
  return <div className="loading">{t('state.loading')}</div>;
}
