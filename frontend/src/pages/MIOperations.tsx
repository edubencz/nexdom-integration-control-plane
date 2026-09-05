import { Alert, Box, Button, CircularProgress, PageContent, PageTitle, Stack, Tab, Tabs, FormControl, InputLabel, MenuItem, Select, Typography } from '@wso2/oxygen-ui';
import { ExternalLink, FolderArchive, Package, Server } from '@wso2/oxygen-ui-icons-react';
import { useEffect, useMemo, useState, type JSX } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import { useQueries } from '@tanstack/react-query';
import { gql } from '../api/graphql';
import { useComponentByHandler, useEnvironments, useProjectByHandler, type GqlRuntime } from '../api/queries';
import { resourceUrl, type ComponentScope } from '../nav';
import { useAccessControl } from '../contexts/AccessControlContext';
import { Permissions } from '../constants/permissions';
import { useLoadComponentPermissions } from '../hooks/usePermissionLoader';
import { ServerManagementPanel } from '../components/ServerManagementPanel';
import { CarbonApplicationsPanel } from '../components/ArtifactDetail';
import { RegistryBrowser } from '../components/RegistryBrowser';
import { ArtifactDetail } from '../components/ArtifactDetail';
import type { SelectedArtifact } from '../components/artifact-config';

const TABS = ['server', 'applications', 'registry'] as const;
type TabName = (typeof TABS)[number];
const COMPONENT_RUNTIMES_QUERY = `query MIOperationsRuntimes($environmentId: String!, $projectId: String!, $componentId: String!) {
  runtimes(environmentId: $environmentId, projectId: $projectId, componentId: $componentId) {
    items { runtimeId, runtimeName, runtimeType, status, version, platformName, platformVersion, platformHome, osName, osVersion, registrationTime, lastHeartbeat }
    pageInfo { total, limit, offset }
  }
}`;

function validTab(value: string | null): TabName {
  return TABS.includes(value as TabName) ? (value as TabName) : 'applications';
}

