import type { JSX } from 'react';

interface ErrorBannerProps {
  message: string;
  onDismiss: () => void;
}

export function ErrorBanner({ message, onDismiss }: ErrorBannerProps): JSX.Element {
  return (
    <div className="error-banner">
      <span>{message}</span>
      <button
        type="button"
        className="error-banner__dismiss"
        onClick={onDismiss}
        aria-label="dismiss error"
      >
        x
      </button>
    </div>
  );
}
