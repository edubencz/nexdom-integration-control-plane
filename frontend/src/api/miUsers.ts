import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { gql } from './graphql';

export interface MiUser {
  username: string;
  domain: string;
  isAdmin: boolean;
}

export type MiUserStoreStatus = 'SUPPORTED' | 'UNSUPPORTED_FILE_BASED';

export interface MiUsersPage {
  items: MiUser[];
  pageInfo: { total: number; limit: number; offset: number };
  userStoreStatus: MiUserStoreStatus;
}

const GET_MI_USERS = `
  query GetMIUsers($componentId: String!, $runtimeId: String!, $limit: Int, $offset: Int) {
    getMIUsers(componentId: $componentId, runtimeId: $runtimeId, pagination: { limit: $limit, offset: $offset }) {
      items { username, domain, isAdmin }
      pageInfo { total, limit, offset }
      userStoreStatus
    }
  }`;

const ADD_MI_USER = `
  mutation AddMIUser($componentId: String!, $runtimeId: String!, $username: String!, $password: String!, $isAdmin: Boolean, $domain: String) {
    addMIUser(componentId: $componentId, runtimeId: $runtimeId, username: $username, password: $password, isAdmin: $isAdmin, domain: $domain) {
      username, status
    }
  }`;

const DELETE_MI_USER = `
  mutation DeleteMIUser($componentId: String!, $runtimeId: String!, $username: String!, $domain: String) {
    deleteMIUser(componentId: $componentId, runtimeId: $runtimeId, username: $username, domain: $domain) {
      username, status
    }
  }`;

const miUsersKey = (componentId: string, runtimeId: string, limit: number, offset: number) => ['mi-users', componentId, runtimeId, limit, offset] as const;

export function useListMiUsers(componentId: string, runtimeId: string, limit = 25, offset = 0, enabled = true) {
  return useQuery({
    queryKey: miUsersKey(componentId, runtimeId, limit, offset),
    queryFn: () => gql<{ getMIUsers: MiUsersPage }>(GET_MI_USERS, { componentId, runtimeId, limit, offset }).then((d) => d.getMIUsers),
    enabled: enabled && !!componentId && !!runtimeId,
  });
}

export function useCreateMiUser() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ componentId, runtimeId, username, password, isAdmin, domain }: { componentId: string; runtimeId: string; username: string; password: string; isAdmin: boolean; domain: string }) =>
      gql<{ addMIUser: { username: string; status: string } }>(ADD_MI_USER, { componentId, runtimeId, username, password, isAdmin, domain }).then((d) => d.addMIUser),
    onSuccess: (_, vars) => qc.invalidateQueries({ queryKey: ['mi-users', vars.componentId, vars.runtimeId] }),
  });
}

export function useDeleteMiUser() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ componentId, runtimeId, username, domain }: { componentId: string; runtimeId: string; username: string; domain: string }) =>
      gql<{ deleteMIUser: { username: string; status: string } }>(DELETE_MI_USER, { componentId, runtimeId, username, domain }).then((d) => d.deleteMIUser),
    onSuccess: (_, vars) => qc.invalidateQueries({ queryKey: ['mi-users', vars.componentId, vars.runtimeId] }),
  });
}
