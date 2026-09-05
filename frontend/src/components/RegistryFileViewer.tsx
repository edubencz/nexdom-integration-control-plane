/**
 * Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
 * Licensed under the Apache License, Version 2.0.
 */

import { type JSX, useEffect, useState } from 'react';
import { Alert, Box, Button, Chip, CircularProgress, IconButton, ListingTable, Stack, Tab, Tabs, TextField, Typography } from '@wso2/oxygen-ui';
import { ArrowLeft, Download, Pencil, Plus, Save, Trash2, Upload, X } from '@wso2/oxygen-ui-icons-react';
import { useRegistryFileContent, useRegistryResourceProperties, type GqlRegistryDirectoryItem, type GqlRegistryPropertiesResponse } from '../api/queries';
import { deleteRegistryProperty, downloadRegistryResource, updateRegistryResource, upsertRegistryProperties } from '../api/registry';
import CodeViewer from './CodeViewer';
import { useQueryClient } from '@tanstack/react-query';

interface RegistryFileViewerProps {
  runtimeId: string;
  componentId: string;
  environmentId: string;
  filePath: string;
  item: GqlRegistryDirectoryItem;
  onClose: () => void;
  onDelete?: () => void;
  onDirtyChange?: (dirty: boolean) => void;
  canEdit?: boolean;
  onChanged?: () => void;
}

function validateTextContent(content: string, mediaType: string): string | null {
  try {
    if (mediaType.includes('json')) JSON.parse(content);
    if (mediaType.includes('xml')) {
      const parsed = new DOMParser().parseFromString(content, 'application/xml');
      if (parsed.getElementsByTagName('parsererror').length > 0) return 'The XML content is not well formed.';
    }
    return null;
  } catch {
    return mediaType.includes('json') ? 'The JSON content is not valid.' : 'The content could not be validated.';
  }
}

