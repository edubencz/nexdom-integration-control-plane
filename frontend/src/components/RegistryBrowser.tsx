/**
 * Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
 *
 * WSO2 LLC. licenses this file under the Apache License, Version 2.0.
 */
/** Registry browser and runtime-scoped Registry Resource controls. */
import { type JSX, useEffect, useRef, useState } from 'react';
import { Box, CircularProgress, Typography, Alert, Button, Stack, Dialog, DialogTitle, DialogContent, DialogActions, TextField, MenuItem, Select, FormControl, InputLabel } from '@wso2/oxygen-ui';
import { ArrowUp, Plus } from '@wso2/oxygen-ui-icons-react';
import { useQueryClient } from '@tanstack/react-query';
import { useRegistryNavigation } from '../hooks/useRegistryNavigation';
import { useRegistryDirectory, type GqlRegistryDirectoryItem } from '../api/queries';
import { createRegistryResource, deleteRegistryResource } from '../api/registry';
import { useAccessControl } from '../contexts/AccessControlContext';
import { Permissions } from '../constants/permissions';
import { RegistryBreadcrumb } from './RegistryBreadcrumb';
import { RegistryDirectoryView } from './RegistryDirectoryView';
import { RegistryFileViewer } from './RegistryFileViewer';

interface RegistryBrowserProps {
  runtimeId: string;
  componentId: string;
  environmentId: string;
  projectId?: string;
  runtimes?: Array<{ runtimeId: string; runtimeName?: string; status?: string }>;
  initialPath?: string;
}

