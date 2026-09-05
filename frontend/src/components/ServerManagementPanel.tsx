import {
  Alert, Box, Button, Chip, CircularProgress, Dialog, DialogActions, DialogContent,
  DialogTitle, FormControl, InputLabel, MenuItem, Select, Stack, TextField, Typography,
} from '@wso2/oxygen-ui';
import { RefreshCw, Server, X } from '@wso2/oxygen-ui-icons-react';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { fetchLogFileContent, useRuntimes, type GqlRuntime } from '../api/queries';
import { authenticatedFetch } from '../auth/tokenManager';
import { miServerApiUrl } from '../config/api';
import { useAccessControl } from '../contexts/AccessControlContext';
import { Permissions } from '../constants/permissions';

type ServerAction = 'shutdown' | 'shutdownGracefully' | 'restart' | 'restartGracefully';
type Phase = 'idle' | 'confirm' | 'sending' | 'monitoring' | 'success' | 'pending' | 'error';
type ServerInfo = Record<string, unknown>;
type Operation = {
  action: ServerAction;
  runtimeName: string;
  phase: Phase;
  checks: number;
  httpStatus?: number;
  responseMessage?: string;
  responseBody?: string;
  baselineLog: string;
  logLines: string[];
  logError?: string;
  sawUnavailable: boolean;
  unavailableChecks: number;
  available: boolean;
  error?: string;
};

const MAX_CHECKS = 30;
const CHECK_INTERVAL = 4000;
const ACTION_LABELS: Record<ServerAction, string> = {
  shutdown: 'Shutdown', shutdownGracefully: 'Graceful Shutdown',
  restart: 'Restart', restartGracefully: 'Graceful Restart',
};

function parseResponse(text: string): { value?: ServerInfo; message?: string } {
  try {
    const value = JSON.parse(text) as unknown;
    if (value && typeof value === 'object') {
      const object = value as Record<string, unknown>;
      const message = [object.Message, object.message, (object.error as Record<string, unknown> | undefined)?.message].find((v) => typeof v === 'string');
      return { value: object, message: message as string | undefined };
    }
  } catch { /* response may be plain text */ }
  return { message: text || undefined };
}

function relatedLogLines(content: string, runtimeName: string, action: ServerAction): string[] {
  const tokens = [runtimeName, 'CappDeployer', 'Carbon Application', 'Successfully Deployed', 'shutdown', 'restart', 'started', 'initializ'];
  const lowerName = runtimeName.toLowerCase();
  return content.split(/\r?\n/).filter((line) => {
    const lower = line.toLowerCase();
    return (lower.includes(lowerName) || tokens.slice(1).some((token) => lower.includes(token.toLowerCase()))) &&
      (action.startsWith('shutdown') || action.startsWith('restart') || lower.includes('deploy') || lower.includes('start'));
  }).slice(-20);
}

function displayValue(value: unknown): string {
  if (value === null || value === undefined) return '—';
  if (typeof value === 'object') return JSON.stringify(value, null, 2);
  return String(value);
}

function ServerInfoCard({ info }: { info: ServerInfo }) {
  const groups: Array<[string, string[]]> = [
    ['Product and version', ['productName', 'productVersion']],
    ['Java', ['javaVersion', 'javaVendor', 'javaHome']],
    ['Operating system', ['osName', 'osVersion']],
    ['Runtime directories', ['repositoryLocation', 'workDirectory', 'carbonHome']],
  ];
  const used = new Set(groups.flatMap(([, keys]) => keys));
  return <Stack spacing={1.5} sx={{ mt: 2 }}>
    {groups.map(([title, keys]) => <Box key={title}>
      <Typography variant="subtitle2" sx={{ mb: 0.5 }}>{title}</Typography>
      <Box sx={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: 1 }}>
        {keys.filter((key) => key in info).map((key) => <Box key={key} sx={{ p: 1, bgcolor: 'action.hover', borderRadius: 1 }}>
          <Typography variant="caption" color="text.secondary">{key}</Typography>
          <Typography variant="body2" sx={{ wordBreak: 'break-word' }}>{displayValue(info[key])}</Typography>
        </Box>)}
      </Box>
    </Box>)}
    {Object.keys(info).some((key) => !used.has(key)) && <Box>
      <Typography variant="subtitle2" sx={{ mb: 0.5 }}>Additional fields</Typography>
      <Box sx={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: 1 }}>
        {Object.entries(info).filter(([key]) => !used.has(key)).map(([key, value]) => <Box key={key} sx={{ p: 1, bgcolor: 'action.hover', borderRadius: 1 }}>
          <Typography variant="caption" color="text.secondary">{key}</Typography><Typography variant="body2" sx={{ wordBreak: 'break-word' }}>{displayValue(value)}</Typography>
        </Box>)}
      </Box>
    </Box>}
  </Stack>;
}

