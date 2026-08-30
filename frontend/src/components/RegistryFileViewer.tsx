/**
 * Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

import { type JSX, useEffect, useState } from 'react';
import { Box, Button, CircularProgress, Divider, IconButton, Stack, Typography, Drawer, Tabs, Tab, TextField, Alert, Dialog, DialogTitle, DialogContent, DialogActions } from '@wso2/oxygen-ui';
import { X, Download, Save, Pencil, Trash2, Plus } from '@wso2/oxygen-ui-icons-react';
import { useRegistryFileContent, useRegistryResourceProperties, type GqlRegistryDirectoryItem } from '../api/queries';
import { deleteRegistryProperty, downloadRegistryResource, updateRegistryResource, upsertRegistryProperties } from '../api/registry';
import CodeViewer from './CodeViewer';

const drawerSx = {
  '& .MuiDrawer-paper': {
    width: '70%',
    maxWidth: 1200,
    minWidth: 600,
    position: 'fixed',
    top: 64,
    height: 'calc(100% - 64px)',
    borderLeft: '1px solid',
    borderColor: 'divider',
  },
};

const headerSx = {
  px: 2,
  py: 1.5,
  borderBottom: '1px solid',
  borderColor: 'divider',
};

interface RegistryFileViewerProps {
  runtimeId: string;
  componentId: string;
  environmentId: string;
  filePath: string;
  item: GqlRegistryDirectoryItem;
  onClose: () => void;
  canEdit?: boolean;
  onChanged?: () => void;
}

export function RegistryFileViewer({ runtimeId, componentId, environmentId, filePath, item, onClose, canEdit = false, onChanged }: RegistryFileViewerProps): JSX.Element {
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
  const isText = item.mediaType.startsWith('text/') || /json|xml|yaml|javascript/.test(item.mediaType);
  const { data: fileContent, isLoading: isLoadingContent } = useRegistryFileContent(runtimeId, filePath, isText);
  const { data: propertiesData, isLoading: isLoadingProperties } = useRegistryResourceProperties(runtimeId, filePath, true);

  useEffect(() => { if (typeof fileContent === 'string' && !editing) setEditedContent(fileContent); }, [fileContent, editing]);

  const handleDownload = async () => {
    try {
      const blob = await downloadRegistryResource(componentId, environmentId, runtimeId, filePath);
      const url = window.URL.createObjectURL(blob); const link = document.createElement('a'); link.href = url; link.download = item.name; link.click(); window.URL.revokeObjectURL(url);
    } catch (e) { setError(e instanceof Error ? e.message : 'Unable to download resource.'); }
  };

  const handleSaveContent = async () => {
    setBusy(true); setError(null);
    try { await updateRegistryResource(componentId, environmentId, runtimeId, filePath, item.mediaType, editedContent); setEditing(false); onChanged?.(); }
    catch (e) { setError(e instanceof Error ? e.message : 'Unable to update resource.'); }
    finally { setBusy(false); }
  };

  const handleReplaceBinary = async () => {
    if (!replacementFile) return;
    setBusy(true); setError(null);
    try { await updateRegistryResource(componentId, environmentId, runtimeId, filePath, item.mediaType, replacementFile, item.name); setReplacementFile(null); onChanged?.(); }
    catch (e) { setError(e instanceof Error ? e.message : 'Unable to replace resource.'); }
    finally { setBusy(false); }
  };

  const handleSaveProperty = async () => {
    if (!propertyName.trim()) return;
    setBusy(true); setError(null);
    try { await upsertRegistryProperties(componentId, environmentId, runtimeId, filePath, [{ name: propertyName.trim(), value: propertyValue }]); setPropertyName(''); setPropertyValue(''); setEditingProperty(null); onChanged?.(); }
    catch (e) { setError(e instanceof Error ? e.message : 'Unable to update property.'); }
    finally { setBusy(false); }
  };

  const handleDeleteProperty = async () => {
    if (!propertyToDelete) return;
    setBusy(true); setError(null);
    try { await deleteRegistryProperty(componentId, environmentId, runtimeId, filePath, propertyToDelete); setPropertyToDelete(null); onChanged?.(); }
    catch (e) { setError(e instanceof Error ? e.message : 'Unable to delete property.'); }
    finally { setBusy(false); }
  };

  const getLanguage = (mediaType: string): 'xml' | 'json' | 'yaml' | 'javascript' | 'text' => {
    if (mediaType.includes('xml')) return 'xml';
    if (mediaType.includes('json')) return 'json';
    if (mediaType.includes('javascript')) return 'javascript';
    if (mediaType.includes('python')) return 'text';
    if (mediaType.includes('java')) return 'text';
    if (mediaType.includes('yaml') || mediaType.includes('yml')) return 'yaml';
    return 'text';
  };

  return (
    <Drawer anchor="right" open onClose={onClose} variant="persistent" sx={drawerSx}>
      <Stack direction="row" alignItems="center" justifyContent="space-between" sx={headerSx}>
        <Box sx={{ flex: 1, minWidth: 0 }}>
          <Typography variant="subtitle1" sx={{ fontWeight: 600 }} noWrap>
            {item.name}
          </Typography>
          <Typography variant="caption" color="text.secondary">
            {item.mediaType}
          </Typography>
        </Box>
        <Stack direction="row" spacing={1}>
          <Button variant="outlined" size="small" startIcon={<Download size={16} />} onClick={() => void handleDownload()}>
            Download
          </Button>
          <IconButton size="small" aria-label="close" onClick={onClose}>
            <X size={16} />
          </IconButton>
        </Stack>
      </Stack>

      {error && <Alert severity="error" sx={{ m: 2 }} onClose={() => setError(null)}>{error}</Alert>}

      <Tabs value={activeTab} onChange={(_, newValue) => setActiveTab(newValue)} sx={{ borderBottom: 1, borderColor: 'divider', px: 2 }}>
        <Tab label="Content" />
        <Tab label={`Properties (${propertiesData?.count || 0})`} />
      </Tabs>

      <Box sx={{ flex: 1, overflow: 'auto' }}>
        {activeTab === 0 && (
          <Box sx={{ p: 2 }}>
            {isLoadingContent ? (
              <Box sx={{ display: 'flex', justifyContent: 'center', py: 4 }}>
                <CircularProgress />
              </Box>
            ) : isText && typeof fileContent === 'string' ? (
              editing ? <TextField value={editedContent} onChange={(event) => setEditedContent(event.target.value)} multiline minRows={20} fullWidth sx={{ '& textarea': { fontFamily: 'monospace' } }} /> : <CodeViewer code={fileContent} language={getLanguage(item.mediaType)} />
            ) : (
              <Stack spacing={2} alignItems="center" sx={{ py: 4 }}><Typography color="text.secondary">Binary resource. Use Download to inspect it.</Typography>{canEdit && <Button component="label" variant="outlined">{replacementFile ? replacementFile.name : 'Choose replacement file'}<input hidden type="file" onChange={(event) => setReplacementFile(event.target.files?.[0] || null)} /></Button>}{canEdit && replacementFile && <Button variant="contained" onClick={() => void handleReplaceBinary()} disabled={busy}>Replace</Button>}</Stack>
            )}
            {canEdit && isText && <Stack direction="row" spacing={1} sx={{ mt: 2 }}>{editing ? <><Button variant="contained" startIcon={<Save size={16} />} onClick={() => void handleSaveContent()} disabled={busy}>Save</Button><Button onClick={() => { setEditing(false); setEditedContent(typeof fileContent === 'string' ? fileContent : ''); }} disabled={busy}>Cancel</Button></> : <Button variant="outlined" startIcon={<Pencil size={16} />} onClick={() => setEditing(true)}>Edit</Button>}</Stack>}
          </Box>
        )}

        {activeTab === 1 && (
          <Box sx={{ p: 2 }}>
            {isLoadingProperties ? (
              <Box sx={{ display: 'flex', justifyContent: 'center', py: 4 }}>
                <CircularProgress />
              </Box>
            ) : propertiesData ? (
              <Stack spacing={2}>
                {canEdit && <Stack direction="row" spacing={1} alignItems="flex-start"><TextField size="small" label="Property name" value={propertyName} onChange={(event) => setPropertyName(event.target.value)} /><TextField size="small" label="Value" value={propertyValue} onChange={(event) => setPropertyValue(event.target.value)} sx={{ flex: 1 }} /><Button variant="contained" startIcon={editingProperty ? <Save size={16} /> : <Plus size={16} />} onClick={() => void handleSaveProperty()} disabled={busy || !propertyName.trim()}>{editingProperty ? 'Update' : 'Add'}</Button></Stack>}
                {propertiesData.properties.map((prop, index) => (
                  <Box key={index}>
                    <Stack direction="row" spacing={2} alignItems="flex-start">
                      <Typography variant="body2" sx={{ fontWeight: 500, minWidth: 150, color: 'text.secondary' }}>
                        {prop.name}
                      </Typography>
                      <Typography variant="body2" sx={{ fontFamily: 'monospace', wordBreak: 'break-all' }}>
                        {prop.value}
                      </Typography>
                      {canEdit && <Stack direction="row" spacing={0.5} sx={{ ml: 'auto' }}><IconButton size="small" aria-label={`Edit ${prop.name}`} onClick={() => { setEditingProperty(prop.name); setPropertyName(prop.name); setPropertyValue(prop.value); }}><Pencil size={15} /></IconButton><IconButton size="small" aria-label={`Delete ${prop.name}`} onClick={() => setPropertyToDelete(prop.name)}><Trash2 size={15} /></IconButton></Stack>}
                    </Stack>
                    {index < propertiesData.properties.length - 1 && <Divider sx={{ mt: 2 }} />}
                  </Box>
                ))}
              </Stack>
            ) : (
              <Typography color="text.secondary" sx={{ py: 4, textAlign: 'center' }}>
                No properties available
              </Typography>
            )}
          </Box>
        )}
      </Box>
      <Dialog open={propertyToDelete !== null} onClose={() => !busy && setPropertyToDelete(null)}><DialogTitle>Delete Registry Property</DialogTitle><DialogContent><Typography>Delete property <strong>{propertyToDelete}</strong>?</Typography></DialogContent><DialogActions><Button onClick={() => setPropertyToDelete(null)} disabled={busy}>Cancel</Button><Button color="error" variant="contained" onClick={() => void handleDeleteProperty()} disabled={busy}>Delete</Button></DialogActions></Dialog>
    </Drawer>
  );
}
