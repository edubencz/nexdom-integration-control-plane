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
import { Box, Breadcrumbs, IconButton, Link, Tooltip, Typography } from '@wso2/oxygen-ui';
import { ChevronRight, Copy } from '@wso2/oxygen-ui-icons-react';

interface RegistryBreadcrumbProps {
  pathSegments: string[];
  onNavigate: (index: number) => void;
}

export function RegistryBreadcrumb({ pathSegments, onNavigate }: RegistryBreadcrumbProps): JSX.Element {
  const fullPath = pathSegments.join('/');
  const isCollapsed = pathSegments.length > 4;
  const visibleSegments = isCollapsed
    ? [{ segment: pathSegments[0], index: 0 }, { segment: '…', index: -1 }, ...pathSegments.slice(-2).map((segment, offset) => ({ segment, index: pathSegments.length - 2 + offset }))]
    : pathSegments.map((segment, index) => ({ segment, index }));

  return (
    <Box sx={{ display: 'flex', alignItems: 'center', minWidth: 0 }}>
      <Tooltip title={fullPath} placement="bottom-start">
        <Breadcrumbs separator={<ChevronRight size={16} />} aria-label="registry path navigation" sx={{ minWidth: 0, overflow: 'hidden', '& ol': { flexWrap: 'nowrap' } }}>
          {visibleSegments.map(({ segment, index }, visibleIndex) => {
            const isLast = visibleIndex === visibleSegments.length - 1;
            const displayName = segment === 'registry' ? 'Registry' : segment;
            if (index < 0) {
              return (
                <Typography key="ellipsis" variant="body2" color="text.secondary">
                  …
                </Typography>
              );
            }
            return isLast ? (
              <Typography key={index} variant="body2" color="text.primary" sx={{ fontWeight: 500, maxWidth: 220, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {displayName}
              </Typography>
            ) : (
              <Link
                key={index}
                component="button"
                variant="body2"
                onClick={() => onNavigate(index)}
                sx={{ cursor: 'pointer', textDecoration: 'none', maxWidth: 180, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', '&:hover': { textDecoration: 'underline' } }}>
                {displayName}
              </Link>
            );
          })}
        </Breadcrumbs>
      </Tooltip>
      <Tooltip title="Copy path">
        <IconButton size="small" aria-label="Copy registry path" onClick={() => void navigator.clipboard?.writeText(fullPath)} sx={{ ml: 0.5 }}>
          <Copy size={14} />
        </IconButton>
      </Tooltip>
    </Box>
  );
}