export function ServerManagementPanel({ envId, projectId, componentId, runtimes: controlledRuntimes, selectedRuntimeId, canManage }: { envId: string; projectId: string; componentId: string; runtimes?: GqlRuntime[]; selectedRuntimeId?: string; canManage?: boolean }) {
  const { data: fetchedRuntimes = [], isLoading: runtimesLoading, refetch: refetchRuntimes } = useRuntimes(envId, projectId, componentId, !controlledRuntimes);
  const runtimes = controlledRuntimes ?? fetchedRuntimes;
  const miRuntimes = useMemo(() => runtimes.filter((runtime) => runtime.runtimeType.toUpperCase().includes('MI')), [runtimes]);
  const [localRuntimeId, setLocalRuntimeId] = useState('');
  const runtimeId = selectedRuntimeId ?? localRuntimeId;
  const [info, setInfo] = useState<ServerInfo | null>(null);
  const [shutdownConfirmation, setShutdownConfirmation] = useState('');
  const [loading, setLoading] = useState(false);
  const [readError, setReadError] = useState('');
  const [operation, setOperation] = useState<Operation | null>(null);
  const activeRef = useRef(false);
  const { hasAnyPermission } = useAccessControl();
  const effectiveCanManage = canManage ?? hasAnyPermission([Permissions.INTEGRATION_MANAGE], projectId, componentId);

  useEffect(() => {
    if (!runtimeId && miRuntimes.length && !selectedRuntimeId) setLocalRuntimeId((miRuntimes.find((runtime) => runtime.status === 'RUNNING') || miRuntimes[0]).runtimeId);
  }, [miRuntimes, runtimeId, selectedRuntimeId]);
  const selectedRuntime = miRuntimes.find((runtime) => runtime.runtimeId === runtimeId);

  const getServer = useCallback(async (id: string): Promise<{ ok: boolean; status: number; body: string; info?: ServerInfo }> => {
    const response = await authenticatedFetch(miServerApiUrl(componentId, envId, id));
    const body = await response.text();
    const parsed = parseResponse(body);
    return { ok: response.ok, status: response.status, body, info: parsed.value };
  }, [componentId, envId]);

  const refresh = useCallback(async (id = runtimeId) => {
    if (!id || activeRef.current) return;
    setLoading(true); setReadError('');
    try {
      const result = await getServer(id);
      if (!result.ok) throw new Error(`${result.status}: ${parseResponse(result.body).message || result.body || 'Unable to load server information'}`);
      setInfo(result.info || {});
    } catch (error) { setReadError(error instanceof Error ? error.message : 'Unable to load server information'); }
    finally { setLoading(false); }
  }, [getServer, runtimeId]);

  useEffect(() => {
    activeRef.current = false;
    setInfo(null);
    setOperation(null);
    setShutdownConfirmation('');
    setReadError('');
    if (runtimeId) void refresh(runtimeId);
    return () => { activeRef.current = false; };
  }, [runtimeId]); // eslint-disable-line react-hooks/exhaustive-deps

  const updateLog = useCallback(async (current: Operation, id: string): Promise<Partial<Operation>> => {
    try {
      const content = await fetchLogFileContent(id, 'wso2carbon.log');
      return { logLines: relatedLogLines(content.slice(current.baselineLog.length), current.runtimeName, current.action) };
    } catch (error) { return { logError: error instanceof Error ? error.message : 'Unable to read wso2carbon.log' }; }
  }, []);

  const monitor = useCallback(async (initial: Operation, allowImmediate = true) => {
    activeRef.current = true;
    let current = initial;
    for (let check = 1; check <= MAX_CHECKS; check += 1) {
      if (!activeRef.current) return;
      if (!allowImmediate) await new Promise((resolve) => setTimeout(resolve, CHECK_INTERVAL));
      if (!activeRef.current) return;
      allowImmediate = false;
       const runtimeResult = controlledRuntimes ? { data: controlledRuntimes } : await refetchRuntimes();
       const currentRuntime = (runtimeResult.data || []).find((r) => r.runtimeId === runtimeId) || (runtimeResult.data || []).find((r) => r.runtimeName === initial.runtimeName);
      const id = currentRuntime?.runtimeId || runtimeId;
      let result: { ok: boolean; status: number; body: string; info?: ServerInfo } | undefined;
      try { result = await getServer(id); } catch { result = undefined; }
      const available = !!result?.ok;
      const offline = !available || currentRuntime?.status === 'OFFLINE';
      const logUpdate = await updateLog(current, id);
      const sawUnavailable = current.sawUnavailable || offline;
      const unavailableChecks = offline ? current.unavailableChecks + 1 : 0;
      const restartConfirmed = (current.action.startsWith('restart') && available && sawUnavailable) ||
        (current.action.startsWith('restart') && available && (logUpdate.logLines?.length || 0) > 0);
      const shutdownConfirmed = current.action.startsWith('shutdown') && unavailableChecks >= 2;
      const success = restartConfirmed || shutdownConfirmed;
      current = { ...current, checks: check, available, sawUnavailable, unavailableChecks, ...logUpdate,
        ...(result ? { httpStatus: result.status, responseBody: result.body } : {}),
        ...(result?.info ? { } : {}) };
      if (result?.info) setInfo(result.info);
      setOperation({ ...current, phase: success ? 'success' : 'monitoring' });
      if (success) { activeRef.current = false; return; }
    }
    activeRef.current = false;
    setOperation({ ...current, phase: 'pending' });
  }, [controlledRuntimes, getServer, refetchRuntimes, runtimeId, updateLog]);

  const beginAction = useCallback(async (action: ServerAction) => {
    if (!selectedRuntime || activeRef.current) return;
    activeRef.current = true; setOperation({ action, runtimeName: selectedRuntime.runtimeName || selectedRuntime.runtimeId, phase: 'sending', checks: 0, baselineLog: '', logLines: [], sawUnavailable: false, unavailableChecks: 0, available: true });
    let baselineLog = '';
    try { baselineLog = await fetchLogFileContent(selectedRuntime.runtimeId, 'wso2carbon.log'); } catch { /* best effort */ }
    try {
      const response = await authenticatedFetch(miServerApiUrl(componentId, envId, selectedRuntime.runtimeId), { method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ status: action }) });
      const body = await response.text(); const parsed = parseResponse(body);
      const base: Operation = { action, runtimeName: selectedRuntime.runtimeName || selectedRuntime.runtimeId, phase: response.ok ? 'monitoring' : 'error', checks: 0, baselineLog, logLines: [], sawUnavailable: false, unavailableChecks: 0, available: true, httpStatus: response.status, responseMessage: parsed.message, responseBody: body, error: response.ok ? undefined : `HTTP ${response.status}` };
      setOperation(base);
      if (response.ok) await monitor(base); else activeRef.current = false;
    } catch (error) {
      const base: Operation = { action, runtimeName: selectedRuntime.runtimeName || selectedRuntime.runtimeId, phase: 'monitoring', checks: 0, baselineLog, logLines: [], sawUnavailable: false, unavailableChecks: 0, available: false, error: error instanceof Error ? error.message : 'Network error' };
      setOperation(base); await monitor(base);
    }
  }, [componentId, envId, monitor, selectedRuntime]);

  const retryStatus = useCallback(() => { if (operation && !activeRef.current) void monitor({ ...operation, phase: 'monitoring', checks: 0, unavailableChecks: 0 }); }, [monitor, operation]);
  const busy = !!operation && ['sending', 'monitoring'].includes(operation.phase);
  if (runtimesLoading) return <CircularProgress size={24} sx={{ display: 'block', mx: 'auto', py: 4 }} />;
  if (!miRuntimes.length) return <Alert severity="info">No MI runtimes are associated with this environment.</Alert>;
  return <Stack spacing={2}>
    <Stack direction="row" spacing={1} alignItems="center">
       {!selectedRuntimeId && <FormControl size="small" sx={{ minWidth: 280 }}><InputLabel>MI runtime</InputLabel><Select value={runtimeId} label="MI runtime" onChange={(event) => { setLocalRuntimeId(event.target.value); setInfo(null); }} disabled={busy}>{miRuntimes.map((runtime) => <MenuItem key={runtime.runtimeId} value={runtime.runtimeId}>{runtime.runtimeName || runtime.runtimeId} — {runtime.status}</MenuItem>)}</Select></FormControl>}
      <Button startIcon={<RefreshCw size={16} />} onClick={() => void refresh()} disabled={loading || busy}>Refresh</Button>
    </Stack>
    {selectedRuntime && <Typography variant="body2" color="text.secondary">Source runtime: {selectedRuntime.runtimeName || selectedRuntime.runtimeId} <Chip size="small" label={selectedRuntime.status} sx={{ ml: 1 }} /></Typography>}
    {readError && <Alert severity="error">{readError}</Alert>}
    {loading && <CircularProgress size={24} />}
    {info && <ServerInfoCard info={info} />}
    <Stack direction="row" spacing={1} flexWrap="wrap" useFlexGap>
       {effectiveCanManage && <>
         <Button variant="outlined" startIcon={<Server size={15} />} onClick={() => setOperation({ action: 'restartGracefully', runtimeName: selectedRuntime?.runtimeName || runtimeId, phase: 'confirm', checks: 0, baselineLog: '', logLines: [], sawUnavailable: false, unavailableChecks: 0, available: true })} disabled={busy || selectedRuntime?.status !== 'RUNNING'}>Graceful Restart</Button>
         <Button variant="outlined" color="error" startIcon={<Server size={15} />} onClick={() => setOperation({ action: 'restart', runtimeName: selectedRuntime?.runtimeName || runtimeId, phase: 'confirm', checks: 0, baselineLog: '', logLines: [], sawUnavailable: false, unavailableChecks: 0, available: true })} disabled={busy || selectedRuntime?.status !== 'RUNNING'}>Restart</Button>
         <Button variant="text" onClick={() => setOperation({ action: 'shutdownGracefully', runtimeName: selectedRuntime?.runtimeName || runtimeId, phase: 'confirm', checks: 0, baselineLog: '', logLines: [], sawUnavailable: false, unavailableChecks: 0, available: true })} disabled={busy || selectedRuntime?.status !== 'RUNNING'}>Graceful Shutdown</Button>
         <Button variant="text" color="error" onClick={() => setOperation({ action: 'shutdown', runtimeName: selectedRuntime?.runtimeName || runtimeId, phase: 'confirm', checks: 0, baselineLog: '', logLines: [], sawUnavailable: false, unavailableChecks: 0, available: true })} disabled={busy || selectedRuntime?.status !== 'RUNNING'}>Shutdown</Button>
       </>}
    </Stack>
    <Dialog open={!!operation} onClose={() => { if (!busy) setOperation(null); }} maxWidth="md" fullWidth>
      <DialogTitle>{operation?.phase === 'confirm' ? `Confirm ${operation ? ACTION_LABELS[operation.action] : ''}` : operation?.phase === 'success' ? 'Operation completed' : operation?.phase === 'pending' ? 'Confirmation pending' : 'Server operation'}</DialogTitle>
       <DialogContent><Stack spacing={1.5}>
        {operation && <Typography>Runtime: <strong>{operation.runtimeName}</strong> · Action: <strong>{ACTION_LABELS[operation.action]}</strong> · Check: {operation.checks}/{MAX_CHECKS}</Typography>}
         {operation?.phase === 'confirm' && <Typography>Are you sure you want to execute this operation on the MI runtime?</Typography>}
         {operation?.phase === 'confirm' && operation.action.startsWith('shutdown') && <TextField label="Type the runtime name to confirm" value={shutdownConfirmation} onChange={(event) => setShutdownConfirmation(event.target.value)} helperText={`Enter ${operation.runtimeName}`} fullWidth autoFocus />}
        {operation && operation.phase !== 'confirm' && <Alert severity={operation.phase === 'success' ? 'success' : operation.phase === 'error' ? 'error' : operation.phase === 'pending' ? 'warning' : 'info'}>{operation.phase === 'success' ? 'The server operation was confirmed by runtime availability.' : operation.phase === 'pending' ? 'Command accepted, but operation was not confirmed within two minutes.' : operation.error || 'Monitoring runtime availability and logs…'}</Alert>}
        {operation?.httpStatus !== undefined && <Typography variant="body2">HTTP status: {operation.httpStatus}{operation.responseMessage ? ` — ${operation.responseMessage}` : ''}</Typography>}
        {operation?.responseBody && <Box component="pre" sx={{ maxHeight: 140, overflow: 'auto', p: 1, bgcolor: 'action.hover', fontSize: 12 }}>{operation.responseBody}</Box>}
        {operation?.logLines.length ? <Box><Typography variant="subtitle2">Recent related log lines</Typography><Box component="pre" sx={{ maxHeight: 220, overflow: 'auto', p: 1, bgcolor: 'action.hover', fontSize: 11 }}>{operation.logLines.join('\n')}</Box></Box> : null}
        {operation?.logError && <Typography variant="body2" color="text.secondary">Log evidence unavailable: {operation.logError}</Typography>}
      </Stack></DialogContent>
      <DialogActions>
        <Button onClick={() => setOperation(null)} disabled={busy} startIcon={<X size={15} />}>Close</Button>
         {operation?.phase === 'confirm' && <Button variant="contained" color={operation.action.startsWith('shutdown') || operation.action === 'restart' ? 'error' : 'primary'} onClick={() => void beginAction(operation.action)} disabled={operation.action.startsWith('shutdown') && shutdownConfirmation !== operation.runtimeName}>Confirm</Button>}
        {(operation?.phase === 'pending' || operation?.phase === 'error') && <Button variant="contained" onClick={retryStatus} disabled={busy}>Check status</Button>}
      </DialogActions>
    </Dialog>
  </Stack>;
}
