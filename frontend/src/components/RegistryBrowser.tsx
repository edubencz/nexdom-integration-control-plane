/**
 * Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
 * Licensed under the Apache License, Version 2.0.
 */

import { type JSX, useEffect, useState } from 'react';
import { Alert, Autocomplete, Box, Button, CircularProgress, Dialog, DialogActions, DialogContent, DialogTitle, FormControl, InputLabel, MenuItem, Select, Stack, TextField, Typography } from '@wso2/oxygen-ui';
import { ArrowUp, Plus, RefreshCw } from '@wso2/oxygen-ui-icons-react';
import { useQueryClient } from '@tanstack/react-query';
import { useRegistryNavigation } from '../hooks/useRegistryNavigation';
import { useRegistryDirectory, useRegistryResourceSearch, type GqlRegistryDirectoryItem, type GqlRegistryDirectoryResponse } from '../api/queries';
import { createRegistryResource, deleteRegistryResource, downloadRegistryResource } from '../api/registry';
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
  onDirtyChange?: (dirty: boolean) => void;
}

type CreateMode = 'text' | 'file';

type MediaTypeOption = {
  value: string;
  label: string;
  group: string;
};

const CUSTOM_MEDIA_TYPE = '__custom__';

const mediaTypeOptions: MediaTypeOption[] = [
  { value: 'text/plain', label: 'Plain text', group: 'Text' },
  { value: 'text/csv', label: 'CSV', group: 'Text' },
  { value: 'text/html', label: 'HTML', group: 'Text' },
  { value: 'text/css', label: 'CSS', group: 'Text' },
  { value: 'text/javascript', label: 'JavaScript', group: 'Text' },
  { value: 'application/json', label: 'JSON', group: 'Data' },
  { value: 'application/xml', label: 'XML', group: 'Data' },
  { value: 'application/yaml', label: 'YAML', group: 'Data' },
  { value: 'application/graphql', label: 'GraphQL', group: 'Data' },
  { value: 'application/pdf', label: 'PDF', group: 'Documents' },
  { value: 'application/rtf', label: 'Rich Text Format', group: 'Documents' },
  { value: 'image/png', label: 'PNG image', group: 'Images' },
  { value: 'image/jpeg', label: 'JPEG image', group: 'Images' },
  { value: 'image/gif', label: 'GIF image', group: 'Images' },
  { value: 'image/svg+xml', label: 'SVG image', group: 'Images' },
  { value: 'audio/mpeg', label: 'MP3 audio', group: 'Audio and video' },
  { value: 'video/mp4', label: 'MP4 video', group: 'Audio and video' },
  { value: 'application/zip', label: 'ZIP archive', group: 'Archives' },
  { value: 'application/gzip', label: 'GZIP archive', group: 'Archives' },
  { value: 'application/octet-stream', label: 'Binary data', group: 'Other' },
  { value: CUSTOM_MEDIA_TYPE, label: 'Custom media type…', group: 'Other' },
];

function inferMediaType(file: File): string {
  if (file.type) return file.type;
  const extension = file.name.split('.').pop()?.toLowerCase();
  const knownTypes: Record<string, string> = {
    json: 'application/json',
    xml: 'application/xml',
    yaml: 'application/yaml',
    yml: 'application/yaml',
    properties: 'text/plain',
    txt: 'text/plain',
    csv: 'text/csv',
    pdf: 'application/pdf',
    png: 'image/png',
    jpg: 'image/jpeg',
    jpeg: 'image/jpeg',
    gif: 'image/gif',
  };
  return extension ? knownTypes[extension] || 'application/octet-stream' : 'application/octet-stream';
}

function validateRegistryResourceName(name: string): string | null {
  if (!name) return null;
  if (/\s/.test(name)) return 'Spaces are not supported in MI Registry resource names. Use a name such as certificate.cer.';
  if (/[\\/]/.test(name)) return 'Slashes are not allowed in the resource name.';
  if (name.includes('..')) return 'The resource name cannot contain ..';
  return null;
}

