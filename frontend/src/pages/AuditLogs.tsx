import { Alert, Box, Button, CircularProgress, Drawer, IconButton, ListingTable, PageContent, PageTitle, Stack, TablePagination, TextField, Typography } from '@wso2/oxygen-ui';
import { RefreshCw, X } from '@wso2/oxygen-ui-icons-react';
import { useMemo, useState, useEffect, type JSX } from 'react';
import { useAuditLogs, type GqlAuditLog } from '../api/queries';
import type { OrgScope } from '../nav';
import { useAccessControl } from '../contexts/AccessControlContext';
import { Permissions } from '../constants/permissions';
import { notAuthorizedUrl } from '../paths';
import { useNavigate } from 'react-router';

const ACTIONS = ['LOGIN_SUCCESS', 'LOGIN_FAILURE', 'LOGOUT', 'PASSWORD_CHANGE', 'USER_CREATE', 'USER_DELETE', 'GROUP_CREATE', 'GROUP_UPDATE', 'GROUP_DELETE', 'ROLE_CREATE', 'ROLE_UPDATE', 'ROLE_DELETE', 'PROJECT_CREATE', 'PROJECT_UPDATE', 'PROJECT_DELETE', 'COMPONENT_CREATE', 'COMPONENT_UPDATE', 'COMPONENT_DELETE', 'COMPOSITE_APP_UPLOAD', 'COMPOSITE_APP_DELETE', 'REGISTRY_RESOURCE_CREATE', 'REGISTRY_RESOURCE_UPDATE', 'REGISTRY_RESOURCE_DELETE', 'REGISTRY_PROPERTIES_UPDATE', 'SERVER_RESTART', 'SERVER_RESTART_GRACEFULLY', 'SERVER_SHUTDOWN', 'SERVER_SHUTDOWN_GRACEFULLY'];
const RESOURCE_TYPES = ['SESSION', 'USER', 'GROUP', 'ROLE', 'PROJECT', 'COMPONENT', 'ENVIRONMENT', 'RUNTIME', 'ARTIFACT', 'COMPOSITE_APP', 'REGISTRY_RESOURCE', 'SECRET', 'LOGGER', 'LISTENER'];

function isoDate(date: Date): string {
  return date.toISOString().slice(0, 10);
}

