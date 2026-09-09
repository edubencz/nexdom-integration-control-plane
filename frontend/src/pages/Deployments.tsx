import {
  Alert,
  Box,
  Button,
  Checkbox,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  Divider,
  Drawer,
  FormControlLabel,
  IconButton,
  LinearProgress,
  ListingTable,
  MenuItem,
  PageContent,
  PageTitle,
  Stack,
  Step,
  StepLabel,
  Stepper,
  TablePagination,
  TextField,
  Tooltip,
  Typography,
} from '@wso2/oxygen-ui';
import { ArrowLeft, CheckCircle2, FileText, RefreshCw, Trash2, Upload, X, XCircle } from '@wso2/oxygen-ui-icons-react';
import { useEffect, useRef, useState, type JSX, type ReactNode } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useSearchParams } from 'react-router';
import type { OrgScope } from '../nav';
import { useAccessControl } from '../contexts/AccessControlContext';
import { Permissions } from '../constants/permissions';
import { useProjects } from '../api/queries';
import {
  cancelMiDeployment,
  createMiDeployment,
  deleteMiDeployment,
  executeMiDeployment,
  getMiDeployment,
  getMiDeploymentEvents,
  listMiDeployments,
  retryMiDeployment,
  recheckMiDeployment,
  saveMiTargetDecisions,
  startMiPreflight,
  type MiDeployment,
  type MiDeploymentSummary,
  type MiDeploymentTarget,
  type DeploymentTiming,
} from '../api/miDeployments';
import { LogFilesDrawer } from '../components/LogFilesDrawer';

