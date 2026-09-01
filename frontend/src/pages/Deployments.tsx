import { Alert, Box, Button, Checkbox, Chip, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, Divider, FormControlLabel, IconButton, LinearProgress, ListingTable, PageContent, PageTitle, Stack, TablePagination, TextField, Tooltip, Typography } from '@wso2/oxygen-ui';
import { ArrowLeft, CheckCircle2, FileText, RefreshCw, Trash2, Upload, XCircle } from '@wso2/oxygen-ui-icons-react';
import { useCallback, useEffect, useMemo, useRef, useState, type JSX } from 'react';
import type { OrgScope } from '../nav';
import { useAccessControl } from '../contexts/AccessControlContext';
import { Permissions } from '../constants/permissions';
import { useProjects } from '../api/queries';
import { cancelMiDeployment, createMiDeployment, deleteMiDeployment, executeMiDeployment, getMiDeployment, listMiDeployments, recheckMiDeployment, retryMiDeployment, saveMiTargetDecisions, startMiPreflight, type MiDeployment } from '../api/miDeployments';
import { LogFilesDrawer } from '../components/LogFilesDrawer';

const terminal = new Set(['COMPLETED', 'COMPLETED_WITH_ISSUES', 'CANCELLED', 'FAILED']);
export default function Deployments({ org }: OrgScope): JSX.Element {
  const { hasOrgPermission, isOrgPermissionsLoaded } = useAccessControl();
  const canManage = hasOrgPermission(Permissions.DEPLOYMENT_MANAGE);
  const [operation, setOperation] = useState<MiDeployment | null>(null);
  const [history, setHistory] = useState<MiDeployment[]>([]);
  const [historyPage, setHistoryPage] = useState(0);
  const [historyRowsPerPage, setHistoryRowsPerPage] = useState(10);
  const [historyTotal, setHistoryTotal] = useState(0);
  const [step, setStep] = useState(0);
  const [file, setFile] = useState<File | null>(null);
  const [selectedProjects, setSelectedProjects] = useState<string[]>([]);
  const [projectSearch, setProjectSearch] = useState('');
  const [productionConfirmation, setProductionConfirmation] = useState('');
  const [targetDecisions, setTargetDecisions] = useState<Record<string, boolean>>({});
  const [busy, setBusy] = useState(false);
  const [executing, setExecuting] = useState(false);
  const [autoChecking, setAutoChecking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [targetFilter, setTargetFilter] = useState('');
  const [pendingDelete, setPendingDelete] = useState<MiDeployment | null>(null);
  const autoRecheckAttempts = useRef(0);
  const { data: projects = [], isLoading: projectsLoading } = useProjects();

  const loadHistory = useCallback(async () => {
    try {
      const result = await listMiDeployments(org, historyRowsPerPage, historyPage * historyRowsPerPage);
      setHistory(Array.from(new Map(result.items.filter((item) => item.id).map((item) => [item.id, item])).values()));
      setHistoryTotal(result.total);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Unable to load deployment history.');
    }
  }, [historyPage, historyRowsPerPage, org]);
  useEffect(() => {
    if (canManage || hasOrgPermission(Permissions.DEPLOYMENT_VIEW)) void loadHistory();
  }, [canManage, hasOrgPermission, loadHistory]);
  useEffect(() => {
    if (!operation) return;
    const hasIndeterminate = operation.targets.some((target) => target.phase === 'INDETERMINATE');
    // Keep observing running operations and unresolved targets. Terminal operations
    // without indeterminate targets do not need background traffic.
    if (terminal.has(operation.status) && !hasIndeterminate) return;
    const timer = window.setInterval(async () => {
      try {
        const fresh = await getMiDeployment(operation.id);
        setOperation(fresh);
        const unresolved = fresh.targets.some((target) => target.phase === 'INDETERMINATE');
        if (unresolved && fresh.status === 'COMPLETED_WITH_ISSUES' && autoRecheckAttempts.current < 10) {
          autoRecheckAttempts.current += 1;
          setAutoChecking(true);
          setOperation(await recheckMiDeployment(fresh.id));
        } else if (unresolved && autoRecheckAttempts.current >= 10) {
          setAutoChecking(false);
          window.clearInterval(timer);
        } else if (!unresolved) {
          setAutoChecking(false);
        }
      } catch {
        /* polling is best effort; the last known state remains visible */
      }
    }, 3000);
    return () => window.clearInterval(timer);
  }, [operation?.id, operation?.status]);
  useEffect(() => {
    autoRecheckAttempts.current = 0;
    setAutoChecking(false);
  }, [operation?.id]);
  useEffect(() => {
    if (operation?.status === 'COMPLETED_WITH_ISSUES' && operation.targets.some((target) => target.phase === 'INDETERMINATE') && autoRecheckAttempts.current < 10) {
      setAutoChecking(true);
    }
  }, [operation?.status, operation?.targets]);
  useEffect(() => {
    if (!operation || operation.targets.length === 0) return;
    const pending = operation.targets.some((target) => ['QUEUED', 'VALIDATING', 'DELETING', 'VERIFYING_DELETE', 'UPLOADING', 'VERIFYING_DEPLOY'].includes(target.phase));
    const issues = operation.targets.some((target) => ['FAILED', 'FAULTY', 'INDETERMINATE'].includes(target.phase));
    if (!pending && !issues && (operation.status === 'RUNNING' || operation.status === 'COMPLETED_WITH_ISSUES')) {
      setOperation({ ...operation, status: 'COMPLETED' });
    }
  }, [operation?.status, operation?.targets]);
  const toggleProject = (id: string) => setSelectedProjects((current) => (current.includes(id) ? current.filter((item) => item !== id) : [...current, id]));
  const run = async (action: () => Promise<MiDeployment>, nextStep?: number) => {
    setBusy(true);
    setError(null);
    try {
      setOperation(await action());
      if (nextStep !== undefined) setStep(nextStep);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Deployment request failed.');
    } finally {
      setBusy(false);
    }
  };
  const cancelAndReset = async () => {
    if (!operation) {
      reset();
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await cancelMiDeployment(operation.id);
      reset();
      await loadHistory();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Unable to cancel deployment.');
    } finally {
      setBusy(false);
    }
  };
  const confirmDelete = async () => {
    if (!pendingDelete) return;
    setBusy(true);
    try {
      await deleteMiDeployment(pendingDelete.id);
      setPendingDelete(null);
      await loadHistory();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Unable to delete deployment.');
    } finally {
      setBusy(false);
    }
  };
  const reset = () => {
    setExecuting(false);
    setAutoChecking(false);
    autoRecheckAttempts.current = 0;
    setOperation(null);
    setFile(null);
    setSelectedProjects([]);
    setProjectSearch('');
    setProductionConfirmation('');
    setTargetDecisions({});
    setStep(0);
  };
  const stepForOperation = (item: MiDeployment): number => {
    if (item.status === 'DRAFT' || item.status === 'PREFLIGHT') return 0;
    if (item.status === 'AWAITING_DECISIONS') return 2;
    if (item.status === 'READY') return 3;
    return 3;
  };
  const decisions = useMemo(() => operation?.targets.filter((target) => target.conflict || target.conflictDetected) ?? [], [operation]);
  const filteredProjects = useMemo(() => {
    const query = projectSearch.trim().toLowerCase();
    return projects.filter((project) => !query || `${project.name} ${project.handler}`.toLowerCase().includes(query));
  }, [projectSearch, projects]);
  const projectNames = useMemo(() => Object.fromEntries(projects.map((project) => [project.id, project.name])), [projects]);
  if (isOrgPermissionsLoaded && !hasOrgPermission(Permissions.DEPLOYMENT_VIEW) && !canManage) return <></>;
  return (
    <PageContent>
      <PageTitle>
        <PageTitle.Header>Deployments</PageTitle.Header>
      </PageTitle>
      {error && (
        <Alert severity="error" sx={{ mb: 2 }}>
          {error}
        </Alert>
      )}
      {!operation && canManage && (
        <Stack gap={2}>
          <Box sx={{ border: '1px dashed', borderColor: 'divider', borderRadius: 1, p: 4, textAlign: 'center' }}>
            <Upload size={28} />
            <Typography variant="h6" sx={{ mt: 1 }}>
              Deploy a Carbon Application
            </Typography>
            <Typography color="text.secondary">Upload one .CAR to selected projects and their MI runtimes.</Typography>
            {!file && <Button component="label" variant="contained" sx={{ mt: 2 }} startIcon={<Upload size={16} />}>
              Choose .CAR
              <input
                hidden
                type="file"
                accept=".car,application/octet-stream"
                onChange={(e) => {
                  const picked = e.target.files?.[0];
                  if (picked) {
                    setFile(picked);
                    setStep(0);
                  }
                }}
              />
            </Button>}
            {file && (<>
              <Box sx={{ mt: 2, mx: 'auto', maxWidth: 620, textAlign: 'left', border: '1px solid', borderColor: 'divider', borderRadius: 2, p: 2, bgcolor: 'background.paper' }}>
                <Stack direction="row" gap={1.5} alignItems="center"><Box sx={{ width: 44, height: 44, borderRadius: 1.5, display: 'grid', placeItems: 'center', bgcolor: 'action.selected' }}><Upload size={21} /></Box><Box sx={{ minWidth: 0, flex: 1 }}><Typography variant="subtitle1" noWrap>{file.name}</Typography><Typography variant="caption" color="text.secondary">Carbon Application archive</Typography></Box><Chip label="Ready" color="success" size="small" /></Stack>
                <Box sx={{ display: 'grid', gridTemplateColumns: { xs: '1fr', sm: '1fr 1fr 1fr' }, gap: 1.5, mt: 2 }}><Box><Typography variant="caption" color="text.secondary">Format</Typography><Typography variant="body2">.CAR / ZIP</Typography></Box><Box><Typography variant="caption" color="text.secondary">Size</Typography><Typography variant="body2">{(file.size / 1024 / 1024).toFixed(2)} MB</Typography></Box><Box><Typography variant="caption" color="text.secondary">Modified</Typography><Typography variant="body2">{file.lastModified ? new Date(file.lastModified).toLocaleString() : '—'}</Typography></Box></Box>
              </Box>
              <Box sx={{ mt: 2 }}>
                <Typography variant="body2" sx={{ display: 'none' }}>
                  {file.name} · {(file.size / 1024 / 1024).toFixed(2)} MB
                </Typography>
                <Button variant="contained" sx={{ mt: 1 }} disabled={busy} onClick={() => void run(() => createMiDeployment(org, file, crypto.randomUUID()))}>
                  Upload and inspect
                </Button>
                <Button variant="text" color="inherit" sx={{ mt: 1, ml: 1 }} disabled={busy} onClick={() => setFile(null)}>
                  Remove file
                </Button>
              </Box>
            </>)}
          </Box>
        </Stack>
      )}
      {operation && (
        <Stack gap={2}>
          <Stack direction={{ xs: 'column', sm: 'row' }} gap={1.5} alignItems={{ xs: 'stretch', sm: 'center' }} sx={{ pb: 1.5, borderBottom: '1px solid', borderColor: 'divider' }}>
            <Chip label={`Step ${Math.min(step + 1, 4)} of 4`} color="primary" />
            <Typography variant="body2" color="text.secondary">
              {operation.fileName} · {operation.artifactName} {operation.artifactVersion}
            </Typography>
            <Box sx={{ flex: 1 }} />
            {step < 3 && (
              <Button variant="outlined" color="inherit" onClick={() => void cancelAndReset()} disabled={busy}>
                Cancel
              </Button>
            )}
            <Button
              variant="text"
              startIcon={<ArrowLeft size={16} />}
              onClick={() => {
                reset();
                void loadHistory();
              }}
              disabled={busy}>
              Back to deployments
            </Button>
          </Stack>
          {step === 0 && (
            <Box>
              <Typography variant="h6">1. Confirm artifact</Typography>
              <Box sx={{ border: '1px solid', borderColor: 'divider', borderRadius: 2, p: 2.5, maxWidth: 760, bgcolor: 'background.paper' }}>
                <Stack direction="row" gap={1.5} alignItems="center" sx={{ mb: 2 }}>
                  <Box sx={{ width: 42, height: 42, borderRadius: 1.5, display: 'grid', placeItems: 'center', bgcolor: 'action.selected' }}><Upload size={21} /></Box>
                  <Box sx={{ minWidth: 0, flex: 1 }}><Typography variant="subtitle1" noWrap>{operation.fileName}</Typography><Typography variant="caption" color="text.secondary">Carbon Application package (.CAR)</Typography></Box>
                  <Chip label={operation.status} size="small" />
                </Stack>
                <Box sx={{ display: 'grid', gridTemplateColumns: { xs: '1fr', sm: '1fr 1fr' }, gap: 1.5 }}>
                  <Box><Typography variant="caption" color="text.secondary">Application</Typography><Typography variant="body2">{operation.artifactName || 'Not available'}</Typography></Box>
                  <Box><Typography variant="caption" color="text.secondary">Version</Typography><Typography variant="body2">{operation.artifactVersion || 'Not available'}</Typography></Box>
                  <Box><Typography variant="caption" color="text.secondary">File size</Typography><Typography variant="body2">{(operation.fileSize / 1024 / 1024).toFixed(2)} MB</Typography></Box>
                  <Box><Typography variant="caption" color="text.secondary">SHA-256</Typography><Typography variant="body2" sx={{ wordBreak: 'break-all', fontFamily: 'monospace' }}>{operation.sha256 || 'Not available'}</Typography></Box>
                  <Box><Typography variant="caption" color="text.secondary">Uploaded</Typography><Typography variant="body2">{operation.createdAt ? new Date(operation.createdAt).toLocaleString() : 'Not available'}</Typography></Box>
                </Box>
              </Box>
              <Button sx={{ mt: 2 }} variant="contained" disabled={busy} onClick={() => setStep(1)}>
                Continue to projects
              </Button>
            </Box>
          )}
          {step === 1 && (
            <Box>
              <Typography variant="h6">2. Select projects</Typography>
              <Typography color="text.secondary" sx={{ mb: 1 }}>
                {selectedProjects.length} of {projects.length} projects selected
              </Typography>
              <TextField fullWidth size="small" placeholder="Search projects by name or handler" value={projectSearch} onChange={(event) => setProjectSearch(event.target.value)} sx={{ mb: 1.5 }} />
              {projectsLoading ? (
                <CircularProgress />
              ) : (
                <Stack gap={1.25} sx={{ maxHeight: 360, overflowY: 'auto', pr: 0.5, py: 0.5 }}>
                  {filteredProjects.map((project) => (
                    <Box key={project.id} sx={{ border: '1px solid', borderColor: selectedProjects.includes(project.id) ? 'primary.main' : 'divider', borderRadius: 1.5, px: 1.5, py: 1.1, bgcolor: selectedProjects.includes(project.id) ? 'action.selected' : 'transparent' }}>
                      <FormControlLabel sx={{ width: '100%', m: 0, alignItems: 'flex-start' }} control={<Checkbox sx={{ mt: -0.5 }} checked={selectedProjects.includes(project.id)} onChange={() => toggleProject(project.id)} />} label={<Box sx={{ minWidth: 0 }}>
                        <Stack direction="row" gap={1} alignItems="center" flexWrap="wrap">
                          <Typography variant="body2" fontWeight={600}>{project.name}</Typography>
                          {project.type && <Chip size="small" variant="outlined" label={project.type} />}
                        </Stack>
                        <Typography variant="caption" color="text.secondary" display="block">{project.handler}{project.region ? ` · ${project.region}` : ''}</Typography>
                        <Typography variant="body2" color="text.secondary" sx={{ mt: 0.6 }}>{project.description || 'No description provided.'}</Typography>
                      </Box>} />
                    </Box>
                  ))}
                  {filteredProjects.length === 0 && <Typography color="text.secondary" sx={{ py: 2, textAlign: 'center' }}>No projects match your search.</Typography>}
                </Stack>
              )}
              <Stack direction="row" justifyContent="flex-end" sx={{ mt: 2 }}>
                <Button variant="text" color="inherit" onClick={() => setStep(0)} disabled={busy} sx={{ mr: 1 }}>
                  Back
                </Button>
                <Button variant="contained" disabled={busy || selectedProjects.length === 0} onClick={() => void run(() => startMiPreflight(operation.id, selectedProjects), 2)}>
                  Run preflight
                </Button>
              </Stack>
            </Box>
          )}
          {step === 2 && (
            <Box>
              <Typography variant="h6">3. Review preflight</Typography>
              <Typography color="text.secondary" sx={{ mb: 2 }}>
                Conflicts are decided per runtime. Offline and unauthorized targets remain visible as ineligible.
              </Typography>
              <TargetTable
                operation={operation}
                projectNames={projectNames}
                conflictDecisions={targetDecisions}
                onConflictDecision={(targetId, deleteBeforeUpload) => setTargetDecisions((current) => ({ ...current, [targetId]: deleteBeforeUpload }))}
              />
              <Button
                variant="contained"
                disabled={busy || operation.targets.every((target) => target.eligible === false)}
                onClick={() =>
                  void run(
                    () =>
                      saveMiTargetDecisions(
                        operation.id,
                        decisions.map((target) => {
                          const targetId = target.targetId || target.id || '';
                          return { targetId, deleteBeforeUpload: targetDecisions[targetId] ?? target.deleteBeforeUpload ?? false };
                        }),
                      ),
                    3,
                  )
                }
                sx={{ mt: 2 }}>
                Continue
              </Button>
              <Button variant="text" color="inherit" onClick={() => setStep(1)} disabled={busy} sx={{ mt: 2, ml: 1 }}>
                Back
              </Button>
            </Box>
          )}
          {step === 3 && (
            <Box>
              <Typography variant="h6">4. Execute deployment</Typography>
              <Alert severity="warning" sx={{ my: 2 }}>
                The operation continues on the server after you leave this page. Failed and indeterminate targets can be retried later.
              </Alert>
              {operation.targets.some((target) => target.environmentName?.toLowerCase().includes('prod')) && (
                <TextField label={`Type DEPLOY ${operation.artifactName}:${operation.artifactVersion}`} value={productionConfirmation} onChange={(e) => setProductionConfirmation(e.target.value)} fullWidth sx={{ mb: 2 }} />
              )}
              {operation.status === 'READY' && !executing && (
                <Button
                  variant="contained"
                  disabled={busy}
                  onClick={() => {
                    setExecuting(true);
                    setOperation((current) => current ? {
                      ...current,
                      status: 'RUNNING',
                      targets: current.targets.map((target) => target.eligible && target.phase === 'QUEUED' ? { ...target, phase: 'VALIDATING', message: 'Checking runtime before deployment…' } : target),
                    } : current);
                    void run(() => executeMiDeployment(operation.id, productionConfirmation), 3).finally(() => setExecuting(false));
                  }}>
                  Start deployment
                </Button>
              )}
              {operation.status === 'READY' && !executing && (
                <Button variant="text" color="inherit" onClick={() => setStep(2)} disabled={busy} sx={{ mt: 2, ml: 1 }}>
                  Back
                </Button>
              )}
            </Box>
          )}
          {(executing || (autoChecking && operation.targets.some((target) => target.phase === 'INDETERMINATE')) || operation.status === 'RUNNING' || operation.status.startsWith('COMPLETED') || operation.status === 'CANCELLED' || operation.status === 'FAILED') && (
            <Box>
              <Divider sx={{ my: 2 }} />
            <Stack direction="row" gap={1} alignItems="center" flexWrap="wrap" sx={{ mb: 1 }}>
              <Typography variant="h6">Execution</Typography>
              <Chip label={executing || (autoChecking && operation.targets.some((target) => target.phase === 'INDETERMINATE')) ? 'RUNNING' : operation.status} color={executing || (autoChecking && operation.targets.some((target) => target.phase === 'INDETERMINATE')) ? 'info' : undefined} />
              {(['SUCCEEDED', 'FAILED', 'FAULTY', 'INDETERMINATE', 'SKIPPED_CONFLICT', 'SKIPPED_INELIGIBLE'] as const).map((phase) => {
                const count = operation.targets.filter((target) => target.phase === phase).length;
                return count > 0 && !(autoChecking && operation.targets.some((target) => target.phase === 'INDETERMINATE')) ? <Chip key={phase} size="small" label={`${phase}: ${count}`} /> : null;
              })}
            </Stack>
            {(executing || (autoChecking && operation.targets.some((target) => target.phase === 'INDETERMINATE')) || operation.status === 'RUNNING') && (
              <>
                <Typography variant="body2" color="text.secondary" sx={{ mb: 0.75 }}>
                  {executing ? 'Deploying and checking each MI runtime…' : autoChecking && operation.targets.some((target) => target.phase === 'INDETERMINATE') ? 'Rechecking runtime status…' : 'Deployment is running in the background…'}
                </Typography>
                <LinearProgress sx={{ borderRadius: 1, mb: 1.5 }} />
              </>
            )}
            {!executing && operation.targets.some((target) => target.phase === 'INDETERMINATE') && (
              <Stack direction="row" gap={1} alignItems="center" sx={{ mb: 1.5 }}>
                <CircularProgress size={15} />
                <Typography variant="body2" color="text.secondary">Checking runtime status automatically…</Typography>
              </Stack>
            )}
              <TextField size="small" label="Filter targets" value={targetFilter} onChange={(event) => setTargetFilter(event.target.value)} sx={{ mb: 1, minWidth: 260 }} />
            <TargetTable
              operation={operation}
              filter={targetFilter}
              projectNames={projectNames}
              busy={busy}
              onRecheck={(targetId) => void run(() => recheckMiDeployment(operation.id, targetId))}
              onCancel={(targetId) => void run(() => cancelMiDeployment(operation.id, targetId))}
              onRetry={(targetId) => void run(() => retryMiDeployment(operation.id, [targetId]), 3)}
            />
            </Box>
          )}
        </Stack>
      )}
      {!operation && !canManage && <Alert severity="info">You have view-only access to deployment history.</Alert>}
      {!operation && history.length > 0 && (
        <Box sx={{ mt: 4 }}>
          <Typography variant="h6" sx={{ mb: 1 }}>
            Recent deployments
          </Typography>
          <ListingTable>
            <ListingTable.Head><ListingTable.Row><ListingTable.Cell>Application</ListingTable.Cell><ListingTable.Cell>Version</ListingTable.Cell><ListingTable.Cell>Executed</ListingTable.Cell><ListingTable.Cell>Status</ListingTable.Cell><ListingTable.Cell>Actions</ListingTable.Cell></ListingTable.Row></ListingTable.Head>
            <ListingTable.Body>{history.map((item) => <ListingTable.Row key={item.id}><ListingTable.Cell><Button variant="text" sx={{ textTransform: 'none', p: 0 }} onClick={() => { setOperation(item); setStep(stepForOperation(item)); }}>{item.artifactName}</Button></ListingTable.Cell><ListingTable.Cell>{item.artifactVersion}</ListingTable.Cell><ListingTable.Cell>{item.updatedAt ? new Date(item.updatedAt).toLocaleString() : '—'}</ListingTable.Cell><ListingTable.Cell><Chip size="small" label={item.status} /></ListingTable.Cell><ListingTable.Cell><Tooltip title="Delete deployment"><IconButton size="small" color="error" aria-label={`Delete ${item.artifactName}`} onClick={() => setPendingDelete(item)}><Trash2 size={16} /></IconButton></Tooltip></ListingTable.Cell></ListingTable.Row>)}</ListingTable.Body>
          </ListingTable>
          <TablePagination component="div" count={historyTotal} page={historyPage} onPageChange={(_, value) => setHistoryPage(value)} rowsPerPage={historyRowsPerPage} onRowsPerPageChange={(event) => { setHistoryRowsPerPage(Number(event.target.value)); setHistoryPage(0); }} rowsPerPageOptions={[5, 10, 25, 50]} />
        </Box>
      )}
    <Dialog open={pendingDelete !== null} onClose={() => !busy && setPendingDelete(null)} maxWidth="sm" fullWidth>
      <DialogTitle>Delete deployment record?</DialogTitle>
      <DialogContent>
        <Typography> This will permanently remove the deployment history, targets and stored artifact for <strong>{pendingDelete?.artifactName} {pendingDelete?.artifactVersion}</strong>. This action cannot be undone.</Typography>
      </DialogContent>
      <DialogActions>
        <Button onClick={() => setPendingDelete(null)} disabled={busy}>Cancel</Button>
        <Button variant="contained" color="error" startIcon={<Trash2 size={16} />} onClick={() => void confirmDelete()} disabled={busy}>Delete record</Button>
      </DialogActions>
    </Dialog>
    </PageContent>
  );
}
function TargetTable({ operation, filter = '', projectNames = {}, busy = false, onRecheck, onCancel, onRetry, conflictDecisions, onConflictDecision }: { operation: MiDeployment; filter?: string; projectNames?: Record<string, string>; busy?: boolean; onRecheck?: (targetId: string) => void; onCancel?: (targetId: string) => void; onRetry?: (targetId: string) => void; conflictDecisions?: Record<string, boolean>; onConflictDecision?: (targetId: string, deleteBeforeUpload: boolean) => void }): JSX.Element {
  const [logRuntimeId, setLogRuntimeId] = useState<string | null>(null);
  const normalizedFilter = filter.trim().toLowerCase();
  const targets = operation.targets.filter((target) => !normalizedFilter || [target.projectName, target.projectId, target.environmentName, target.runtimeName, target.phase, target.message, target.reason].filter(Boolean).some((value) => value!.toLowerCase().includes(normalizedFilter)));
  return (
    <>
    <ListingTable>
      <ListingTable.Head>
        <ListingTable.Row>
          <ListingTable.Cell>Project</ListingTable.Cell>
          <ListingTable.Cell>Environment</ListingTable.Cell>
          <ListingTable.Cell>Runtime</ListingTable.Cell>
          <ListingTable.Cell>Status</ListingTable.Cell>
          <ListingTable.Cell>Details</ListingTable.Cell>
          <ListingTable.Cell>Logs</ListingTable.Cell>
          {(onRecheck || onCancel || onRetry || onConflictDecision) && <ListingTable.Cell>Actions</ListingTable.Cell>}
        </ListingTable.Row>
      </ListingTable.Head>
      <ListingTable.Body>
        {targets.map((target, index) => (
          <ListingTable.Row key={target.targetId || target.id || `${target.runtimeId}-${index}`}>
            <ListingTable.Cell>{target.projectName && target.projectName !== target.projectId ? target.projectName : projectNames[target.projectId] || target.projectName || target.projectId}</ListingTable.Cell>
            <ListingTable.Cell>{target.environmentName || '—'}</ListingTable.Cell>
            <ListingTable.Cell>{target.runtimeName || target.runtimeId}</ListingTable.Cell>
            <ListingTable.Cell>{['SUCCEEDED'].includes(target.phase) ? <Stack direction="row" gap={0.5} alignItems="center"><CheckCircle2 color="green" size={16} /><Typography variant="caption" color="success.main">Succeeded</Typography></Stack> : ['FAILED', 'FAULTY'].includes(target.phase) ? <Stack direction="row" gap={0.5} alignItems="center"><XCircle color="red" size={16} /><Typography variant="caption" color="error.main">{target.phase}</Typography></Stack> : ['VALIDATING', 'DELETING', 'VERIFYING_DELETE', 'UPLOADING', 'VERIFYING_DEPLOY'].includes(target.phase) ? <Stack direction="row" gap={0.75} alignItems="center"><CircularProgress size={14} /><Chip size="small" color="info" label={target.phase} /></Stack> : <Chip size="small" color={target.phase === 'QUEUED' ? 'success' : undefined} label={target.phase} />}</ListingTable.Cell>
            <ListingTable.Cell>{target.message || target.reason || (target.conflict || target.conflictDetected ? 'Same name/version exists' : '—')}</ListingTable.Cell>
            <ListingTable.Cell>
              <Tooltip title="View runtime logs">
                <IconButton size="small" aria-label={`View logs for ${target.runtimeName || target.runtimeId}`} disabled={!target.runtimeId} onClick={() => setLogRuntimeId(target.runtimeId)}>
                  <FileText size={16} />
                </IconButton>
              </Tooltip>
            </ListingTable.Cell>
            {(onRecheck || onCancel || onRetry || onConflictDecision) && <ListingTable.Cell>
              <Stack direction="row" gap={0.5} flexWrap="wrap">
                {onConflictDecision && (target.conflict || target.conflictDetected) && (() => {
                  const targetId = target.targetId || target.id || '';
                  const deleteBeforeUpload = conflictDecisions?.[targetId] ?? target.deleteBeforeUpload ?? false;
                  return <>
                    <Button size="small" variant={deleteBeforeUpload ? 'contained' : 'text'} onClick={() => onConflictDecision(targetId, true)} disabled={busy}>Delete conflict</Button>
                    <Button size="small" variant={!deleteBeforeUpload ? 'contained' : 'text'} color="inherit" onClick={() => onConflictDecision(targetId, false)} disabled={busy}>Skip conflict</Button>
                  </>;
                })()}
                {onRecheck && <Button size="small" variant="text" startIcon={<RefreshCw size={14} />} onClick={() => onRecheck(target.targetId || target.id || '')} disabled={busy || target.phase !== 'INDETERMINATE'}>Recheck</Button>}
                {onCancel && <Button size="small" variant="text" color="inherit" onClick={() => onCancel(target.targetId || target.id || '')} disabled={busy || target.phase !== 'QUEUED'}>Cancel</Button>}
                {onRetry && <Button size="small" variant="text" startIcon={<RefreshCw size={14} />} onClick={() => onRetry(target.targetId || target.id || '')} disabled={busy || !['FAILED', 'FAULTY'].includes(target.phase)}>Retry</Button>}
              </Stack>
            </ListingTable.Cell>}
          </ListingTable.Row>
        ))}
      </ListingTable.Body>
    </ListingTable>
    {logRuntimeId && <LogFilesDrawer runtimeId={logRuntimeId} onClose={() => setLogRuntimeId(null)} />}
    </>
  );
}