export function RegistryFileViewer({ runtimeId, componentId, environmentId, filePath, item, onClose, onDelete, onDirtyChange, canEdit = false, onChanged }: RegistryFileViewerProps): JSX.Element {
  const [activeTab, setActiveTab] = useState(0);
  const [editing, setEditing] = useState(false);
  const [editedContent, setEditedContent] = useState('');
  const [replacementFile, setReplacementFile] = useState<File | null>(null);
  const [propertyName, setPropertyName] = useState('');
  const [propertyValue, setPropertyValue] = useState('');
  const [editingProperty, setEditingProperty] = useState<string | null>(null);
  const [propertyToDelete, setPropertyToDelete] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [binaryPreviewUrl, setBinaryPreviewUrl] = useState<string | null>(null);
  const [isLoadingBinary, setIsLoadingBinary] = useState(false);
  const queryClient = useQueryClient();
  const isText = item.mediaType.startsWith('text/') || /json|xml|yaml|javascript|properties/.test(`${item.mediaType} ${item.name} ${filePath}`);
  const isImage = item.mediaType.startsWith('image/');
  const isPdf = item.mediaType === 'application/pdf';
  const { data: fileContent, isLoading: isLoadingContent, error: contentError, refetch: refetchContent } = useRegistryFileContent(runtimeId, filePath, isText);
  const { data: propertiesData, isLoading: isLoadingProperties, error: propertiesError, refetch: refetchProperties } = useRegistryResourceProperties(runtimeId, filePath, true);

  useEffect(() => {
    if (typeof fileContent === 'string' && !editing) setEditedContent(fileContent);
  }, [fileContent, editing]);

  useEffect(() => {
    onDirtyChange?.(editing && isText && typeof fileContent === 'string' && editedContent !== fileContent);
  }, [editedContent, editing, fileContent, isText, onDirtyChange]);

  useEffect(() => {
    if (isText) {
      setBinaryPreviewUrl(null);
      return undefined;
    }
    let disposed = false;
    setIsLoadingBinary(true);
    void downloadRegistryResource(componentId, environmentId, runtimeId, filePath)
      .then((blob) => {
        if (!disposed) setBinaryPreviewUrl(URL.createObjectURL(blob));
      })
      .catch(() => {
        if (!disposed) setBinaryPreviewUrl(null);
      })
      .finally(() => {
        if (!disposed) setIsLoadingBinary(false);
      });
    return () => {
      disposed = true;
      setBinaryPreviewUrl((url) => {
        if (url) URL.revokeObjectURL(url);
        return null;
      });
    };
  }, [componentId, environmentId, filePath, isText, runtimeId]);

  const handleDownload = async () => {
    try {
      const blob = await downloadRegistryResource(componentId, environmentId, runtimeId, filePath);
      const url = window.URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = item.name;
      link.click();
      window.URL.revokeObjectURL(url);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Unable to download resource.');
    }
  };

  const handleSaveContent = async () => {
    const validationError = validateTextContent(editedContent, item.mediaType);
    if (validationError) {
      setError(validationError);
      return;
    }
    setBusy(true);
    setError(null);
    setSuccess(null);
    try {
      await updateRegistryResource(componentId, environmentId, runtimeId, filePath, item.mediaType, editedContent);
      queryClient.setQueryData(['registryFileContent', runtimeId, filePath], editedContent);
      setEditing(false);
      setSuccess('Resource update requested. The runtime may take up to its configured cachableDuration to reflect the change.');
      onChanged?.();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Unable to update resource.');
    } finally {
      setBusy(false);
    }
  };

  const handleReplaceBinary = async () => {
    if (!replacementFile) return;
    setBusy(true);
    setError(null);
    setSuccess(null);
    try {
      await updateRegistryResource(componentId, environmentId, runtimeId, filePath, item.mediaType, replacementFile, item.name);
      setReplacementFile(null);
      setSuccess('Resource replacement requested. The runtime may take up to its configured cachableDuration to reflect the change.');
      onChanged?.();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Unable to replace resource.');
    } finally {
      setBusy(false);
    }
  };

  const handleSaveProperty = async () => {
    const name = editingProperty || propertyName.trim();
    if (!name) return;
    setBusy(true);
    setError(null);
    setSuccess(null);
    try {
      await upsertRegistryProperties(componentId, environmentId, runtimeId, filePath, [{ name, value: propertyValue }]);
      queryClient.setQueryData<GqlRegistryPropertiesResponse>(['registryResourceProperties', runtimeId, filePath], (current) => {
        if (!current) return current;
        const existing = current.properties.findIndex((property) => property.name === name);
        const properties = existing >= 0 ? current.properties.map((property, index) => (index === existing ? { ...property, value: propertyValue } : property)) : [...current.properties, { name, value: propertyValue }];
        return { count: properties.length, properties };
      });
      setPropertyName('');
      setPropertyValue('');
      setEditingProperty(null);
      setSuccess('Property update requested. The runtime may take up to its configured cachableDuration to reflect the change.');
      onChanged?.();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Unable to update property.');
    } finally {
      setBusy(false);
    }
  };

  const handleDeleteProperty = async () => {
    if (!propertyToDelete) return;
    setBusy(true);
    setError(null);
    setSuccess(null);
    try {
      await deleteRegistryProperty(componentId, environmentId, runtimeId, filePath, propertyToDelete);
      queryClient.setQueryData<GqlRegistryPropertiesResponse>(['registryResourceProperties', runtimeId, filePath], (current) =>
        current ? { count: current.properties.filter((property) => property.name !== propertyToDelete).length, properties: current.properties.filter((property) => property.name !== propertyToDelete) } : current,
      );
      setPropertyToDelete(null);
      setSuccess('Property deletion requested. The runtime may take up to its configured cachableDuration to reflect the change.');
      onChanged?.();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Unable to delete property.');
    } finally {
      setBusy(false);
    }
  };

  const getLanguage = (mediaType: string): 'xml' | 'json' | 'yaml' | 'javascript' | 'text' => {
    if (mediaType.includes('xml')) return 'xml';
    if (mediaType.includes('json')) return 'json';
    if (mediaType.includes('javascript')) return 'javascript';
    if (mediaType.includes('yaml') || mediaType.includes('yml')) return 'yaml';
    return 'text';
  };

  return (
    <Stack spacing={2} sx={{ height: '100%', minWidth: 0, overflow: 'auto', p: 2 }}>
      <Stack spacing={1} sx={{ minWidth: 0 }}>
        <Stack direction="row" alignItems="center" justifyContent="space-between" spacing={1} sx={{ minWidth: 0 }}>
          <Button variant="text" size="small" startIcon={<ArrowLeft size={16} />} onClick={onClose} sx={{ flexShrink: 0 }}>
            Back
          </Button>
          <Stack direction="row" alignItems="center" spacing={0.75} sx={{ flexShrink: 0 }}>
            <Chip label={item.mediaType} size="small" variant="outlined" />
            <IconButton size="small" aria-label="Download resource" onClick={() => void handleDownload()}>
              <Download size={18} />
            </IconButton>
            {canEdit && onDelete && (
              <IconButton size="small" color="error" aria-label={`Delete ${item.name}`} onClick={onDelete}>
                <Trash2 size={17} />
              </IconButton>
            )}
          </Stack>
        </Stack>
        <Box sx={{ minWidth: 0 }} title={filePath}>
          <Typography variant="subtitle1" sx={{ fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {item.name}
          </Typography>
          <Typography variant="caption" color="text.secondary" sx={{ display: 'block', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {filePath}
          </Typography>
        </Box>
      </Stack>
      {error && (
        <Alert severity="error" onClose={() => setError(null)}>
          {error}
        </Alert>
      )}
      {success && (
        <Alert severity="success" onClose={() => setSuccess(null)}>
          {success}
        </Alert>
      )}
      <Tabs value={activeTab} onChange={(_, value) => setActiveTab(value)} sx={{ borderBottom: 1, borderColor: 'divider' }}>
        <Tab label="Content" />
        <Tab label={`Properties (${propertiesData?.count || 0})`} />
      </Tabs>
      {activeTab === 0 && (
        <Box sx={{ minWidth: 0 }}>
          {isLoadingContent ? (
            <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}>
              <CircularProgress />
            </Box>
          ) : contentError ? (
            <Alert
              severity="error"
              action={
                <Button size="small" onClick={() => void refetchContent()}>
                  Retry
                </Button>
              }>
              Unable to load resource content.
            </Alert>
          ) : isText && typeof fileContent === 'string' ? (
            editing ? (
              <TextField value={editedContent} onChange={(event) => setEditedContent(event.target.value)} multiline minRows={20} fullWidth sx={{ '& textarea': { fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace' } }} />
            ) : (
              <CodeViewer code={fileContent} language={getLanguage(item.mediaType)} maxHeight="55vh" />
            )
          ) : (
            <Stack spacing={2} alignItems="center" sx={{ py: 3 }}>
              {isLoadingBinary && <CircularProgress size={24} />}
              {binaryPreviewUrl && isImage && <Box component="img" src={binaryPreviewUrl} alt={item.name} sx={{ maxWidth: '100%', maxHeight: '55vh', objectFit: 'contain', border: '1px solid', borderColor: 'divider', borderRadius: 1 }} />}
              {binaryPreviewUrl && isPdf && <Box component="iframe" title={item.name} src={binaryPreviewUrl} sx={{ width: '100%', height: '55vh', border: '1px solid', borderColor: 'divider' }} />}
              {!binaryPreviewUrl && !isLoadingBinary && <Typography color="text.secondary">Binary resource. Use Download to inspect it.</Typography>}
              {canEdit && (
                <Button component="label" variant="outlined" startIcon={<Upload size={16} />}>
                  {replacementFile ? replacementFile.name : 'Choose replacement file'}
                  <input hidden type="file" onChange={(event) => setReplacementFile(event.target.files?.[0] || null)} />
                </Button>
              )}
              {canEdit && replacementFile && (
                <Button variant="contained" onClick={() => void handleReplaceBinary()} disabled={busy}>
                  Replace
                </Button>
              )}
            </Stack>
          )}
          {canEdit && isText && (
            <Stack direction="row" spacing={1} sx={{ mt: 2 }}>
              {editing ? (
                <>
                  <Button variant="contained" startIcon={<Save size={16} />} onClick={() => void handleSaveContent()} disabled={busy}>
                    Save
                  </Button>
                  <Button
                    onClick={() => {
                      setEditing(false);
                      setEditedContent(typeof fileContent === 'string' ? fileContent : '');
                    }}
                    disabled={busy}>
                    Cancel
                  </Button>
                </>
              ) : (
                <Button
                  variant="outlined"
                  startIcon={<Pencil size={16} />}
                  onClick={() => {
                    setError(null);
                    setEditing(true);
                  }}>
                  Edit
                </Button>
              )}
            </Stack>
          )}
        </Box>
      )}
      {activeTab === 1 && (
        <Box sx={{ minWidth: 0 }}>
          {isLoadingProperties ? (
            <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}>
              <CircularProgress />
            </Box>
          ) : propertiesError ? (
            <Alert
              severity="error"
              action={
                <Button size="small" onClick={() => void refetchProperties()}>
                  Retry
                </Button>
              }>
              Unable to load properties.
            </Alert>
          ) : propertiesData ? (
            <Stack spacing={2}>
              {canEdit && editingProperty === null && (
                <Stack direction={{ xs: 'column', sm: 'row' }} spacing={1} alignItems={{ sm: 'flex-start' }}>
                  <TextField size="small" label="Property name" value={propertyName} onChange={(event) => setPropertyName(event.target.value)} />
                  <TextField size="small" label="Value" value={propertyValue} onChange={(event) => setPropertyValue(event.target.value)} sx={{ flex: 1, minWidth: 0 }} />
                  <Button variant="contained" startIcon={editingProperty ? <Save size={16} /> : <Plus size={16} />} onClick={() => void handleSaveProperty()} disabled={busy || !(editingProperty || propertyName.trim())}>
                    {editingProperty ? 'Update' : 'Add'}
                  </Button>
                  {editingProperty && (
                    <Button
                      onClick={() => {
                        setEditingProperty(null);
                        setPropertyName('');
                        setPropertyValue('');
                      }}
                      disabled={busy}>
                      Cancel
                    </Button>
                  )}
                </Stack>
              )}
              {propertiesData.properties.length === 0 ? (
                <Typography color="text.secondary" sx={{ py: 4, textAlign: 'center' }}>
                  No properties available
                </Typography>
              ) : (
                <ListingTable>
                  <ListingTable.Head>
                    <ListingTable.Row>
                      <ListingTable.Cell>Name</ListingTable.Cell>
                      <ListingTable.Cell>Value</ListingTable.Cell>
                      {canEdit && <ListingTable.Cell align="right">Actions</ListingTable.Cell>}
                    </ListingTable.Row>
                  </ListingTable.Head>
                  <ListingTable.Body>
                    {propertiesData.properties.map((prop) => (
                      <ListingTable.Row key={prop.name}>
                        <ListingTable.Cell>
                          <Typography variant="body2" sx={{ fontWeight: 500, overflowWrap: 'anywhere' }}>
                            {prop.name}
                          </Typography>
                        </ListingTable.Cell>
                        <ListingTable.Cell>
                          {editingProperty === prop.name ? (
                            <TextField size="small" value={propertyValue} onChange={(event) => setPropertyValue(event.target.value)} fullWidth autoFocus />
                          ) : (
                            <Typography variant="body2" sx={{ fontFamily: 'monospace', wordBreak: 'break-all' }}>
                              {prop.value}
                            </Typography>
                          )}
                        </ListingTable.Cell>
                        {canEdit && (
                          <ListingTable.Cell align="right">
                            <Stack direction="row" spacing={0.5} justifyContent="flex-end">
                              {editingProperty === prop.name ? (
                                <>
                                  <IconButton size="small" aria-label={`Save ${prop.name}`} onClick={() => void handleSaveProperty()} disabled={busy}>
                                    <Save size={15} />
                                  </IconButton>
                                  <IconButton
                                    size="small"
                                    aria-label={`Cancel editing ${prop.name}`}
                                    onClick={() => {
                                      setEditingProperty(null);
                                      setPropertyName('');
                                      setPropertyValue('');
                                    }}
                                    disabled={busy}>
                                    <X size={15} />
                                  </IconButton>
                                </>
                              ) : (
                                <>
                                  <IconButton
                                    size="small"
                                    aria-label={`Edit ${prop.name}`}
                                    onClick={() => {
                                      setEditingProperty(prop.name);
                                      setPropertyName(prop.name);
                                      setPropertyValue(prop.value);
                                    }}>
                                    <Pencil size={15} />
                                  </IconButton>
                                  <IconButton size="small" color="error" aria-label={`Delete property ${prop.name}`} onClick={() => setPropertyToDelete(prop.name)}>
                                    <Trash2 size={15} />
                                  </IconButton>
                                </>
                              )}
                            </Stack>
                          </ListingTable.Cell>
                        )}
                      </ListingTable.Row>
                    ))}
                  </ListingTable.Body>
                </ListingTable>
              )}
            </Stack>
          ) : (
            <Typography color="text.secondary" sx={{ py: 4, textAlign: 'center' }}>
              No properties available
            </Typography>
          )}
        </Box>
      )}
      {propertyToDelete && (
        <Box role="alertdialog" sx={{ p: 2, border: '1px solid', borderColor: 'error.main', borderRadius: 1 }}>
          <Typography variant="body2" sx={{ mb: 1 }}>
            Delete property <strong>{propertyToDelete}</strong>?
          </Typography>
          <Stack direction="row" spacing={1}>
            <Button size="small" onClick={() => setPropertyToDelete(null)} disabled={busy}>
              Cancel
            </Button>
            <Button size="small" color="error" variant="contained" onClick={() => void handleDeleteProperty()} disabled={busy}>
              Delete
            </Button>
          </Stack>
        </Box>
      )}
    </Stack>
  );
}