export function RegistryBrowser({ runtimeId, componentId, environmentId, projectId, runtimes = [], initialPath = 'registry', selectedRuntimeId: controlledRuntimeId, canEdit: controlledCanEdit, onPathChange }: RegistryBrowserProps & { selectedRuntimeId?: string; canEdit?: boolean; onPathChange?: (path: string) => void }): JSX.Element {
  const availableRuntimes = runtimes.length > 0 ? runtimes : [{ runtimeId, runtimeName: runtimeId, status: 'RUNNING' }];
  const defaultRuntime = availableRuntimes.find((item) => item.status === 'RUNNING')?.runtimeId || runtimeId;
  const [selectedRuntimeId, setSelectedRuntimeId] = useState(defaultRuntime);
  const effectiveRuntimeId = controlledRuntimeId ?? selectedRuntimeId;
  const selectedRuntime = availableRuntimes.find((item) => item.runtimeId === effectiveRuntimeId);
  const { currentPath, pathSegments, navigateToPath, navigateToSegment, navigateInto, navigateUp } = useRegistryNavigation(initialPath);
  const lastInitialPath = useRef<string | null>(null);
  useEffect(() => { onPathChange?.(currentPath); }, [currentPath, onPathChange]);

  // `currentPath` is local state and changes immediately when the user clicks
  // a directory. The parent then persists that path in the URL and sends it
  // back as `initialPath`. If this effect also depends on `currentPath`, it can
  // observe the old URL value in the same render and navigate back to the old
  // directory, creating a config <-> registry loop. Sync only when the URL
  // value itself changes; local navigation remains authoritative until then.
  useEffect(() => {
    const normalized = initialPath.startsWith('/') ? initialPath.slice(1) : initialPath;
    if (lastInitialPath.current === normalized) return;
    lastInitialPath.current = normalized;
    const valid = normalized === 'registry' || /^registry\/(config|governance)(\/|$)/.test(normalized);
    if (valid && normalized !== currentPath) navigateToPath(normalized);
    if (!valid && currentPath !== 'registry') navigateToSegment(-1);
  }, [currentPath, initialPath, navigateToPath, navigateToSegment]);
  const [selectedFile, setSelectedFile] = useState<{ item: GqlRegistryDirectoryItem; path: string } | null>(null);
  const [addOpen, setAddOpen] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<{ name: string; path: string } | null>(null);
  const [resourceName, setResourceName] = useState('');
  const [mediaType, setMediaType] = useState('text/plain');
  const [resourceContent, setResourceContent] = useState('');
  const [resourceFile, setResourceFile] = useState<File | null>(null);
  const [mutationError, setMutationError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const queryClient = useQueryClient();
  const { hasAnyPermission } = useAccessControl();
  const canEdit = controlledCanEdit ?? hasAnyPermission([Permissions.INTEGRATION_EDIT, Permissions.INTEGRATION_MANAGE], projectId, componentId);
  const { data: directoryData, isLoading, error } = useRegistryDirectory(effectiveRuntimeId, currentPath, false);

  const refreshRegistry = () => {
    void queryClient.invalidateQueries({ queryKey: ['registryDirectory'] });
    void queryClient.invalidateQueries({ queryKey: ['registryFileContent'] });
    void queryClient.invalidateQueries({ queryKey: ['registryResourceProperties'] });
    void queryClient.invalidateQueries({ queryKey: ['registryResourceMetadata'] });
  };
  const handleRuntimeChange = (nextRuntimeId: string) => { setSelectedRuntimeId(nextRuntimeId); setSelectedFile(null); navigateToSegment(-1); setMutationError(null); };
  const handleSelectFile = (item: GqlRegistryDirectoryItem) => setSelectedFile({ item, path: `${currentPath}/${item.name}` });
  const isAtRoot = pathSegments.length === 1 && pathSegments[0] === 'registry';

  const submitCreate = async () => {
    const trimmedName = resourceName.trim();
    if (!trimmedName || !mediaType.trim() || isAtRoot) return;
    setBusy(true); setMutationError(null);
    try {
      await createRegistryResource(componentId, environmentId, effectiveRuntimeId, `${currentPath}/${trimmedName}`, mediaType.trim(), resourceFile || resourceContent, trimmedName);
      setAddOpen(false); setResourceName(''); setResourceContent(''); setResourceFile(null); refreshRegistry();
    } catch (e) { setMutationError(e instanceof Error ? e.message : 'Failed to create Registry Resource.'); }
    finally { setBusy(false); }
  };
  const confirmDelete = async () => {
    if (!deleteTarget) return;
    setBusy(true); setMutationError(null);
    try { await deleteRegistryResource(componentId, environmentId, effectiveRuntimeId, deleteTarget.path); setDeleteTarget(null); setSelectedFile(null); refreshRegistry(); }
    catch (e) { setMutationError(e instanceof Error ? e.message : 'Failed to delete Registry Resource.'); }
    finally { setBusy(false); }
  };

  return <Box sx={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
    <Stack direction="row" alignItems="center" spacing={2} sx={{ mb: 2, flexWrap: 'wrap' }}>
      {!isAtRoot && <Button variant="text" size="small" startIcon={<ArrowUp size={16} />} onClick={navigateUp}>Up</Button>}
      <Box sx={{ flex: 1 }}><RegistryBreadcrumb pathSegments={pathSegments} onNavigate={(index) => navigateToSegment(index)} /></Box>
      {!controlledRuntimeId && <FormControl size="small" sx={{ minWidth: 220 }}>
        <InputLabel id="registry-runtime-label">Runtime</InputLabel>
        <Select labelId="registry-runtime-label" label="Runtime" value={selectedRuntimeId} onChange={(event) => handleRuntimeChange(event.target.value as string)}>
          {availableRuntimes.map((runtime) => <MenuItem key={runtime.runtimeId} value={runtime.runtimeId} disabled={runtime.status !== 'RUNNING'}>{runtime.runtimeName || runtime.runtimeId}{runtime.status !== 'RUNNING' ? ` (${runtime.status || 'offline'})` : ''}</MenuItem>)}
        </Select>
      </FormControl>}
      {canEdit && <Button variant="contained" size="small" startIcon={<Plus size={16} />} onClick={() => setAddOpen(true)} disabled={isAtRoot || selectedRuntime?.status !== 'RUNNING'}>Add Resource</Button>}
    </Stack>
    {mutationError && <Alert severity="error" sx={{ mb: 2 }} onClose={() => setMutationError(null)}>{mutationError}</Alert>}
    {error ? <Alert severity="error" sx={{ mb: 2 }}>Failed to load registry directory: {error instanceof Error ? error.message : 'Unknown error'}</Alert> : null}
    {isLoading ? <Box sx={{ display: 'flex', justifyContent: 'center', py: 8 }}><CircularProgress /></Box> : directoryData ? <>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>{directoryData.count} item{directoryData.count !== 1 ? 's' : ''}</Typography>
      <RegistryDirectoryView items={directoryData.items} onNavigateInto={navigateInto} onSelectFile={handleSelectFile} canEdit={canEdit} onDeleteFile={(item) => setDeleteTarget({ name: item.name, path: `${currentPath}/${item.name}` })} />
    </> : <Typography color="text.secondary" sx={{ py: 4, textAlign: 'center' }}>No data available</Typography>}
    {selectedFile && <RegistryFileViewer runtimeId={effectiveRuntimeId} componentId={componentId} environmentId={environmentId} filePath={selectedFile.path} item={selectedFile.item} onClose={() => setSelectedFile(null)} canEdit={canEdit} onChanged={refreshRegistry} />}
    <Dialog open={addOpen} onClose={() => !busy && setAddOpen(false)} fullWidth maxWidth="sm">
      <DialogTitle>Add Registry Resource</DialogTitle><DialogContent><Stack spacing={2} sx={{ pt: 1 }}>
        <Typography variant="body2" color="text.secondary">Create under {currentPath} on {selectedRuntime?.runtimeName || selectedRuntimeId}.</Typography>
        <TextField label="Resource name" value={resourceName} onChange={(event) => setResourceName(event.target.value)} required fullWidth autoFocus />
        <TextField label="Media type" value={mediaType} onChange={(event) => setMediaType(event.target.value)} helperText="Examples: text/plain, application/json, image/png" fullWidth required />
        {mediaType === 'application/octet-stream' ? <Button component="label" variant="outlined">{resourceFile ? resourceFile.name : 'Choose binary file'}<input hidden type="file" onChange={(event) => setResourceFile(event.target.files?.[0] || null)} /></Button> : <TextField label="Content" value={resourceContent} onChange={(event) => setResourceContent(event.target.value)} multiline minRows={8} fullWidth />}
      </Stack></DialogContent><DialogActions><Button onClick={() => setAddOpen(false)} disabled={busy}>Cancel</Button><Button variant="contained" onClick={() => void submitCreate()} disabled={busy || !resourceName.trim() || !mediaType.trim()}>Create</Button></DialogActions>
    </Dialog>
    <Dialog open={deleteTarget !== null} onClose={() => !busy && setDeleteTarget(null)}><DialogTitle>Delete Registry Resource</DialogTitle><DialogContent><Typography>Delete <strong>{deleteTarget?.name}</strong> from runtime <strong>{selectedRuntime?.runtimeName || selectedRuntimeId}</strong>?</Typography></DialogContent><DialogActions><Button onClick={() => setDeleteTarget(null)} disabled={busy}>Cancel</Button><Button color="error" variant="contained" onClick={() => void confirmDelete()} disabled={busy}>Delete</Button></DialogActions></Dialog>
  </Box>;
}
