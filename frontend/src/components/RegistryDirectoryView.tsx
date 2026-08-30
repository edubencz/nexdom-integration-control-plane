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

import { type JSX } from 'react';
import { Box, ListingTable, Typography, Chip, IconButton, Tooltip } from '@wso2/oxygen-ui';
import { Folder, FileText, Trash2 } from '@wso2/oxygen-ui-icons-react';
import type { GqlRegistryDirectoryItem } from '../api/queries';

interface RegistryDirectoryViewProps {
  items: GqlRegistryDirectoryItem[];
  onNavigateInto: (itemName: string) => void;
  onSelectFile: (item: GqlRegistryDirectoryItem) => void;
  canEdit?: boolean;
  onDeleteFile?: (item: GqlRegistryDirectoryItem) => void;
}

export function RegistryDirectoryView({ items, onNavigateInto, onSelectFile, canEdit = false, onDeleteFile }: RegistryDirectoryViewProps): JSX.Element {
  const handleItemClick = (item: GqlRegistryDirectoryItem) => {
    if (item.isDirectory) {
      onNavigateInto(item.name);
    } else {
      onSelectFile(item);
    }
  };

  const getMediaTypeDisplay = (mediaType: string): string => {
    const parts = mediaType.split('/');
    return parts[parts.length - 1] || mediaType;
  };

  if (items.length === 0) {
    return (
      <Box sx={{ py: 8, textAlign: 'center' }}>
        <Typography color="text.secondary">This directory is empty</Typography>
      </Box>
    );
  }

  return (
    <ListingTable>
      <ListingTable.Head>
        <ListingTable.Row>
          <ListingTable.Cell sx={{ width: '50%' }}>Name</ListingTable.Cell>
          <ListingTable.Cell sx={{ width: '30%' }}>Type</ListingTable.Cell>
          <ListingTable.Cell sx={{ width: '15%' }}>Properties</ListingTable.Cell>
          {canEdit && <ListingTable.Cell sx={{ width: '5%' }} />}
        </ListingTable.Row>
      </ListingTable.Head>
      <ListingTable.Body>
        {items.map((item) => (
          <ListingTable.Row
            key={item.name}
            onClick={() => handleItemClick(item)}
            sx={{
              cursor: 'pointer',
              '&:hover': {
                backgroundColor: 'action.hover',
              },
            }}>
            <ListingTable.Cell>
              <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                {item.isDirectory ? <Folder size={18} color="primary" /> : <FileText size={18} />}
                <Typography variant="body2" sx={{ fontWeight: item.isDirectory ? 500 : 400 }}>
                  {item.name}
                </Typography>
              </Box>
            </ListingTable.Cell>
            <ListingTable.Cell>
              <Chip label={getMediaTypeDisplay(item.mediaType)} size="small" variant="outlined" />
            </ListingTable.Cell>
            <ListingTable.Cell>
              <Typography variant="body2" color="text.secondary">
                {item.properties.length > 0 ? `${item.properties.length} properties` : ''}
              </Typography>
            </ListingTable.Cell>
            {canEdit && <ListingTable.Cell align="right">
              {!item.isDirectory && onDeleteFile && <Tooltip title="Delete resource"><IconButton size="small" aria-label={`Delete ${item.name}`} onClick={(event) => { event.stopPropagation(); onDeleteFile(item); }}><Trash2 size={16} /></IconButton></Tooltip>}
            </ListingTable.Cell>}
          </ListingTable.Row>
        ))}
      </ListingTable.Body>
    </ListingTable>
  );
}
