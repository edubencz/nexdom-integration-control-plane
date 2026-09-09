import { authenticatedFetch } from '../auth/tokenManager';

export type DeploymentPhase = 'QUEUED' | 'VALIDATING' | 'DELETING' | 'VERIFYING_DELETE' | 'UPLOADING' | 'VERIFYING_DEPLOY' | 'SUCCEEDED' | 'FAULTY' | 'FAILED' | 'INDETERMINATE' | 'CANCELLED' | 'SKIPPED_CONFLICT' | 'SKIPPED_INELIGIBLE' | 'STALE_PREFLIGHT';
export type DeploymentStatus = 'DRAFT' | 'PREFLIGHT' | 'AWAITING_DECISIONS' | 'READY' | 'RUNNING' | 'CANCELLING' | 'COMPLETED' | 'COMPLETED_WITH_ISSUES' | 'CANCELLED' | 'FAILED';
export interface DeploymentTiming {
  startedAt?: string | null;
  finishedAt?: string | null;
  durationMs?: number | null;
}
export interface MiDeploymentTarget extends DeploymentTiming {
  targetId: string;
  deploymentId: string;
  projectId: string;
  projectName: string;
  componentId: string;
  componentName: string;
  environmentId: string;
  environmentName: string;
  runtimeId: string;
  runtimeName: string;
  phase: DeploymentPhase;
  conflictDetected: boolean;
  deleteBeforeUpload: boolean;
  eligible: boolean;
  production: boolean;
  reason?: string | null;
  httpStatus?: number | null;
  message?: string | null;
  attempt: number;
  updatedAt: string;
  evidence: string[];
}
export interface MiDeploymentSummary extends DeploymentTiming {
  id: string;
  orgHandler: string;
  status: DeploymentStatus;
  artifactName: string;
  artifactVersion: string;
  fileName: string;
  fileSize: number;
  sha256: string;
  createdAt: string;
  updatedAt: string;
  createdBy: string;
  parentDeploymentId?: string | null;
  selectedProjectIds: string[];
  summary: { total: number; succeeded: number; failed: number; indeterminate: number; cancelled: number; pending: number; skipped: number };
}
export interface MiDeployment extends MiDeploymentSummary {
  targets: MiDeploymentTarget[];
  executionError?: string;
}
export interface MiDeploymentEvent {
  eventId: string;
  deploymentId: string;
  targetId?: string | null;
  phase: string;
  message: string;
  createdAt: string;
  reason?: string | null;
  httpStatus?: number | null;
  evidence: string[];
}

function base(): string {
  return window.API_CONFIG.miDeploymentsUrl;
}
async function json<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await authenticatedFetch(url, init);
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body?.error?.message || body?.message || `Deployment request failed (${response.status})`);
  return body as T;
}
export function createMiDeployment(orgHandler: string, file: File, idempotencyKey: string) {
  const form = new FormData();
  form.append('file', file, file.name);
  form.append('orgHandler', orgHandler);
  return json<MiDeployment>(`${base()}?orgHandler=${encodeURIComponent(orgHandler)}`, { method: 'POST', headers: { 'Idempotency-Key': idempotencyKey }, body: form });
}
export function startMiPreflight(id: string, projectIds: string[]) {
  return json<MiDeployment>(`${base()}/${encodeURIComponent(id)}/preflight`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ projectIds }) });
}
export function saveMiTargetDecisions(id: string, decisions: Array<{ targetId: string; deleteBeforeUpload: boolean }>) {
  return json<MiDeployment>(`${base()}/${encodeURIComponent(id)}/targets`, { method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ decisions }) });
}
export function executeMiDeployment(id: string, productionConfirmation?: string) {
  return json<MiDeployment>(`${base()}/${encodeURIComponent(id)}/execute`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ productionConfirmation }) });
}
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
export function retryMiDeployment(id: string, targetIds: string[]) {
  return json<MiDeployment>(`${base()}/${encodeURIComponent(id)}/retry`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ targetIds }) });
}
export function getMiDeployment(id: string, orgHandler: string) {
  return json<MiDeployment>(`${base()}/${encodeURIComponent(id)}?orgHandler=${encodeURIComponent(orgHandler)}`);
}
export function deleteMiDeployment(id: string) {
  return json<{ deleted: boolean }>(`${base()}/${encodeURIComponent(id)}`, { method: 'DELETE' });
}
export function listMiDeployments(orgHandler: string, limit = 10, offset = 0) {
  return json<{ items: MiDeploymentSummary[]; total: number }>(`${base()}?orgHandler=${encodeURIComponent(orgHandler)}&limit=${limit}&offset=${offset}`);
}

export function getMiDeploymentEvents(id: string, orgHandler: string, targetId?: string, limit = 25, offset = 0) {
  const params = new URLSearchParams({ orgHandler, limit: String(limit), offset: String(offset) });
  if (targetId) params.set('targetId', targetId);
  return json<{ items: MiDeploymentEvent[]; total: number }>(`${base()}/${encodeURIComponent(id)}/events?${params}`);
}