const active = new Set(['RUNNING', 'CANCELLING']);
const preparing = new Set(['DRAFT', 'PREFLIGHT', 'AWAITING_DECISIONS', 'READY']);
const retryable = new Set(['FAILED', 'FAULTY', 'INDETERMINATE']);
const labels: Record<string, string> = {
  AWAITING_DECISIONS: 'Review conflicts',
  COMPLETED_WITH_ISSUES: 'Completed with issues',
  SKIPPED_CONFLICT: 'Conflict skipped',
  SKIPPED_INELIGIBLE: 'Ineligible',
  VERIFYING_DELETE: 'Verifying removal',
  VERIFYING_DEPLOY: 'Verifying deployment',
  INDETERMINATE: 'Needs recheck',
  STALE_PREFLIGHT: 'Preflight expired',
};
const label = (value: string) => labels[value] ?? value.charAt(0) + value.slice(1).toLowerCase();
const date = (value?: string | null) => (value ? new Date(value).toLocaleString() : 'Not available');
const card = { border: '1px solid', borderColor: 'divider', borderRadius: 2, p: 2.5, bgcolor: 'background.paper' };
function duration(value: DeploymentTiming, running = false): string {
  const ms = value.durationMs ?? (running && value.startedAt ? Date.now() - new Date(value.startedAt).getTime() : null);
  if (ms == null || !Number.isFinite(ms)) return '\u2014';
  if (ms < 1000) return `${Math.max(0, ms)} ms`;
  const seconds = Math.floor(ms / 1000);
  return seconds < 60 ? `${seconds}s` : seconds < 3600 ? `${Math.floor(seconds / 60)}m ${seconds % 60}s` : `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
}
function Status({ value }: { value: string }): JSX.Element {
  const success = value === 'SUCCEEDED' || value === 'COMPLETED';
  const failure = ['FAILED', 'FAULTY'].includes(value);
  const warning = ['INDETERMINATE', 'COMPLETED_WITH_ISSUES', 'STALE_PREFLIGHT'].includes(value);
  const running = active.has(value) || ['VALIDATING', 'DELETING', 'UPLOADING', 'VERIFYING_DELETE', 'VERIFYING_DEPLOY'].includes(value);
  return <Chip size="small" label={label(value)} color={success ? 'success' : failure ? 'error' : warning ? 'warning' : running ? 'info' : 'default'} icon={success ? <CheckCircle2 size={14} /> : failure ? <XCircle size={14} /> : undefined} />;
}
function Field({ title, children }: { title: string; children: ReactNode }): JSX.Element {
  return (
    <Box sx={{ minWidth: 0 }}>
      <Typography variant="caption" color="text.secondary">
        {title}
      </Typography>
      <Typography variant="body2" component="div" sx={{ overflowWrap: 'anywhere' }}>
        {children}
      </Typography>
    </Box>
  );
}
function initialStep(operation: MiDeployment) {
  return operation.status === 'READY' ? 3 : operation.status === 'AWAITING_DECISIONS' ? 2 : 0;
}
function numberParam(value: string | null, fallback: number) {
  const n = Number(value);
  return value !== null && Number.isInteger(n) && n >= 0 ? n : fallback;
}

export default function Deployments({ org }: OrgScope): JSX.Element {
  const { hasOrgPermission, isOrgPermissionsLoaded } = useAccessControl();
  const canManage = hasOrgPermission(Permissions.DEPLOYMENT_MANAGE);
  const canView = canManage || hasOrgPermission(Permissions.DEPLOYMENT_VIEW);
  const [params, setParams] = useSearchParams();
  const client = useQueryClient();
  const id = params.get('deploymentId');
  const isNew = params.get('view') === 'new' && !id;
  const isHistory = !id && !isNew;
  const page = numberParam(params.get('page'), 0);
  const size = [5, 10, 25, 50].includes(numberParam(params.get('size'), 10)) ? numberParam(params.get('size'), 10) : 10;
  const [file, setFile] = useState<File | null>(null);
  const [selectedProjects, setSelectedProjects] = useState<string[]>([]);
  const [projectSearch, setProjectSearch] = useState('');
  const [decisions, setDecisions] = useState<Record<string, boolean>>({});
  const [confirmation, setConfirmation] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pendingDelete, setPendingDelete] = useState<MiDeploymentSummary | null>(null);
  const [logRuntime, setLogRuntime] = useState<string | null>(null);
  const [, tick] = useState(0);
  const restored = useRef('');
  const uploadKey = useRef(crypto.randomUUID());
  const { data: projects = [], isLoading: projectsLoading } = useProjects();
  const history = useQuery({
    queryKey: ['mi-deployments', org, page, size],
    queryFn: () => listMiDeployments(org, size, page * size),
    enabled: canView && isHistory,
    refetchInterval: (query) => (query.state.data?.items.some((item) => active.has(item.status)) ? 3000 : false),
  });
  const detail = useQuery({ queryKey: ['mi-deployment', org, id], queryFn: () => getMiDeployment(id!, org), enabled: canView && !!id, refetchInterval: (query) => (query.state.data && active.has(query.state.data.status) ? 3000 : false) });
  const operation = detail.data;
  const editing = !!operation && preparing.has(operation.status) && canManage;
  const step = operation ? Math.min(numberParam(params.get('step'), initialStep(operation)), operation.status === 'DRAFT' ? 1 : operation.status === 'AWAITING_DECISIONS' ? 2 : 3) : 0;
  const targetFilter = params.get('targetQuery') ?? '';
  const targetStatus = params.get('targetStatus') ?? '';
  const eventTarget = params.get('target');
  const eventsOpen = params.get('events') === '1';
  const updateRoute = (changes: Record<string, string | null>, replace = false) => {
    setParams(
      (current) => {
        const next = new URLSearchParams(current);
        Object.entries(changes).forEach(([key, value]) => (value === null ? next.delete(key) : next.set(key, value)));
        return next;
      },
      { replace },
    );
  };
  const openOperation = (deploymentId: string, nextStep?: number) => updateRoute({ deploymentId, view: null, step: nextStep == null ? null : String(nextStep), events: null, target: null });
  const back = () => {
    setError(null);
    updateRoute({ deploymentId: null, view: null, step: null, events: null, target: null });
  };
  useEffect(() => {
    if (!operation || restored.current === `${org}:${operation.id}`) return;
    restored.current = `${org}:${operation.id}`;
    setSelectedProjects(operation.selectedProjectIds?.length ? operation.selectedProjectIds : [...new Set(operation.targets.map((t) => t.projectId))]);
    setDecisions(Object.fromEntries(operation.targets.map((t) => [t.targetId, t.deleteBeforeUpload])));
    setConfirmation('');
    setError(null);
  }, [operation, org]);
  useEffect(() => {
    if (!operation || !active.has(operation.status)) return;
    const timer = window.setInterval(() => tick((v) => v + 1), 1000);
    return () => window.clearInterval(timer);
  }, [operation]);
  const run = async (action: () => Promise<MiDeployment>, nextStep?: number) => {
    setBusy(true);
    setError(null);
    try {
      const result = await action();
      client.setQueryData(['mi-deployment', org, result.id], result);
      await client.invalidateQueries({ queryKey: ['mi-deployments', org] });
      await client.invalidateQueries({ queryKey: ['mi-events', org] });
      if (result.id !== id || nextStep !== undefined) openOperation(result.id, nextStep);
      if (result.id !== id) {
        restored.current = '';
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Deployment request failed.');
    } finally {
      setBusy(false);
    }
  };
  const remove = async () => {
    if (!pendingDelete) return;
    setBusy(true);
    setError(null);
    try {
      await deleteMiDeployment(pendingDelete.id);
      setPendingDelete(null);
      if (history.data?.items.length === 1 && page > 0) updateRoute({ page: String(page - 1) }, true);
      await client.invalidateQueries({ queryKey: ['mi-deployments', org] });
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Unable to delete deployment.');
    } finally {
      setBusy(false);
    }
  };
  if (isOrgPermissionsLoaded && !canView) return <></>;
  const shownTargets = (operation?.targets ?? []).filter(
    (t) => (!targetStatus || t.phase === targetStatus) && (!targetFilter || [t.projectName, t.projectId, t.runtimeName, t.runtimeId, t.environmentName, t.message, t.reason].some((value) => value?.toLowerCase().includes(targetFilter.toLowerCase()))),
  );
  const eligibleCount = operation?.targets.filter((t) => t.eligible && (!t.conflictDetected || (decisions[t.targetId] ?? t.deleteBeforeUpload))).length ?? 0;
  const production = operation?.targets.some((t) => t.production && t.eligible && (!t.conflictDetected || t.deleteBeforeUpload));
  const showEvents = (targetId?: string) => updateRoute({ events: '1', target: targetId ?? null });
  return (
    <PageContent>
      <Stack direction="row" alignItems="center" justifyContent="space-between" gap={2} sx={{ mb: 2 }}>
        <PageTitle>
          <PageTitle.Header>{isHistory ? 'Deployments' : isNew || editing ? 'New deployment' : 'Deployment details'}</PageTitle.Header>
        </PageTitle>
        {isHistory && canManage && (
          <Button
            variant="contained"
            startIcon={<Upload size={16} />}
            sx={{ flexShrink: 0, whiteSpace: "nowrap" }}
            onClick={() => {
              setFile(null);
              uploadKey.current = crypto.randomUUID();
              updateRoute({ view: 'new' });
            }}>
            New deploy
          </Button>
        )}
      </Stack>
      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}
      {((detail.isError && id) || (history.isError && isHistory)) && (
        <Alert
          severity="error"
          sx={{ mb: 2 }}
          action={
            <Button color="inherit" onClick={() => void (id ? detail.refetch() : history.refetch())}>
              Try again
            </Button>
          }>
          {id ? 'Unable to refresh deployment details. Any displayed data is the last saved response.' : 'Unable to load deployment history.'}
        </Alert>
      )}
      {!isHistory && (
        <Button startIcon={<ArrowLeft size={16} />} onClick={back} sx={{ mb: 2 }}>
          Back to deployments
        </Button>
      )}
      {isHistory && (
        <Stack gap={2}>
          <Typography color="text.secondary">Review deployments across projects and runtimes. Execution results and events remain available when you return.</Typography>
          {!canManage && <Alert severity="info">You have view-only access to deployment history.</Alert>}
          {history.isLoading ? (
            <CircularProgress aria-label="Loading deployment history" />
          ) : history.data?.items.length === 0 ? (
            <Box sx={{ ...card, textAlign: 'center', py: 6 }}>
              <Typography variant="h6">No deployments yet</Typography>
              <Typography color="text.secondary">Your deployment history will appear here.</Typography>
            </Box>
          ) : (
            history.data && (
              <Box sx={{ ...card, p: 0, overflow: 'hidden' }}>
                <Box sx={{ overflowX: 'auto' }}>
                  <ListingTable>
                    <ListingTable.Head>
                      <ListingTable.Row>
                        {['Application / version', 'Created by', 'Started', 'Duration', 'Result', 'Runtimes', ...(canManage ? ['Actions'] : [])].map((title) => (
                          <ListingTable.Cell key={title}>{title}</ListingTable.Cell>
                        ))}
                      </ListingTable.Row>
                    </ListingTable.Head>
                    <ListingTable.Body>
                      {history.data.items.map((item) => (
                        <ListingTable.Row key={item.id}>
                          <ListingTable.Cell>
                            <Button sx={{ textTransform: 'none', textAlign: 'left', p: 0 }} onClick={() => openOperation(item.id)}>
                              {item.artifactName}
                            </Button>
                            <Typography variant="caption" display="block" color="text.secondary">
                              {item.artifactVersion}
                              {item.parentDeploymentId ? '\u00b7 Retry' : ''}
                            </Typography>
                          </ListingTable.Cell>
                          <ListingTable.Cell>
                            <Typography variant="body2" sx={{ maxWidth: 160, overflowWrap: 'anywhere' }}>
                              {item.createdBy}
                            </Typography>
                          </ListingTable.Cell>
                          <ListingTable.Cell>{item.startedAt ? date(item.startedAt) : preparing.has(item.status) ? 'Not started' : 'Not available'}</ListingTable.Cell>
                          <ListingTable.Cell>{duration(item, active.has(item.status))}</ListingTable.Cell>
                          <ListingTable.Cell>
                            <Status value={item.status} />
                          </ListingTable.Cell>
                          <ListingTable.Cell>
                            <Typography variant="body2">
                              {item.summary.succeeded} / {item.summary.total} succeeded
                            </Typography>
                            <Typography variant="caption" color="text.secondary">
                              {item.summary.failed + item.summary.indeterminate} issues / {item.summary.skipped} skipped / {item.summary.cancelled} cancelled
                            </Typography>
                          </ListingTable.Cell>
                          {canManage && (
                            <ListingTable.Cell>
                              <Tooltip title={active.has(item.status) ? 'Wait for execution to finish before deleting' : 'Delete deployment record'}>
                                <span>
                                  <IconButton color="error" size="small" aria-label={`Delete ${item.artifactName} ${item.artifactVersion}`} disabled={active.has(item.status)} onClick={() => setPendingDelete(item)}>
                                    <Trash2 size={16} />
                                  </IconButton>
                                </span>
                              </Tooltip>
                            </ListingTable.Cell>
                          )}
                        </ListingTable.Row>
                      ))}
                    </ListingTable.Body>
                  </ListingTable>
                </Box>
                <TablePagination
                  component="div"
                  count={history.data.total}
                  page={page}
                  rowsPerPage={size}
                  rowsPerPageOptions={[5, 10, 25, 50]}
                  onPageChange={(_, value) => updateRoute({ page: String(value) })}
                  onRowsPerPageChange={(e) => updateRoute({ size: e.target.value, page: '0' })}
                />
              </Box>
            )
          )}
        </Stack>
      )}
      {id && detail.isLoading && <CircularProgress aria-label="Loading deployment details" />}
      {isNew && canManage && (
        <Box sx={{ ...card, borderStyle: 'dashed', textAlign: 'center', py: 5 }}>
          <Upload size={32} />
          <Typography variant="h6" sx={{ mt: 1 }}>
            Deploy a Carbon Application
          </Typography>
          <Typography color="text.secondary" sx={{ mb: 3 }}>
            Choose one .CAR, then select projects and review their runtimes.
          </Typography>
          <Button component="label" variant={file ? 'outlined' : 'contained'}>
            Choose .CAR
            <input
              hidden
              type="file"
              accept=".car"
              onChange={(e) => {
                setFile(e.target.files?.[0] ?? null);
                uploadKey.current = crypto.randomUUID();
              }}
            />
          </Button>
          {file && (
            <Stack gap={2} alignItems="center" sx={{ mt: 2 }}>
              <Typography>
                {file.name} / {(file.size / 1024 / 1024).toFixed(2)} MB
              </Typography>
              <Button variant="contained" disabled={busy} onClick={() => void run(() => createMiDeployment(org, file, uploadKey.current), 0)}>
                {busy ? 'Uploading...' : 'Upload and inspect'}
              </Button>
            </Stack>
          )}
        </Box>
      )}
      {operation && (
        <Stack gap={2.5}>
          <Box sx={card}>
            <Stack direction={{ xs: 'column', sm: 'row' }} gap={2} alignItems={{ sm: 'center' }} justifyContent="space-between">
              <Box>
                <Typography variant="h6">
                  {operation.artifactName}{' '}
                  <Typography component="span" color="text.secondary">
                    {operation.artifactVersion}
                  </Typography>
                </Typography>
                <Typography variant="body2" color="text.secondary" sx={{ overflowWrap: 'anywhere' }}>
                  {operation.fileName}
                </Typography>
              </Box>
              <Status value={operation.status} />
            </Stack>
            <Box sx={{ display: 'grid', gridTemplateColumns: { xs: '1fr 1fr', md: 'repeat(4, 1fr)' }, gap: 2, mt: 2 }}>
              <Field title="Created by">{operation.createdBy}</Field>
              <Field title="Started">{date(operation.startedAt)}</Field>
              <Field title="Finished">{date(operation.finishedAt)}</Field>
              <Field title="Duration">{duration(operation, active.has(operation.status))}</Field>
            </Box>
            {operation.parentDeploymentId && (
              <Button size="small" sx={{ mt: 1 }} onClick={() => openOperation(operation.parentDeploymentId!)}>
                View original deployment
              </Button>
            )}
          </Box>
          {operation.executionError && (
            <Alert severity="error">
              {operation.executionError}
              {canManage && (
                <Button color="inherit" disabled={busy} onClick={() => void run(() => recheckMiDeployment(operation.id))}>
                  Recheck interrupted execution
                </Button>
              )}
            </Alert>
          )}
          {editing && (
            <Box sx={card}>
              <Stepper activeStep={step} alternativeLabel sx={{ mb: 3 }}>
                {['Artifact', 'Projects', 'Conflicts', 'Review'].map((title) => (
                  <Step key={title}>
                    <StepLabel>{title}</StepLabel>
                  </Step>
                ))}
              </Stepper>
              {step === 0 && (
                <Stack gap={2}>
                  <Typography variant="h6">Confirm artifact</Typography>
                  <Field title="File size">{(operation.fileSize / 1024 / 1024).toFixed(2)} MB</Field>
                  <Field title="SHA-256">{operation.sha256}</Field>
                  <Field title="Uploaded">{date(operation.createdAt)}</Field>
                  <Box>
                    <Button variant="contained" onClick={() => updateRoute({ step: '1' })}>
                      Continue to projects
                    </Button>
                  </Box>
                </Stack>
              )}
              {step === 1 && (
                <Stack gap={2}>
                  <Typography variant="h6">Select projects</Typography>
                  <Typography color="text.secondary">{selectedProjects.length} projects selected. All registered MI runtimes in these projects will be inspected.</Typography>
                  <TextField size="small" label="Search projects" value={projectSearch} onChange={(e) => setProjectSearch(e.target.value)} />
                  {projectsLoading ? (
                    <CircularProgress />
                  ) : (
                    <Stack gap={1} sx={{ maxHeight: 360, overflowY: 'auto' }}>
                      {projects
                        .filter((p) => `${p.name} ${p.handler}`.toLowerCase().includes(projectSearch.toLowerCase()))
                        .map((project) => (
                          <Box key={project.id} sx={{ ...card, p: 1, borderColor: selectedProjects.includes(project.id) ? 'primary.main' : 'divider' }}>
                            <FormControlLabel
                              sx={{ m: 0, width: '100%' }}
                              control={<Checkbox checked={selectedProjects.includes(project.id)} onChange={() => setSelectedProjects((current) => (current.includes(project.id) ? current.filter((id) => id !== project.id) : [...current, project.id]))} />}
                              label={
                                <Box>
                                  <Typography variant="body2" fontWeight={600}>
                                    {project.name}
                                  </Typography>
                                  <Typography variant="caption" color="text.secondary">
                                    {project.handler}
                                  </Typography>
                                </Box>
                              }
                            />
                          </Box>
                        ))}
                    </Stack>
                  )}
                  <Stack direction="row" justifyContent="space-between">
                    <Button disabled={busy} onClick={() => updateRoute({ step: '0' })}>
                      Back
                    </Button>
                    <Button variant="contained" disabled={busy || !selectedProjects.length} onClick={() => void run(() => startMiPreflight(operation.id, selectedProjects), 2)}>
                      {busy ? 'Inspecting runtimes...' : 'Run preflight'}
                    </Button>
                  </Stack>
                </Stack>
              )}
              {step === 2 && (
                <Stack gap={2}>
                  <Typography variant="h6">Review runtime conflicts</Typography>
                  <Typography color="text.secondary">Choose whether to replace an existing application or skip that runtime. Offline runtimes remain recorded as ineligible.</Typography>
                  {operation.targets.length === 0 && <Alert severity="info">No MI runtimes were found in the selected projects. Go back and select another project.</Alert>}
                  <Targets targets={operation.targets} busy={busy} decisions={decisions} onDecision={(id, replace) => setDecisions((current) => ({ ...current, [id]: replace }))} onDetails={showEvents} onLogs={setLogRuntime} />
                  <Typography variant="body2">{eligibleCount} runtimes selected for execution.</Typography>
                  <Stack direction="row" justifyContent="space-between">
                    <Button disabled={busy} onClick={() => updateRoute({ step: '1' })}>
                      Back
                    </Button>
                    <Button
                      variant="contained"
                      disabled={busy || eligibleCount === 0}
                      onClick={() =>
                        void run(
                          () =>
                            saveMiTargetDecisions(
                              operation.id,
                              operation.targets.filter((t) => t.conflictDetected).map((t) => ({ targetId: t.targetId, deleteBeforeUpload: decisions[t.targetId] ?? t.deleteBeforeUpload })),
                            ),
                          3,
                        )
                      }>
                      Continue to review
                    </Button>
                  </Stack>
                </Stack>
              )}
              {step === 3 && (
                <Stack gap={2}>
                  <Typography variant="h6">Ready to deploy</Typography>
                  <Typography>
                    {operation.targets.filter((t) => t.eligible && (!t.conflictDetected || t.deleteBeforeUpload)).length} runtimes across {new Set(operation.targets.map((t) => t.projectId)).size} projects.
                  </Typography>
                  <Alert severity="info">Execution continues on the server when you leave this page. Return to this deployment to review progress and results.</Alert>
                  {production && (
                    <>
                      <Alert severity="warning">This deployment includes production runtimes.</Alert>
                      <TextField fullWidth label={`Type DEPLOY ${operation.artifactName}:${operation.artifactVersion}`} value={confirmation} onChange={(e) => setConfirmation(e.target.value)} />
                    </>
                  )}
                  <Stack direction="row" justifyContent="space-between">
                    <Button disabled={busy} onClick={() => updateRoute({ step: '2' })}>
                      Back
                    </Button>
                    <Button variant="contained" disabled={busy || (!!production && confirmation !== `DEPLOY ${operation.artifactName}:${operation.artifactVersion}`)} onClick={() => void run(() => executeMiDeployment(operation.id, confirmation))}>
                      {busy ? 'Starting...' : 'Start deployment'}
                    </Button>
                  </Stack>
                </Stack>
              )}
              <Divider sx={{ my: 2 }} />
              <Button color="inherit" disabled={busy} onClick={() => void run(() => cancelMiDeployment(operation.id))}>
                Cancel preparation
              </Button>
            </Box>
          )}
          {!editing && (
            <Stack gap={2}>
              {active.has(operation.status) && (
                <>
                  <Alert severity="info">{operation.status === 'CANCELLING' ? 'Cancellation requested. In-flight runtime requests are finishing.' : 'Deployment is running on the server. You can leave and return to this page.'}</Alert>
                  <LinearProgress aria-label="Deployment in progress" />
                </>
              )}
              <Stack direction="row" gap={1} flexWrap="wrap" alignItems="center">
                <Typography variant="h6" sx={{ mr: 1 }}>
                  Runtime executions
                </Typography>
                {Object.entries(operation.summary)
                  .filter(([name]) => name !== 'total')
                  .map(([name, count]) => (
                    <Chip key={name} size="small" variant="outlined" label={`${count} ${name}`} />
                  ))}
              </Stack>
              <Stack direction={{ xs: 'column', sm: 'row' }} gap={1}>
                <TextField size="small" label="Filter projects or runtimes" value={targetFilter} onChange={(e) => updateRoute({ targetQuery: e.target.value || null }, true)} sx={{ flex: 1 }} />
                <TextField select size="small" label="Status" value={targetStatus} onChange={(e) => updateRoute({ targetStatus: e.target.value || null }, true)} sx={{ minWidth: 190 }}>
                  <MenuItem value="">All statuses</MenuItem>
                  {[...new Set(operation.targets.map((t) => t.phase))].map((phase) => (
                    <MenuItem key={phase} value={phase}>
                      {label(phase)}
                    </MenuItem>
                  ))}
                </TextField>
                <Button startIcon={<FileText size={16} />} onClick={() => showEvents()}>
                  All events
                </Button>
                <Button startIcon={<RefreshCw size={16} />} disabled={detail.isFetching} onClick={() => void detail.refetch()}>
                  Refresh
                </Button>
                {canManage && operation.status === 'RUNNING' && (
                  <Button color="inherit" disabled={busy} onClick={() => void run(() => cancelMiDeployment(operation.id))}>
                    Cancel pending
                  </Button>
                )}
              </Stack>
              <Targets
                targets={shownTargets}
                busy={busy}
                onDetails={showEvents}
                onLogs={setLogRuntime}
                onRecheck={canManage && !active.has(operation.status) ? (targetId) => void run(() => recheckMiDeployment(operation.id, targetId)) : undefined}
                onRetry={canManage && !active.has(operation.status) ? (targetId) => void run(() => retryMiDeployment(operation.id, [targetId]), 3) : undefined}
                onCancel={canManage && active.has(operation.status) ? (targetId) => void run(() => cancelMiDeployment(operation.id, targetId)) : undefined}
              />
              {shownTargets.length === 0 && <Alert severity="info">{operation.targets.length ? 'No executions match these filters.' : 'No runtime executions were recorded for this deployment.'}</Alert>}
            </Stack>
          )}
        </Stack>
      )}
      {operation && eventsOpen && <EventsDrawer key={`${operation.id}:${eventTarget ?? 'all'}`} org={org} operation={operation} targetId={eventTarget ?? undefined} onClose={() => updateRoute({ events: null, target: null })} />}
      {logRuntime && <LogFilesDrawer runtimeId={logRuntime} onClose={() => setLogRuntime(null)} />}
      <Dialog open={!!pendingDelete} onClose={() => !busy && setPendingDelete(null)} maxWidth="sm" fullWidth>
        <DialogTitle>Delete deployment record?</DialogTitle>
        <DialogContent>
          <Typography>
            This permanently removes the history, runtime executions and events for {pendingDelete?.artifactName} {pendingDelete?.artifactVersion}. Shared artifacts used by other attempts are preserved.
          </Typography>
        </DialogContent>
        <DialogActions>
          <Button disabled={busy} onClick={() => setPendingDelete(null)}>
            Cancel
          </Button>
          <Button variant="contained" color="error" disabled={busy} onClick={() => void remove()}>
            Delete record
          </Button>
        </DialogActions>
      </Dialog>
    </PageContent>
  );
}

type TargetsProps = {
  targets: MiDeploymentTarget[];
  busy: boolean;
  onDetails: (id: string) => void;
  onLogs: (id: string) => void;
  decisions?: Record<string, boolean>;
  onDecision?: (id: string, replace: boolean) => void;
  onRecheck?: (id: string) => void;
  onRetry?: (id: string) => void;
  onCancel?: (id: string) => void;
};
function Targets({ targets, busy, onDetails, onLogs, decisions, onDecision, onRecheck, onRetry, onCancel }: TargetsProps): JSX.Element {
  const actions = targets.some(t => (onDecision && t.conflictDetected) || (onRecheck && t.phase === 'INDETERMINATE') || (onRetry && retryable.has(t.phase)) || (onCancel && t.phase === 'QUEUED'));
  return (
    <Box sx={{ ...card, p: 0, overflowX: 'auto' }}>
      <ListingTable>
        <ListingTable.Head>
          <ListingTable.Row>
            {['Project / component', 'Environment', 'Runtime', 'Status', 'Duration', 'Details', ...(actions ? ['Actions'] : [])].map((title) => (
              <ListingTable.Cell key={title}>{title}</ListingTable.Cell>
            ))}
          </ListingTable.Row>
        </ListingTable.Head>
        <ListingTable.Body>
          {targets.map((t) => (
            <ListingTable.Row key={t.targetId}>
              <ListingTable.Cell>
                {t.projectName || 'Name not recorded'}
                <Typography variant="caption" display="block" color="text.secondary">
                  {t.componentName || t.componentId}
                </Typography>
              </ListingTable.Cell>
              <ListingTable.Cell>{t.environmentName || 'Name not recorded'}</ListingTable.Cell>
              <ListingTable.Cell>{t.runtimeName || t.runtimeId}</ListingTable.Cell>
              <ListingTable.Cell>
                <Status value={t.phase} />
              </ListingTable.Cell>
              <ListingTable.Cell>{duration(t, ['VALIDATING', 'DELETING', 'VERIFYING_DELETE', 'UPLOADING', 'VERIFYING_DEPLOY'].includes(t.phase))}</ListingTable.Cell>
              <ListingTable.Cell>
                <Typography variant="body2" sx={{ maxWidth: 260, display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical', overflow: 'hidden', overflowWrap: 'anywhere' }}>
                  {t.message || t.reason || '\u2014'}
                </Typography>
                <Stack direction="row" gap={1}>
                  <Button size="small" sx={{ p: 0 }} onClick={() => onDetails(t.targetId)}>
                    View details
                  </Button>
                  <Tooltip title="Current runtime logs">
                    <IconButton size="small" aria-label={`Current logs for ${t.runtimeName || t.runtimeId}`} onClick={() => onLogs(t.runtimeId)}>
                      <FileText size={15} />
                    </IconButton>
                  </Tooltip>
                </Stack>
              </ListingTable.Cell>
              {actions && (
                <ListingTable.Cell>
                  <Stack direction="row" gap={0.5} flexWrap="wrap">
                    {onDecision && t.conflictDetected && <FormControlLabel control={<Checkbox disabled={busy} checked={decisions?.[t.targetId] ?? t.deleteBeforeUpload} onChange={(e) => onDecision(t.targetId, e.target.checked)} />} label="Replace existing" />}
                    {onRecheck && t.phase === 'INDETERMINATE' && (
                      <Button size="small" disabled={busy} onClick={() => onRecheck(t.targetId)}>
                        Recheck
                      </Button>
                    )}
                    {onRetry && retryable.has(t.phase) && (
                      <Button size="small" disabled={busy} onClick={() => onRetry(t.targetId)}>
                        Prepare retry
                      </Button>
                    )}
                    {onCancel && t.phase === 'QUEUED' && (
                      <Button size="small" color="inherit" disabled={busy} onClick={() => onCancel(t.targetId)}>
                        Cancel
                      </Button>
                    )}
                  </Stack>
                </ListingTable.Cell>
              )}
            </ListingTable.Row>
          ))}
        </ListingTable.Body>
      </ListingTable>
    </Box>
  );
}

function EventsDrawer({ org, operation, targetId, onClose }: { org: string; operation: MiDeployment; targetId?: string; onClose: () => void }): JSX.Element {
  const [page, setPage] = useState(0);
  const target = operation.targets.find((t) => t.targetId === targetId);
  const query = useQuery({ queryKey: ['mi-events', org, operation.id, targetId, page], queryFn: () => getMiDeploymentEvents(operation.id, org, targetId, 25, page * 25), refetchInterval: active.has(operation.status) ? 3000 : false });
  return (
    <Drawer anchor="right" open onClose={onClose} sx={{ '& .MuiDrawer-paper': { width: { xs: '100%', sm: 560 }, maxWidth: '100%', p: 3 } }}>
      <Stack direction="row" justifyContent="space-between" alignItems="center">
        <Typography variant="h6">{target ? 'Runtime execution details' : 'Deployment events'}</Typography>
        <IconButton aria-label="Close execution details" onClick={onClose}>
          <X size={20} />
        </IconButton>
      </Stack>
      {target && (
        <Stack gap={2} sx={{ my: 2 }}>
          <Typography>
            {target.projectName || target.projectId} / {target.runtimeName || target.runtimeId}
          </Typography>
          <Box>
            <Status value={target.phase} />
          </Box>
          <Box sx={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 2 }}>
            <Field title="Attempt">{target.attempt || 'Not started'}</Field>
            <Field title="Duration">{duration(target)}</Field>
            <Field title="Started">{date(target.startedAt)}</Field>
            <Field title="Finished">{date(target.finishedAt)}</Field>
            <Field title="HTTP status">{target.httpStatus ?? '\u2014'}</Field>
            <Field title="Reason">{target.reason || '\u2014'}</Field>
          </Box>
          <Field title="Message">{target.message || '\u2014'}</Field>
          {target.evidence?.length > 0 && (
            <Field title="Evidence">
              <Box sx={{ maxHeight: 280, overflowY: 'auto' }}>
                {target.evidence.map((item, index) => (
                  <Typography key={index} variant="body2" sx={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>
                    {item}
                  </Typography>
                ))}
              </Box>
            </Field>
          )}
        </Stack>
      )}
      <Divider sx={{ my: 2 }} />
      <Typography variant="subtitle1">Recorded events</Typography>
      <Typography variant="caption" color="text.secondary" sx={{ mb: 2 }}>
        Saved deployment events. Current runtime log files are available separately.
      </Typography>
      {query.isLoading && <CircularProgress />}
      {query.isError && (
        <Alert severity="error" action={<Button onClick={() => void query.refetch()}>Retry</Button>}>
          Unable to load events.
        </Alert>
      )}
      {query.data?.items.length === 0 && <Typography color="text.secondary">No events were recorded.</Typography>}
      <Stack gap={2}>
        {query.data?.items.map((event) => (
          <Box key={event.eventId} sx={{ borderLeft: '2px solid', borderColor: 'divider', pl: 2 }}>
            <Typography variant="caption" color="text.secondary">
              {date(event.createdAt)}
            </Typography>
            <Typography variant="subtitle2">{label(event.phase)}</Typography>
            <Typography variant="body2" sx={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>
              {event.message}
            </Typography>
            {event.reason && (
              <Typography variant="caption" display="block">
                Reason: {event.reason}
              </Typography>
            )}
            {event.httpStatus != null && (
              <Typography variant="caption" display="block">
                HTTP {event.httpStatus}
              </Typography>
            )}
            {event.evidence?.map((text, index) => (
              <Typography key={index} variant="caption" display="block" sx={{ overflowWrap: 'anywhere', whiteSpace: 'pre-wrap', maxHeight: 280, overflowY: 'auto' }}>
                {text}
              </Typography>
            ))}
          </Box>
        ))}
      </Stack>
      {query.data && <TablePagination component="div" count={query.data.total} page={page} rowsPerPage={25} rowsPerPageOptions={[25]} onPageChange={(_, next) => setPage(next)} />}
    </Drawer>
  );
}
