import {
  Alert, Button, Checkbox, Chip, CircularProgress, Dialog, DialogActions, DialogContent,
  DialogContentText, DialogTitle, FormControlLabel, IconButton, Link, ListingTable,
  TablePagination, TextField, Tooltip, Stack, Typography,
} from '@wso2/oxygen-ui';
import { RefreshCw, Trash2, UserPlus } from '@wso2/oxygen-ui-icons-react';
import { useState } from 'react';
import { useCreateMiUser, useDeleteMiUser, useListMiUsers } from '../api/miUsers';

interface RuntimeUsersPanelProps {
  componentId: string;
  runtimeId: string;
  canEdit: boolean;
  runtimeOnline: boolean;
}

export default function RuntimeUsersPanel({ componentId, runtimeId, canEdit, runtimeOnline }: RuntimeUsersPanelProps) {
  const [page, setPage] = useState(0);
  const [rowsPerPage, setRowsPerPage] = useState(25);
  const [createOpen, setCreateOpen] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<{ username: string; domain: string } | null>(null);
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [domain, setDomain] = useState('primary');
  const [isAdmin, setIsAdmin] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [deleteError, setDeleteError] = useState<string | null>(null);
  const usersQuery = useListMiUsers(componentId, runtimeId, rowsPerPage, page * rowsPerPage, runtimeOnline);
  const createMutation = useCreateMiUser();
  const deleteMutation = useDeleteMiUser();
  const data = usersQuery.data;
  const users = data?.items ?? [];
  const unsupported = data?.userStoreStatus === 'UNSUPPORTED_FILE_BASED';

  const closeCreate = () => {
    setCreateOpen(false); setUsername(''); setPassword(''); setDomain('primary'); setIsAdmin(false); setError(null);
  };
  const create = () => {
    setError(null);
    createMutation.mutate({ componentId, runtimeId, username: username.trim(), password, domain: domain.trim() || 'primary', isAdmin }, {
      onSuccess: closeCreate,
      onError: (e) => setError(e.message),
    });
  };
  const remove = () => {
    if (!deleteTarget) return;
    setDeleteError(null);
    deleteMutation.mutate({ componentId, runtimeId, username: deleteTarget.username, domain: deleteTarget.domain }, {
      onSuccess: () => setDeleteTarget(null),
      onError: (e) => setDeleteError(e.message),
    });
  };

  if (!runtimeOnline) return <Alert severity="warning">Runtime Users requires a running MI runtime.</Alert>;
  if (usersQuery.isLoading) return <CircularProgress sx={{ display: 'block', mx: 'auto', my: 5 }} />;
  if (usersQuery.error) return <Alert severity="error" action={<IconButton aria-label="Refresh" onClick={() => void usersQuery.refetch()}><RefreshCw size={16} /></IconButton>}>Failed to load runtime users: {usersQuery.error.message}</Alert>;
  if (unsupported) return <Stack gap={1.5}><Alert severity="info">This runtime uses a file-based user store, so users cannot be managed through the console.</Alert><Typography variant="body2" color="text.secondary">Configure a pluggable MI user store, then refresh this panel.</Typography><Link href="https://mi.docs.wso2.com/en/latest/install-and-setup/setup/user-stores/setting-up-a-userstore-in-mi/" target="_blank" rel="noopener noreferrer">MI user store documentation</Link></Stack>;

  return <Stack gap={2}>
    <Stack direction="row" justifyContent="space-between" alignItems="center">
      <Typography color="text.secondary">{data?.pageInfo.total ?? 0} user(s)</Typography>
      <Stack direction="row" gap={1}>
        <Button size="small" startIcon={<RefreshCw size={15} />} onClick={() => void usersQuery.refetch()}>Refresh</Button>
        {canEdit && <Button size="small" variant="contained" startIcon={<UserPlus size={15} />} onClick={() => setCreateOpen(true)}>Add user</Button>}
      </Stack>
    </Stack>
    {users.length === 0 ? <Typography color="text.secondary" sx={{ py: 4, textAlign: 'center' }}>No users found.</Typography> : <ListingTable>
      <ListingTable.Head><ListingTable.Row><ListingTable.Cell>Username</ListingTable.Cell><ListingTable.Cell>Domain</ListingTable.Cell><ListingTable.Cell>Role</ListingTable.Cell><ListingTable.Cell align="right">Actions</ListingTable.Cell></ListingTable.Row></ListingTable.Head>
      <ListingTable.Body>{users.map((user) => <ListingTable.Row key={`${user.domain}:${user.username}`}>
        <ListingTable.Cell sx={{ fontFamily: 'monospace' }}>{user.username}</ListingTable.Cell>
        <ListingTable.Cell>{user.domain}</ListingTable.Cell>
        <ListingTable.Cell>{user.isAdmin ? <Chip size="small" color="primary" label="Admin" /> : 'User'}</ListingTable.Cell>
        <ListingTable.Cell align="right"><Tooltip title={user.username === 'admin' && user.domain === 'primary' ? 'Cannot delete the default admin user' : `Delete ${user.username}`}><span><IconButton color="error" aria-label={`Delete ${user.username}`} disabled={!canEdit || (user.username === 'admin' && user.domain === 'primary')} onClick={() => setDeleteTarget({ username: user.username, domain: user.domain })}><Trash2 size={16} /></IconButton></span></Tooltip></ListingTable.Cell>
      </ListingTable.Row>)}</ListingTable.Body>
    </ListingTable>}
    <TablePagination component="div" count={data?.pageInfo.total ?? 0} page={page} onPageChange={(_, value) => setPage(value)} rowsPerPage={rowsPerPage} onRowsPerPageChange={(event) => { setRowsPerPage(Number(event.target.value)); setPage(0); }} rowsPerPageOptions={[10, 25, 50]} />
    <Dialog open={createOpen} onClose={closeCreate} maxWidth="xs" fullWidth><DialogTitle>Add Runtime User</DialogTitle><DialogContent><Stack gap={2} sx={{ mt: 1 }}>
      {error && <Alert severity="error">{error}</Alert>}
      <TextField label="Username" required value={username} onChange={(e) => setUsername(e.target.value)} autoFocus />
      <TextField label="Password" required type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
      <TextField label="Domain" value={domain} onChange={(e) => setDomain(e.target.value)} helperText="Use a secondary domain only when configured in MI." />
      <FormControlLabel control={<Checkbox checked={isAdmin} onChange={(e) => setIsAdmin(e.target.checked)} />} label="Admin user" />
    </Stack></DialogContent><DialogActions><Button onClick={closeCreate}>Cancel</Button><Button variant="contained" onClick={create} disabled={!username.trim() || !password.trim() || createMutation.isPending}>Create</Button></DialogActions></Dialog>
    <Dialog open={deleteTarget !== null} onClose={() => { setDeleteTarget(null); setDeleteError(null); }} maxWidth="xs" fullWidth><DialogTitle>Delete User</DialogTitle><DialogContent>{deleteError && <Alert severity="error" sx={{ mb: 2 }}>{deleteError}</Alert>}<DialogContentText>Delete <strong>{deleteTarget?.username}</strong> from the runtime? This action cannot be undone.</DialogContentText></DialogContent><DialogActions><Button onClick={() => setDeleteTarget(null)}>Cancel</Button><Button color="error" variant="contained" onClick={remove} disabled={deleteMutation.isPending}>Delete</Button></DialogActions></Dialog>
  </Stack>;
}