export default function MIOperations(scope: ComponentScope): JSX.Element {
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const { data: project, isLoading: loadingProject } = useProjectByHandler(scope.project);
  const projectId = project?.id ?? '';
  const { data: component, isLoading: loadingComponent } = useComponentByHandler(projectId, scope.component);
  const { data: environments = [], isLoading: loadingEnvironments } = useEnvironments(projectId);
  const permissionsLoaded = useLoadComponentPermissions(scope.org, projectId, component?.id || '');
  const { hasAnyPermission, hasOrgPermission } = useAccessControl();
  const canView = hasAnyPermission([Permissions.INTEGRATION_VIEW, Permissions.INTEGRATION_EDIT, Permissions.INTEGRATION_MANAGE], projectId, component?.id);
  const canEdit = hasAnyPermission([Permissions.INTEGRATION_EDIT, Permissions.INTEGRATION_MANAGE], projectId, component?.id);
  const canManage = hasAnyPermission([Permissions.INTEGRATION_MANAGE], projectId, component?.id);
  const canOpenDeployments = hasOrgPermission(Permissions.DEPLOYMENT_VIEW) || hasOrgPermission(Permissions.DEPLOYMENT_MANAGE);
  const isMI = component?.componentType === 'MI';
  const environmentId = searchParams.get('environmentId') || '';
  const runtimeId = searchParams.get('runtimeId') || '';
  const tab = validTab(searchParams.get('tab'));
  const registryPath = searchParams.get('path') || 'registry';
  const [selectedArtifact, setSelectedArtifact] = useState<SelectedArtifact | null>(null);

  const runtimeQueries = useQueries({ queries: environments.map((environment) => ({
    queryKey: ['mi-operations-runtimes', environment.id, projectId, component?.id],
    queryFn: () => gql<{ runtimes: { items: GqlRuntime[] } }>(COMPONENT_RUNTIMES_QUERY, { environmentId: environment.id, projectId, componentId: component?.id || '' }).then((data) => data.runtimes.items),
    enabled: !!projectId && !!component?.id && isMI,
  })) });
  const runtimesLoading = isMI && runtimeQueries.some((query) => query.isLoading);
  const runtimeQueryError = isMI ? runtimeQueries.find((query) => query.isError)?.error : undefined;
  const miRuntimesByEnvironment = useMemo(() => runtimeQueries.map((query) => (query.data || []).filter((runtime) => runtime.runtimeType.toUpperCase().includes('MI'))), [runtimeQueries]);
  const defaultEnvironment = useMemo(() => {
    const activeIndex = miRuntimesByEnvironment.findIndex((runtimes) => runtimes.some((runtime) => runtime.status === 'RUNNING'));
    return environments[activeIndex >= 0 ? activeIndex : 0];
  }, [environments, miRuntimesByEnvironment]);
  const selectedEnvironment = environments.find((environment) => environment.id === environmentId) || defaultEnvironment;
  const selectedEnvironmentIndex = selectedEnvironment ? environments.findIndex((environment) => environment.id === selectedEnvironment.id) : -1;
  const miRuntimes = selectedEnvironmentIndex >= 0 ? miRuntimesByEnvironment[selectedEnvironmentIndex] || [] : [];
  const selectedRuntime = miRuntimes.find((runtime) => runtime.runtimeId === runtimeId) || miRuntimes.find((runtime) => runtime.status === 'RUNNING') || miRuntimes[0];
  const effectiveTab: TabName = tab;
  useEffect(() => { setSelectedArtifact(null); }, [selectedEnvironment?.id, selectedRuntime?.runtimeId]);

  useEffect(() => {
    if (!component || !isMI || !environments.length || !selectedEnvironment) return;
    const next = new URLSearchParams(searchParams);
    let changed = false;
    if (next.get('environmentId') !== selectedEnvironment.id) { next.set('environmentId', selectedEnvironment.id); changed = true; }
    if (selectedRuntime && next.get('runtimeId') !== selectedRuntime.runtimeId) { next.set('runtimeId', selectedRuntime.runtimeId); changed = true; }
    if (!selectedRuntime && next.has('runtimeId')) { next.delete('runtimeId'); changed = true; }
    if (!next.get('tab') || !TABS.includes(next.get('tab') as TabName)) { next.set('tab', 'applications'); changed = true; }
    if (changed) setSearchParams(next, { replace: true });
  }, [canEdit, component, environments, isMI, searchParams, selectedEnvironment, selectedRuntime, setSearchParams]);

  const updateParam = (key: string, value: string) => {
    const next = new URLSearchParams(searchParams);
    if (value) next.set(key, value); else next.delete(key);
    if (key === 'environmentId') next.delete('runtimeId');
    if (next.toString() !== searchParams.toString()) setSearchParams(next, { replace: key === 'path' });
  };

  if (loadingProject || loadingComponent || loadingEnvironments || runtimesLoading || (!!component && !permissionsLoaded)) return <PageContent sx={{ display: 'flex', justifyContent: 'center', py: 8 }}><CircularProgress /></PageContent>;
  if (!component) return <PageContent><Alert severity="error">Integration not found.</Alert></PageContent>;
  if (!isMI) return <PageContent><Alert severity="info">MI Operations is available only for WSO2 Integrator: MI integrations.</Alert><Button sx={{ mt: 2 }} onClick={() => navigate(resourceUrl(scope, 'overview'))}>Back to integration</Button></PageContent>;
  if (!canView) return <PageContent><Alert severity="error">You do not have permission to view MI Operations.</Alert></PageContent>;

  const runtimeOnline = selectedRuntime?.status === 'RUNNING';
  const showConnectionWarning = !!selectedRuntime && !runtimeOnline;
  return <>
    <PageContent>
      <PageTitle><PageTitle.Header>MI Operations</PageTitle.Header></PageTitle>
      <Stack direction={{ xs: 'column', md: 'row' }} gap={2} alignItems={{ md: 'center' }} sx={{ mb: 2 }}>
        <Typography color="text.secondary" sx={{ flex: 1 }}>{component.displayName} - {selectedRuntime ? `${selectedRuntime.runtimeName || selectedRuntime.runtimeId} (${selectedRuntime.status})` : 'No MI runtime available'}</Typography>
        <FormControl size="small" sx={{ minWidth: 220 }}><InputLabel>Environment</InputLabel><Select label="Environment" value={selectedEnvironment?.id || ''} onChange={(event) => updateParam('environmentId', event.target.value)}>{environments.map((environment) => <MenuItem key={environment.id} value={environment.id}>{environment.name}</MenuItem>)}</Select></FormControl>
        <FormControl size="small" sx={{ minWidth: 250 }}><InputLabel>MI runtime</InputLabel><Select label="MI runtime" value={selectedRuntime?.runtimeId || ''} onChange={(event) => updateParam('runtimeId', event.target.value)} disabled={!selectedEnvironment || miRuntimes.length === 0}>{miRuntimes.map((runtime) => <MenuItem key={runtime.runtimeId} value={runtime.runtimeId}>{runtime.runtimeName || runtime.runtimeId} - {runtime.status}</MenuItem>)}</Select></FormControl>
      </Stack>
      {!selectedRuntime && <Alert severity="info" sx={{ mb: 2 }}>No MI runtime is registered in this integration. Register one from <Button size="small" onClick={() => navigate(resourceUrl(scope, 'runtimes'))}>Runtimes</Button>.</Alert>}
      {runtimeQueryError && <Alert severity="error" sx={{ mb: 2 }}>Unable to load MI runtimes: {runtimeQueryError instanceof Error ? runtimeQueryError.message : 'Unknown error'}</Alert>}
      {selectedRuntime && <Box sx={{ borderBottom: 1, borderColor: 'divider', mb: 3 }}><Tabs value={effectiveTab} onChange={(_, value) => updateParam('tab', value)}>
        <Tab value="applications" label="Carbon Applications" icon={<Package size={16} />} iconPosition="start" />
        <Tab value="registry" label="Registry" icon={<FolderArchive size={16} />} iconPosition="start" />
        <Tab value="server" label="Server" icon={<Server size={16} />} iconPosition="start" />
      </Tabs></Box>}
      {effectiveTab === 'applications' && canOpenDeployments && <Button size="small" endIcon={<ExternalLink size={15} />} onClick={() => navigate(resourceUrl({ level: 'organizations', org: scope.org }, 'deployments'))} sx={{ mb: 2 }}>Open bulk Deployments</Button>}
      {showConnectionWarning && <Alert severity="warning">This operation requires a running MI runtime. Select a running runtime to continue.</Alert>}
      {selectedRuntime && !showConnectionWarning && effectiveTab === 'server' && <ServerManagementPanel key={`server-${selectedEnvironment.id}-${selectedRuntime.runtimeId}`} envId={selectedEnvironment.id} projectId={projectId} componentId={component.id} runtimes={miRuntimes} selectedRuntimeId={selectedRuntime.runtimeId} canManage={canManage} />}
      {selectedRuntime && !showConnectionWarning && effectiveTab === 'applications' && <CarbonApplicationsPanel key={`applications-${selectedEnvironment.id}-${selectedRuntime.runtimeId}`} envId={selectedEnvironment.id} projectId={projectId} componentId={component.id} runtimes={miRuntimes} selectedRuntimeId={selectedRuntime.runtimeId} canEdit={canEdit} onSelectArtifact={(artifact, artifactType, envId) => setSelectedArtifact({ artifact, artifactType, envId, componentId: component.id, projectId })} />}
      {selectedRuntime && !showConnectionWarning && effectiveTab === 'registry' && <RegistryBrowser key={`registry-${selectedEnvironment.id}-${selectedRuntime.runtimeId}`} runtimeId={selectedRuntime.runtimeId} selectedRuntimeId={selectedRuntime.runtimeId} componentId={component.id} environmentId={selectedEnvironment.id} projectId={projectId} runtimes={miRuntimes} initialPath={registryPath} canEdit={canEdit} onPathChange={(path) => updateParam('path', path === 'registry' ? '' : path)} />}
    </PageContent>
    <ArtifactDetail selected={selectedArtifact} onClose={() => setSelectedArtifact(null)} />
  </>;
}