export function RegistryBrowser({ runtimeId, componentId, environmentId, projectId, runtimes = [], initialPath = 'registry', onDirtyChange }: RegistryBrowserProps): JSX.Element {
  const availableRuntimes = runtimes.length > 0 ? runtimes : [{ runtimeId, runtimeName: runtimeId, status: 'RUNNING' }];
  const defaultRuntime = availableRuntimes.find((item) => item.status === 'RUNNING')?.runtimeId || runtimeId;
  const [selectedRuntimeId, setSelectedRuntimeId] = useState(defaultRuntime);
  const selectedRuntime = availableRuntimes.find((item) => item.runtimeId === selectedRuntimeId);
  const { currentPath, pathSegments, navigateToSegment, navigateInto, navigateUp, navigateToPath } = useRegistryNavigation(initialPath);
  const [selectedFile, setSelectedFile] = useState<{ item: GqlRegistryDirectoryItem; path: string } | null>(null);
  const [mobileDetail, setMobileDetail] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [addOpen, setAddOpen] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<{ name: string; path: string } | null>(null);
  const [resourceName, setResourceName] = useState('');
  const [mediaType, setMediaType] = useState('text/plain');
  const [customMediaType, setCustomMediaType] = useState(false);
  const [createMode, setCreateMode] = useState<CreateMode>('text');
  const [resourceContent, setResourceContent] = useState('');
  const [resourceFile, setResourceFile] = useState<File | null>(null);
  const [mutationError, setMutationError] = useState<string | null>(null);
  const [mutationSuccess, setMutationSuccess] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [detailDirty, setDetailDirty] = useState(false);
  const [pendingSelection, setPendingSelection] = useState<{ item: GqlRegistryDirectoryItem; path: string } | null>(null);
  const queryClient = useQueryClient();
  const { hasAnyPermission } = useAccessControl();
  const canEdit = hasAnyPermission([Permissions.INTEGRATION_EDIT, Permissions.INTEGRATION_MANAGE], projectId, componentId);
  const resourceNameError = validateRegistryResourceName(resourceName.trim());
  const { data: directoryData, isLoading: isDirectoryLoading, error: directoryError } = useRegistryDirectory(selectedRuntimeId, currentPath, false);
  const hasSearch = debouncedSearch.length >= 2;
  const { data: searchData, isLoading: isSearchLoading, error: searchError } = useRegistryResourceSearch(selectedRuntimeId, currentPath, debouncedSearch, hasSearch);
  const isAtRoot = pathSegments.length === 1 && pathSegments[0] === 'registry';
  const canCreateInCurrentPath = currentPath === 'registry/config' || currentPath.startsWith('registry/config/') || currentPath === 'registry/governance' || currentPath.startsWith('registry/governance/');

  useEffect(() => {
    const timer = window.setTimeout(() => setDebouncedSearch(searchQuery.trim()), 300);
    return () => window.clearTimeout(timer);
  }, [searchQuery]);

  useEffect(() => {
    onDirtyChange?.(detailDirty);
  }, [detailDirty, onDirtyChange]);

  const refreshRegistry = () => {
    void queryClient.invalidateQueries({ queryKey: ['registryDirectory'] });
    void queryClient.invalidateQueries({ queryKey: ['registryResourceSearch'] });
    void queryClient.invalidateQueries({ queryKey: ['registryFileContent'] });
    void queryClient.invalidateQueries({ queryKey: ['registryResourceProperties'] });
    void queryClient.invalidateQueries({ queryKey: ['registryResourceMetadata'] });
  };

  const handleRuntimeChange = (nextRuntimeId: string) => {
    if (detailDirty && !window.confirm('Discard unsaved resource changes?')) return;
    setSelectedRuntimeId(nextRuntimeId);
    setSelectedFile(null);
    setMobileDetail(false);
    setSearchQuery('');
    setDebouncedSearch('');
    setDetailDirty(false);
    navigateToSegment(-1);
    setMutationError(null);
  };

  const applySelection = (next: { item: GqlRegistryDirectoryItem; path: string }) => {
    setSelectedFile(next);
    setMobileDetail(true);
    setPendingSelection(null);
    setDetailDirty(false);
  };
  const requestSelection = (next: { item: GqlRegistryDirectoryItem; path: string }) => {
    if (detailDirty) {
      setPendingSelection(next);
      return;
    }
    applySelection(next);
  };
  const confirmPendingSelection = (discard: boolean) => {
    if (discard && pendingSelection) applySelection(pendingSelection);
    else setPendingSelection(null);
  };
  const handleSelectFile = (item: GqlRegistryDirectoryItem) => requestSelection({ item, path: item.path || `${currentPath}/${item.name}` });
  const handleNavigateInto = (itemName: string) => {
    if (detailDirty) {
      setPendingSelection(null);
      if (!window.confirm('Discard unsaved resource changes?')) return;
      setDetailDirty(false);
    }
    navigateInto(itemName);
    setSelectedFile(null);
    setMobileDetail(false);
  };
  const handleSearchNavigate = (item: GqlRegistryDirectoryItem) => {
    if (item.isDirectory) {
      navigateToPath(item.path || currentPath);
      setSelectedFile(null);
      setSearchQuery('');
      setMobileDetail(false);
    } else handleSelectFile(item);
  };

  const resetCreateForm = () => {
    setResourceName('');
    setMediaType('text/plain');
    setCustomMediaType(false);
    setCreateMode('text');
    setResourceContent('');
    setResourceFile(null);
  };
  const submitCreate = async () => {
    const trimmedName = resourceName.trim();
    if (!trimmedName || resourceNameError || !mediaType.trim() || !canCreateInCurrentPath || (createMode === 'file' && !resourceFile)) return;
    setBusy(true);
    setMutationError(null);
    setMutationSuccess(null);
    try {
      await createRegistryResource(componentId, environmentId, selectedRuntimeId, `${currentPath}/${trimmedName}`, mediaType.trim(), createMode === 'file' ? resourceFile || new Blob() : resourceContent, trimmedName);
      queryClient.setQueryData<GqlRegistryDirectoryResponse>(['registryDirectory', selectedRuntimeId, currentPath, false], (current) =>
        current
          ? {
              ...current,
              count: current.count + 1,
              items: [...current.items, { name: trimmedName, mediaType: mediaType.trim(), isDirectory: false, properties: [] }],
            }
          : current,
      );
      setAddOpen(false);
      resetCreateForm();
      refreshRegistry();
      setMutationSuccess('Resource creation requested. The runtime may take up to its configured cachableDuration to reflect the change.');
    } catch (e) {
      setMutationError(e instanceof Error ? e.message : 'Failed to create Registry Resource.');
    } finally {
      setBusy(false);
    }
  };

  const confirmDelete = async () => {
    if (!deleteTarget) return;
    setBusy(true);
    setMutationError(null);
    setMutationSuccess(null);
    try {
      await deleteRegistryResource(componentId, environmentId, selectedRuntimeId, deleteTarget.path);
      queryClient.setQueryData<GqlRegistryDirectoryResponse>(['registryDirectory', selectedRuntimeId, currentPath, false], (current) => {
        if (!current) return current;
        const nextItems = current.items.filter((item) => (item.path || `${currentPath}/${item.name}`) !== deleteTarget.path);
        return { ...current, count: nextItems.length, items: nextItems };
      });
      setDeleteTarget(null);
      setSelectedFile(null);
      setMobileDetail(false);
      refreshRegistry();
      setMutationSuccess('Resource deletion requested. The runtime may take up to its configured cachableDuration to reflect the change.');
    } catch (e) {
      setMutationError(e instanceof Error ? e.message : 'Failed to delete Registry Resource.');
    } finally {
      setBusy(false);
    }
  };

  const handleDownloadFile = async (item: GqlRegistryDirectoryItem) => {
    const path = item.path || `${currentPath}/${item.name}`;
    try {
      const blob = await downloadRegistryResource(componentId, environmentId, selectedRuntimeId, path);
      const url = window.URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = item.name;
      link.click();
      window.URL.revokeObjectURL(url);
    } catch (e) {
      setMutationError(e instanceof Error ? e.message : 'Unable to download resource.');
    }
  };

  const searchItems: GqlRegistryDirectoryItem[] = (searchData?.items || []).map((item) => ({ ...item, properties: [], path: item.path }));
  const items = hasSearch ? searchItems : directoryData?.items || [];
  const isLoading = hasSearch ? isSearchLoading : isDirectoryLoading;
  const error = hasSearch ? searchError : directoryError;

  return (
    <Box sx={{ height: '100%', display: 'flex', flexDirection: 'column', minHeight: 0 }}>
      <Stack spacing={1.25} sx={{ flexShrink: 0, mb: 1.5 }}>
        <Stack direction={{ xs: 'column', sm: 'row' }} alignItems={{ sm: 'center' }} spacing={1}>
          <FormControl size="small" sx={{ minWidth: 220 }}>
            <InputLabel id="registry-runtime-label">Runtime</InputLabel>
            <Select labelId="registry-runtime-label" label="Runtime" value={selectedRuntimeId} onChange={(event) => handleRuntimeChange(event.target.value as string)}>
              {availableRuntimes.map((runtime) => (
                <MenuItem key={runtime.runtimeId} value={runtime.runtimeId} disabled={runtime.status !== 'RUNNING'}>
                  {runtime.runtimeName || runtime.runtimeId}
                  {runtime.status !== 'RUNNING' ? ` (${runtime.status || 'offline'})` : ''}
                </MenuItem>
              ))}
            </Select>
          </FormControl>
          <Button variant="outlined" size="small" startIcon={<RefreshCw size={16} />} onClick={refreshRegistry} disabled={isLoading}>
            Refresh
          </Button>
          <Box sx={{ flex: 1 }} />
          {canEdit && (
            <Button
              variant="contained"
              size="small"
              startIcon={<Plus size={16} />}
              onClick={() => {
                setMutationError(null);
                setAddOpen(true);
              }}
              disabled={!canCreateInCurrentPath || selectedRuntime?.status !== 'RUNNING'}
              title={!canCreateInCurrentPath ? 'Choose a directory below registry/config or registry/governance before creating a resource' : undefined}>
              Add Resource
            </Button>
          )}
        </Stack>
        <Stack direction="row" alignItems="center" spacing={1} sx={{ minWidth: 0 }}>
          {!isAtRoot && (
            <Button
              variant="text"
              size="small"
              startIcon={<ArrowUp size={16} />}
              onClick={() => {
                if (!detailDirty || window.confirm('Discard unsaved resource changes?')) {
                  navigateUp();
                  setSelectedFile(null);
                  setMobileDetail(false);
                  setDetailDirty(false);
                }
              }}>
              Up
            </Button>
          )}
          <Box sx={{ flex: 1, minWidth: 0 }}>
            <RegistryBreadcrumb
              pathSegments={pathSegments}
              onNavigate={(index) => {
                if (!detailDirty || window.confirm('Discard unsaved resource changes?')) {
                  navigateToSegment(index);
                  setSelectedFile(null);
                  setMobileDetail(false);
                  setDetailDirty(false);
                }
              }}
            />
          </Box>
        </Stack>
        <TextField size="small" value={searchQuery} onChange={(event) => setSearchQuery(event.target.value)} placeholder="Search this folder and descendants" inputProps={{ 'aria-label': 'Search Registry Resources' }} />
      </Stack>
      {mutationError && (
        <Alert severity="error" sx={{ mb: 1.5 }} onClose={() => setMutationError(null)}>
          {mutationError}
        </Alert>
      )}
      {mutationSuccess && (
        <Alert severity="success" sx={{ mb: 1.5 }} onClose={() => setMutationSuccess(null)}>
          {mutationSuccess}
        </Alert>
      )}
      <Box sx={{ display: 'flex', flex: 1, minHeight: 0, gap: 2 }}>
        <Box sx={{ display: { xs: selectedFile && mobileDetail ? 'none' : 'block', lg: 'block' }, flex: { xs: '1 1 100%', lg: '0 0 43%' }, minWidth: 0, overflow: 'auto' }}>
          {error ? (
            <Alert
              severity="error"
              action={
                <Button size="small" onClick={refreshRegistry}>
                  Retry
                </Button>
              }>
              Failed to load registry resources: {error instanceof Error ? error.message : 'Unknown error'}
            </Alert>
          ) : isLoading ? (
            <Box sx={{ display: 'flex', justifyContent: 'center', py: 8 }}>
              <CircularProgress />
            </Box>
          ) : hasSearch && items.length === 0 ? (
            <Typography color="text.secondary" sx={{ py: 8, textAlign: 'center' }}>
              No resources match “{debouncedSearch}”.
            </Typography>
          ) : directoryData || hasSearch ? (
            <>
              <Typography variant="body2" color="text.secondary" sx={{ mb: 1 }}>
                {hasSearch ? searchData?.count || 0 : directoryData?.count || 0} item{items.length !== 1 ? 's' : ''}
                {hasSearch ? ' found' : ''}
              </Typography>
              <RegistryDirectoryView
                items={items}
                onNavigateInto={
                  hasSearch
                    ? (name) => {
                        const found = items.find((item) => item.name === name);
                        if (found) handleSearchNavigate(found);
                      }
                    : handleNavigateInto
                }
                onSelectFile={hasSearch ? handleSearchNavigate : handleSelectFile}
                canEdit={canEdit}
                selectedPath={selectedFile?.path}
                onDeleteFile={(item) => setDeleteTarget({ name: item.name, path: item.path || `${currentPath}/${item.name}` })}
                onDownloadFile={(item) => void handleDownloadFile(item)}
              />
            </>
          ) : (
            <Typography color="text.secondary" sx={{ py: 8, textAlign: 'center' }}>
              No data available
            </Typography>
          )}
        </Box>
        <Box sx={{ display: { xs: selectedFile && mobileDetail ? 'block' : 'none', lg: 'block' }, flex: 1, minWidth: 0, overflow: 'auto', borderLeft: { lg: '1px solid', xs: 0 }, borderColor: 'divider' }}>
          {selectedFile ? (
            <RegistryFileViewer
              runtimeId={selectedRuntimeId}
              componentId={componentId}
              environmentId={environmentId}
              filePath={selectedFile.path}
              item={selectedFile.item}
              onClose={() => {
                if (detailDirty && !window.confirm('Discard unsaved resource changes?')) return;
                setSelectedFile(null);
                setMobileDetail(false);
                setDetailDirty(false);
              }}
              onDelete={() => setDeleteTarget({ name: selectedFile.item.name, path: selectedFile.path })}
              canEdit={canEdit}
              onChanged={refreshRegistry}
              onDirtyChange={setDetailDirty}
            />
          ) : (
            <Stack sx={{ height: '100%', alignItems: 'center', justifyContent: 'center', p: 3 }}>
              <Typography color="text.secondary">Select a resource to view its content and properties.</Typography>
            </Stack>
          )}
        </Box>
      </Box>
      <Dialog open={addOpen} onClose={() => !busy && setAddOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>Add Registry Resource</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ pt: 1 }}>
            {mutationError && <Alert severity="error">{mutationError}</Alert>}
            <Typography variant="body2" color="text.secondary">
              Create under {currentPath} on {selectedRuntime?.runtimeName || selectedRuntimeId}.
            </Typography>
            <Stack direction="row" spacing={1}>
              <Button variant={createMode === 'text' ? 'contained' : 'outlined'} onClick={() => setCreateMode('text')}>
                Text content
              </Button>
              <Button variant={createMode === 'file' ? 'contained' : 'outlined'} onClick={() => setCreateMode('file')}>
                Upload file
              </Button>
            </Stack>
            <TextField
              label="Resource name"
              value={resourceName}
              onChange={(event) => setResourceName(event.target.value)}
              error={Boolean(resourceNameError)}
              helperText={resourceNameError || 'Use a name only; spaces, slashes and .. are not allowed.'}
              required
              fullWidth
              autoFocus
            />
            {customMediaType ? (
              <Stack spacing={0.75}>
                <TextField
                  label="Custom media type"
                  value={mediaType}
                  onChange={(event) => setMediaType(event.target.value)}
                  helperText="Use the type/subtype format, for example application/vnd.company.config+json."
                  placeholder="type/subtype"
                  fullWidth
                  required
                  autoFocus
                />
                <Button
                  size="small"
                  sx={{ alignSelf: 'flex-start' }}
                  onClick={() => {
                    setCustomMediaType(false);
                    if (!mediaTypeOptions.some((option) => option.value === mediaType)) setMediaType('text/plain');
                  }}>
                  Choose from media type list
                </Button>
              </Stack>
            ) : (
              <Autocomplete<MediaTypeOption>
                options={mediaTypeOptions}
                value={mediaTypeOptions.find((option) => option.value === mediaType) || null}
                groupBy={(option) => option.group}
                getOptionLabel={(option) => option.value}
                isOptionEqualToValue={(option, value) => option.value === value.value}
                filterOptions={(options, state) => {
                  const query = state.inputValue.trim().toLowerCase();
                  if (!query) return options;
                  return options.filter((option) => `${option.label} ${option.value}`.toLowerCase().includes(query));
                }}
                onChange={(_, option) => {
                  if (!option) {
                    setMediaType('');
                    return;
                  }
                  if (option.value === CUSTOM_MEDIA_TYPE) {
                    setCustomMediaType(true);
                    setMediaType('');
                  } else {
                    setMediaType(option.value);
                  }
                }}
                renderOption={(props, option) => (
                  <li {...props} key={option.value}>
                    <Stack>
                      <Typography variant="body2">{option.label}</Typography>
                      <Typography variant="caption" color="text.secondary">
                        {option.value}
                      </Typography>
                    </Stack>
                  </li>
                )}
                renderInput={(params) => <TextField {...params} label="Media type" helperText="Search by format or MIME type. Choose Custom media type… for a proprietary value." required />}
                slotProps={{
                  paper: {
                    elevation: 8,
                    sx: {
                      backgroundColor: 'background.paper',
                      opacity: 1,
                      backdropFilter: 'none',
                      WebkitBackdropFilter: 'none',
                    },
                  },
                }}
                fullWidth
              />
            )}
            {createMode === 'file' ? (
              <Button component="label" variant="outlined">
                {resourceFile ? resourceFile.name : 'Choose file'}
                <input
                  hidden
                  type="file"
                  onChange={(event) => {
                    const file = event.target.files?.[0] || null;
                    setResourceFile(file);
                    if (file) {
                      const inferredMediaType = inferMediaType(file);
                      setResourceName(file.name);
                      setMediaType(inferredMediaType);
                      setCustomMediaType(!mediaTypeOptions.some((option) => option.value === inferredMediaType));
                    }
                  }}
                />
              </Button>
            ) : (
              <TextField label="Content" value={resourceContent} onChange={(event) => setResourceContent(event.target.value)} multiline minRows={8} fullWidth />
            )}
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setAddOpen(false)} disabled={busy}>
            Cancel
          </Button>
          <Button variant="contained" onClick={() => void submitCreate()} disabled={busy || !canCreateInCurrentPath || !resourceName.trim() || Boolean(resourceNameError) || !mediaType.trim() || (createMode === 'file' && !resourceFile)}>
            Create
          </Button>
        </DialogActions>
      </Dialog>
      <Dialog open={deleteTarget !== null} onClose={() => !busy && setDeleteTarget(null)}>
        <DialogTitle>Delete Registry Resource</DialogTitle>
        <DialogContent>
          <Typography>
            Delete <strong>{deleteTarget?.name}</strong> from <strong>{selectedRuntime?.runtimeName || selectedRuntimeId}</strong>?
          </Typography>
          <Typography variant="caption" color="text.secondary" sx={{ display: 'block', mt: 1, overflowWrap: 'anywhere' }}>
            {deleteTarget?.path}
          </Typography>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setDeleteTarget(null)} disabled={busy}>
            Cancel
          </Button>
          <Button color="error" variant="contained" onClick={() => void confirmDelete()} disabled={busy}>
            Delete
          </Button>
        </DialogActions>
      </Dialog>
      <Dialog open={pendingSelection !== null} onClose={() => confirmPendingSelection(false)}>
        <DialogTitle>Discard unsaved changes?</DialogTitle>
        <DialogContent>
          <Typography variant="body2">Your resource has unsaved changes. Continue and discard them?</Typography>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => confirmPendingSelection(false)}>Stay</Button>
          <Button color="error" variant="contained" onClick={() => confirmPendingSelection(true)}>
            Discard
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
