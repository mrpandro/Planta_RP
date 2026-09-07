import type { NUIResponse } from './types';

const RESOURCE_NAME = 'qb-czcraft';

export async function nuiFetch<T>(
  endpoint: string,
  data?: Record<string, unknown>,
): Promise<NUIResponse<T>> {
  const resp = await fetch(`https://${RESOURCE_NAME}/${endpoint}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify(data ?? {}),
  });
  return resp.json() as Promise<NUIResponse<T>>;
}

export function closeNUI(): void {
  // Fire-and-forget: the NUI window is closing regardless of the response.
  nuiFetch('close').catch(() => {});
}
