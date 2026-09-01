import { authenticatedFetch } from '../auth/tokenManager';

export type DeploymentPhase = 'QUEUED' | 'VALIDATING' | 'DELETING' | 'VERIFYING_DELETE' | 'UPLOADING' | 'VERIFYING_DEPLOY' | 'SUCCEEDED' | 'FAULTY' | 'FAILED' | 'INDETERMINATE' | 'CANCELLED' | 'SKIPPED_CONFLICT' | 'SKIPPED_INELIGIBLE' | 'STALE_PREFLIGHT';
export interface MiDeploymentTarget { id?: string; targetId?: string; projectId: string; projectName?: string; componentId?: string; componentName?: string; environmentId?: string; environmentName?: string; runtimeId: string; runtimeName?: string; phase: DeploymentPhase; conflict?: boolean; conflictDetected?: boolean; deleteBeforeUpload?: boolean; eligible?: boolean; reason?: string; httpStatus?: number; message?: string; attempt?: number; updatedAt?: string; evidence?: string[]; }
export interface MiDeployment { id: string; orgHandler: string; status: string; artifactName: string; artifactVersion: string; fileName: string; fileSize: number; sha256: string; createdAt: string; updatedAt: string; targets: MiDeploymentTarget[]; summary?: { total: number; succeeded: number; failed: number; pending: number; skipped: number }; }

function base(): string { return window.API_CONFIG.miDeploymentsUrl; }
async function json<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await authenticatedFetch(url, init);
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body?.error?.message || body?.message || `Deployment request failed (${response.status})`);
  return body as T;
}
export function createMiDeployment(orgHandler: string, file: File, idempotencyKey: string) {
  const form = new FormData(); form.append('file', file, file.name); form.append('orgHandler', orgHandler);
  return json<MiDeployment>(`${base()}?orgHandler=${encodeURIComponent(orgHandler)}`, { method: 'POST', headers: { 'Idempotency-Key': idempotencyKey }, body: form });
}
export function startMiPreflight(id: string, projectIds: string[]) { return json<MiDeployment>(`${base()}/${encodeURIComponent(id)}/preflight`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ projectIds }) }); }
export function saveMiTargetDecisions(id: string, decisions: Array<{ targetId: string; deleteBeforeUpload: boolean }>) { return json<MiDeployment>(`${base()}/${encodeURIComponent(id)}/targets`, { method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ decisions }) }); }
export function executeMiDeployment(id: string, productionConfirmation?: string) { return json<MiDeployment>(`${base()}/${encodeURIComponent(id)}/execute`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ productionConfirmation }) }); }
export function cancelMiDeployment(id: string, targetId?: string) {
  return json<MiDeployment>(`${base()}/${encodeURIComponent(id)}/cancel`, {
    method: 'POST',
    ...(targetId ? { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ targetId }) } : {}),
  });
}
export function recheckMiDeployment(id: string, targetId?: string) {
  return json<MiDeployment>(`${base()}/${encodeURIComponent(id)}/recheck`, {
    method: 'POST',
    ...(targetId ? { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ targetId }) } : {}),
  });
}
export function retryMiDeployment(id: string, targetIds: string[]) { return json<MiDeployment>(`${base()}/${encodeURIComponent(id)}/retry`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ targetIds }) }); }
export function getMiDeployment(id: string) { return json<MiDeployment>(`${base()}/${encodeURIComponent(id)}`); }
export function deleteMiDeployment(id: string) { return json<{ deleted: boolean }>(`${base()}/${encodeURIComponent(id)}`, { method: 'DELETE' }); }
export function listMiDeployments(orgHandler: string, limit = 10, offset = 0) { return json<{ items: MiDeployment[]; total: number }>(`${base()}?orgHandler=${encodeURIComponent(orgHandler)}&limit=${limit}&offset=${offset}`); }
