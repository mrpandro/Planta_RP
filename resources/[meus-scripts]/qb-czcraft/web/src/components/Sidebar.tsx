import type { JSX } from 'react';
import { t } from '../i18n';
import { closeNUI } from '../api';

export type PageId = 'overview' | 'dashboard' | 'stock' | 'bills';

interface SidebarProps {
  currentPage: PageId;
  hasMachine: boolean;
  onNavigate: (page: PageId) => void;
}

interface NavItem {
  id: PageId;
  label: string;
  requiresMachine: boolean;
}

const NAV_ITEMS: NavItem[] = [
  { id: 'overview', label: 'page.overview', requiresMachine: false },
  { id: 'dashboard', label: 'page.dashboard', requiresMachine: true },
  { id: 'stock', label: 'page.stock', requiresMachine: true },
  { id: 'bills', label: 'page.bills', requiresMachine: true },
];

export function Sidebar({ currentPage, hasMachine, onNavigate }: SidebarProps): JSX.Element {
  return (
    <nav className="sidebar">
      <div className="sidebar__title">{t('app.title')}</div>
      <div className="sidebar__nav">
        {NAV_ITEMS.map((item) => {
          const isDisabled = item.requiresMachine && !hasMachine;
          if (isDisabled) {
            return null;
          }
          const isActive = currentPage === item.id;
          return (
            <button
              key={item.id}
              type="button"
              className={`sidebar__link${isActive ? ' sidebar__link--active' : ''}`}
              onClick={() => onNavigate(item.id)}
            >
              {t(item.label)}
            </button>
          );
        })}
      </div>
      <button type="button" className="sidebar__close" onClick={closeNUI}>
        {t('action.close')}
      </button>
    </nav>
  );
}
