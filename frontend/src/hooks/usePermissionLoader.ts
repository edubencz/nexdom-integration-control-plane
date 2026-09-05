import { useEffect, useState } from 'react';
import { useAuth } from '../auth/AuthContext';
import { useAccessControl } from '../contexts/AccessControlContext';
import { fetchProjectPermissions, fetchComponentPermissions } from '../api/auth';

export function useLoadProjectPermissions(orgHandle: string, projectId: string) {
  const { userId } = useAuth();
  const { setProjectPermissions, clearProjectPermissions } = useAccessControl();
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    if (!projectId || !userId) {
      setLoaded(false);
      return;
    }
    setLoaded(false);

    // Clear permissions before loading the new scope. Do not use a ref to skip
    // this request: in React StrictMode an effect is mounted, cleaned up and
    // mounted again. Marking the scope as loaded before the request resolves
    // would cause the second mount to skip the only non-cancelled request.
    clearProjectPermissions();
    let cancelled = false;

    fetchProjectPermissions(orgHandle, userId, projectId)
      .then((data) => { if (!cancelled) { setProjectPermissions(projectId, data.permissionNames); setLoaded(true); } })
      .catch((err) => { if (!cancelled) { console.error('Failed to fetch project permissions', err); setLoaded(true); } });
    return () => { cancelled = true; };
  }, [orgHandle, projectId, userId, setProjectPermissions, clearProjectPermissions]);
  return loaded;
}

export function useLoadComponentPermissions(orgHandle: string, projectId: string, componentId: string) {
  const { userId } = useAuth();
  const { setComponentPermissions, clearComponentPermissions } = useAccessControl();
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    // Early return if any required value is missing
    if (!componentId || !projectId || !userId) {
      setLoaded(false);
      return;
    }
    setLoaded(false);

    // Always start a request for the current scope. In React StrictMode the
    // first effect instance is cancelled and immediately followed by a new
    // one; a pre-populated "loaded" ref would make the second instance return
    // without a request and leave callers waiting forever.
    clearComponentPermissions();
    let cancelled = false;

    fetchComponentPermissions(orgHandle, userId, projectId, componentId)
      .then((data) => { if (!cancelled) { setComponentPermissions(componentId, data.permissionNames); setLoaded(true); } })
      .catch((err) => { if (!cancelled) { console.error('Failed to fetch component permissions', err); setLoaded(true); } });
    return () => { cancelled = true; };
  }, [orgHandle, projectId, componentId, userId, setComponentPermissions, clearComponentPermissions]);
  return loaded;
}