export default function AuditLogs(scope: OrgScope): JSX.Element {
  const navigate = useNavigate();
  const { hasOrgPermission, isOrgPermissionsLoaded } = useAccessControl();
  useEffect(() => {
    if (isOrgPermissionsLoaded && !hasOrgPermission(Permissions.AUDIT_VIEW)) navigate(notAuthorizedUrl(), { replace: true });
  }, [hasOrgPermission, isOrgPermissionsLoaded, navigate]);
  const today = new Date();
  const initialStart = new Date(today.getTime() - 7 * 86400000);
  const [startDate, setStartDate] = useState(isoDate(initialStart));
  const [endDate, setEndDate] = useState(isoDate(today));
  const [action, setAction] = useState('');
  const [resourceType, setResourceType] = useState('');
  const [actor, setActor] = useState('');
  const [search, setSearch] = useState('');
  const [page, setPage] = useState(0);
  const [rowsPerPage, setRowsPerPage] = useState(25);
  const [selected, setSelected] = useState<GqlAuditLog | null>(null);

  const filter = useMemo(() => ({
    ...(action ? { actions: [action] } : {}),
    ...(resourceType ? { resourceTypes: [resourceType] } : {}),
    ...(actor.trim() ? { actor: actor.trim() } : {}),
    ...(search.trim() ? { search: search.trim() } : {}),
    startTime: `${startDate}T00:00:00Z`,
    endTime: `${endDate}T23:59:59Z`,
  }), [action, resourceType, actor, search, startDate, endDate]);
  const { data, isLoading, isError, refetch } = useAuditLogs(scope.org, filter, rowsPerPage, page * rowsPerPage);
  if (isOrgPermissionsLoaded && !hasOrgPermission(Permissions.AUDIT_VIEW)) return <></>;
  const logs = data?.items ?? [];
  const total = data?.pageInfo.total ?? 0;

  return (
    <PageContent>
      <PageTitle>
        <PageTitle.Header>Audit Logs</PageTitle.Header>
      </PageTitle>
      <Box sx={{ display: 'grid', gridTemplateColumns: { xs: '1fr', md: 'repeat(2, minmax(0, 1fr))', lg: '145px 145px minmax(180px, 1.2fr) minmax(150px, 1fr) minmax(160px, 1fr) minmax(200px, 1.2fr) auto' }, gap: 1, mb: 2, alignItems: 'center' }}>
        <TextField label="From" type="date" value={startDate} onChange={(e) => { setStartDate(e.target.value); setPage(0); }} InputLabelProps={{ shrink: true }} size="small" fullWidth />
        <TextField label="To" type="date" value={endDate} onChange={(e) => { setEndDate(e.target.value); setPage(0); }} InputLabelProps={{ shrink: true }} size="small" fullWidth />
        <TextField select label="Action" value={action} onChange={(e) => { setAction(e.target.value); setPage(0); }} size="small" fullWidth InputLabelProps={{ shrink: true }} SelectProps={{ native: true }}>
          <option value="">All actions</option>{ACTIONS.map((item) => <option key={item} value={item}>{item}</option>)}
        </TextField>
        <TextField select label="Resource" value={resourceType} onChange={(e) => { setResourceType(e.target.value); setPage(0); }} size="small" fullWidth InputLabelProps={{ shrink: true }} SelectProps={{ native: true }}>
          <option value="">All resources</option>{RESOURCE_TYPES.map((item) => <option key={item} value={item}>{item}</option>)}
        </TextField>
        <TextField label="Actor" value={actor} onChange={(e) => { setActor(e.target.value); setPage(0); }} size="small" fullWidth placeholder="Username" InputLabelProps={{ shrink: true }} />
        <TextField label="Search" value={search} onChange={(e) => { setSearch(e.target.value); setPage(0); }} size="small" fullWidth placeholder="Details or resource ID" InputLabelProps={{ shrink: true }} />
        <Button startIcon={<RefreshCw size={16} />} onClick={() => refetch()} variant="outlined" sx={{ whiteSpace: 'nowrap', justifySelf: { xs: 'start', lg: 'stretch' } }}>Refresh</Button>
      </Box>
      {isLoading ? <Box sx={{ display: 'flex', justifyContent: 'center', py: 8 }}><CircularProgress /></Box> : isError ? <Alert severity="error">Unable to load audit logs. <Button onClick={() => refetch()}>Try again</Button></Alert> : logs.length === 0 ? <Alert severity="info">No audit records found for the selected filters.</Alert> : (
        <>
          <ListingTable>
            <ListingTable.Head><ListingTable.Row><ListingTable.Cell>Date</ListingTable.Cell><ListingTable.Cell>Actor</ListingTable.Cell><ListingTable.Cell>Action</ListingTable.Cell><ListingTable.Cell>Resource</ListingTable.Cell><ListingTable.Cell>Description</ListingTable.Cell></ListingTable.Row></ListingTable.Head>
            <ListingTable.Body>{logs.map((log) => <ListingTable.Row key={log.id} hover onClick={() => setSelected(log)} sx={{ cursor: 'pointer' }}><ListingTable.Cell>{new Date(log.timestamp).toLocaleString()}</ListingTable.Cell><ListingTable.Cell>{log.actorUsername || log.actorUserId || 'System'}</ListingTable.Cell><ListingTable.Cell>{log.action}</ListingTable.Cell><ListingTable.Cell>{log.resourceType ? `${log.resourceType}${log.resourceId ? `: ${log.resourceId}` : ''}` : '—'}</ListingTable.Cell><ListingTable.Cell>{log.details || '—'}</ListingTable.Cell></ListingTable.Row>)}</ListingTable.Body>
          </ListingTable>
          <TablePagination component="div" count={total} page={page} onPageChange={(_, value) => setPage(value)} rowsPerPage={rowsPerPage} onRowsPerPageChange={(e) => { setRowsPerPage(Number(e.target.value)); setPage(0); }} rowsPerPageOptions={[10, 25, 50, 100]} />
        </>
      )}
      <Drawer anchor="right" open={!!selected} onClose={() => setSelected(null)}><Box sx={{ width: { xs: '85vw', sm: 460 }, p: 3 }}>
        <Stack direction="row" justifyContent="space-between" alignItems="center"><Typography variant="h6">Audit event</Typography><IconButton onClick={() => setSelected(null)}><X size={20} /></IconButton></Stack>
        {selected && <Stack spacing={1.5} sx={{ mt: 3 }}>{[['Date', new Date(selected.timestamp).toLocaleString()], ['Actor', selected.actorUsername || selected.actorUserId || 'System'], ['Action', selected.action], ['Resource type', selected.resourceType], ['Resource ID', selected.resourceId], ['Details', selected.details], ['Client IP', selected.clientIp], ['User agent', selected.userAgent]].map(([label, value]) => <Box key={label}><Typography variant="caption" color="text.secondary">{label}</Typography><Typography sx={{ wordBreak: 'break-word' }}>{value || '—'}</Typography></Box>)}</Stack>}
      </Box></Drawer>
    </PageContent>
  );
}
