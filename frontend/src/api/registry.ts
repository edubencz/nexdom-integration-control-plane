/**
 * Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
 * Licensed under the Apache License, Version 2.0.
 */
import { authenticatedFetch } from '../auth/tokenManager';
import { miRegistryApiUrl } from '../config/api';

export interface RegistryMutationResponse {
  message?: string;
  [key: string]: unknown;
}

async function registryResponse(response: Response): Promise<RegistryMutationResponse> {
  const raw = await response.text();
  let payload: RegistryMutationResponse = {};
  try {
    payload = raw ? (JSON.parse(raw) as RegistryMutationResponse) : {};
  } catch {
    payload = { message: raw };
  }
  if (!response.ok) {
    const error = payload.error as { message?: string } | undefined;
    throw new Error(error?.message || payload.message || `Registry request failed with HTTP ${response.status}.`);
  }
  return payload;
}

export async function createRegistryResource(componentId: string, environmentId: string, runtimeId: string, path: string, mediaType: string, content: string | Blob, fileName?: string) {
  const isBinary = content instanceof Blob;
  const body = isBinary ? (() => {
    const form = new FormData();
    form.append('file', content, fileName || 'resource');
    return form;
  })() : content;
  const response = await authenticatedFetch(miRegistryApiUrl(componentId, environmentId, runtimeId, 'content', { path, mediaType }), {
    method: 'POST',
    ...(isBinary ? {} : { headers: { 'Content-Type': mediaType || 'text/plain' } }),
    body,
  });
  return registryResponse(response);
}

export async function updateRegistryResource(componentId: string, environmentId: string, runtimeId: string, path: string, mediaType: string, content: string | Blob, fileName?: string) {
  const isBinary = content instanceof Blob;
  const body = isBinary ? (() => {
    const form = new FormData();
    form.append('file', content, fileName || 'resource');
    return form;
  })() : content;
  const response = await authenticatedFetch(miRegistryApiUrl(componentId, environmentId, runtimeId, 'content', { path }), {
    method: 'PUT',
    ...(isBinary ? {} : { headers: { 'Content-Type': mediaType || 'text/plain' } }),
    body,
  });
  return registryResponse(response);
}

export async function deleteRegistryResource(componentId: string, environmentId: string, runtimeId: string, path: string) {
  const response = await authenticatedFetch(miRegistryApiUrl(componentId, environmentId, runtimeId, 'content', { path }), { method: 'DELETE' });
  return registryResponse(response);
}

export async function upsertRegistryProperties(componentId: string, environmentId: string, runtimeId: string, path: string, properties: Array<{ name: string; value: string }>) {
  const response = await authenticatedFetch(miRegistryApiUrl(componentId, environmentId, runtimeId, 'properties', { path }), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(properties),
  });
  return registryResponse(response);
}

export async function deleteRegistryProperty(componentId: string, environmentId: string, runtimeId: string, path: string, name: string) {
  const response = await authenticatedFetch(miRegistryApiUrl(componentId, environmentId, runtimeId, 'properties', { path, name }), { method: 'DELETE' });
  return registryResponse(response);
}

export async function downloadRegistryResource(componentId: string, environmentId: string, runtimeId: string, path: string): Promise<Blob> {
  const response = await authenticatedFetch(miRegistryApiUrl(componentId, environmentId, runtimeId, 'content', { path }));
  if (!response.ok) {
    const payload = await response.json().catch(() => ({})) as { error?: { message?: string } };
    throw new Error(payload.error?.message || `Registry download failed with HTTP ${response.status}.`);
  }
  return response.blob();
}
