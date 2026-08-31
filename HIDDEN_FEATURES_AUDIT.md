# Auditoria de features ocultas, incompletas e pouco expostas

## Visão geral

Este documento registra funcionalidades encontradas no projeto `n-integration-control-plane` que se enquadram em uma destas categorias:

- **Incompleta ou protótipo:** há telas, modelos ou rotas preparadas, mas não existe um fluxo funcional de ponta a ponta.
- **Scaffolding ou domínio dormente:** o banco, os tipos ou o GraphQL antecipam uma funcionalidade que a aplicação atual não oferece.
- **Implementada, mas pouco exposta:** a funcionalidade existe e possui backend e frontend, porém depende de configuração, tecnologia específica ou navegação pouco evidente.
- **Legado:** estruturas preservadas por compatibilidade ou herdadas de outro modelo de produto, sem papel claro na experiência atual.

O principal padrão encontrado é que o produto atual possui um núcleo operacional funcional — runtimes, artefatos, logs, métricas, RBAC, Workflow e administração de Micro Integrator — enquanto mantém partes de uma visão mais ampla de plataforma: multi-tenancy, integração Git, pipelines, releases e topologia avançada de ambientes.

---

## Resumo dos achados

| Feature | Classificação | Confiança | Situação resumida |
|---|---|---:|---|
| Cadastro de Organizations | Incompleta / protótipo | Muito alta | Há tabela, escopos, URLs e uma tela mockada, mas a aplicação funciona com `org_id = 1` e não possui CRUD real. |
| Dashboard Analytics legado | Protótipo abandonado | Muito alta | Página órfã, sem rota ativa e composta por dados hardcoded. |
| Integração com repositórios Git | Scaffolding persistido | Alta | Campos existem no banco, tipos e GraphQL, mas não há configuração na UI nem clone/build/deploy. |
| Pipelines, releases e deployment tracks | Domínio dormente | Alta | Tipos ricos permanecem no schema, sem fluxo funcional ou consumidor frontend. |
| Configuração avançada de ambientes | Legado / dormente | Média-alta | Schema mantém campos de cluster, APIM, migração e scale-to-zero que a UI atual não gerencia. |
| Console operacional de MI | Implementada, pouco exposta | Alta | Inclui restart/shutdown, usuários, Registry e lifecycle de Carbon Applications. |
| Desired state de artefatos | Implementada, pouco evidente | Alta | Alterações são reconciliadas assincronamente por comandos e heartbeats. |
| SSO federado | Implementada, configuration-gated | Alta | Suporta SSO-only, claims administrativos e sincronização de grupos do IdP. |
| LDAP user store | Implementada, configuration-only | Alta | Backend alternativo de autenticação com grupos, TLS e papéis administrativos. |
| Moesif Metrics | Implementada, setup-gated | Média-alta | Criação e embed de dashboards com setup próprio para BI e MI. |
| Notificações em tempo real | Implementada | Alta | WebSockets notificam mudanças de runtime e log levels. |
| Auditoria e segurança de sessão | Implementada | Alta | Audit trail, retenção, refresh-token rotation, lockout progressivo e desbloqueio. |

---

## 1. Organization e multi-tenancy incompleto

### Conclusão

A abstração de Organization existe em toda a arquitetura, mas o sistema efetivamente implementado é **single-organization**, fixado na organização de ID `1` e handler `default`.

Não se trata somente de uma tela ausente. Para oferecer multi-tenancy real ainda seria necessário revisar autenticação, autorização, secrets, registro de runtimes, auditoria, WebSockets e isolamento de dados.

### Evidências de preparação para multi-tenancy

- Existe uma tabela `organizations` nos scripts de inicialização dos bancos.
- Projetos possuem `org_id` e foreign key para `organizations`.
- Grupos, roles, permissões e mapeamentos SSO carregam escopo organizacional.
- As URLs seguem o formato `/organizations/:orgHandler/...`.
- O RBAC possui escopos de organização, projeto, integração e ambiente.
- Existe uma página frontend completa chamada `Organizations.tsx`.

Arquivos relevantes:

- `icp_server/resources/db/init-scripts/postgresql_init.sql`
- `icp_server/resources/db/init-scripts/mysql_init.sql`
- `icp_server/resources/db/init-scripts/mssql_init.sql`
- `icp_server/resources/db/init-scripts/oracle_init.sql`
- `icp_server/resources/db/init-scripts/h2_init.sql`
- `frontend/src/pages/Organizations.tsx`
- `frontend/src/paths.ts`

### Evidências de implementação single-organization

Os scripts de banco inserem somente a organização padrão:

```text
org_id: 1
org_name: Default Organization
org_handle: default
```

O seletor de organização do cabeçalho possui somente `Default Organization`, hardcoded em:

```text
frontend/src/layouts/AppLayout.tsx
```

Diversos fluxos usam explicitamente `orgId: 1` ou `DEFAULT_ORG_ID`. Por exemplo:

- Criação de componentes no frontend envia `orgId: 1`.
- O proxy de Workflow monta o escopo com `orgUuid: 1`.
- Audit logs consultam `org_id = 1`.
- Endpoints de SSO Group Mapping usam `storage:DEFAULT_ORG_ID`.

O serviço de autenticação contém TODOs explícitos como:

```text
TODO: use when multiple tenants are supported
```

Arquivo:

```text
icp_server/auth_service.bal
```

### Tela de Organizations

A página `frontend/src/pages/Organizations.tsx` é um protótipo visual:

- Consome `mockOrganizations`.
- Consome `mockExploreMoreSections`.
- Info, Settings e Delete executam apenas `console.log`.
- New Organization navega para `/organizations/new`, mas não existe rota ativa correspondente.
- Edit navega para uma URL sem página registrada.
- A própria página não aparece na matriz ativa de rotas.

O GraphQL possui CRUD de projetos, ambientes e componentes, mas não oferece queries ou mutations de Organization.

### O que seria necessário para concluir

1. Criar queries e mutations para listar, criar, editar e excluir organizações.
2. Substituir a tela mockada por dados reais.
3. Tornar o seletor de organização dinâmico.
4. Remover todos os usos fixos de `orgId = 1` e `DEFAULT_ORG_ID` fora de defaults controlados.
5. Garantir isolamento organizacional em todas as queries e mutations.
6. Vincular usuários e identidades OIDC/LDAP à organização correta.
7. Isolar secrets e API keys por organização.
8. Incluir organização nos canais WebSocket e registros de runtime.
9. Testar vazamento de dados e privilégios entre tenants.
10. Definir regras de exclusão, suspensão e ownership da organização.

Se multi-tenancy não fizer parte do roadmap, a alternativa é simplificar o vocabulário e tornar Organization uma estrutura interna, removendo telas, paths e mocks que sugerem suporte inexistente.

---

## 2. Dashboard Analytics legado

### Conclusão

Existe um dashboard genérico de Analytics que aparenta ser um protótipo antigo e não faz parte da aplicação ativa.

Arquivo:

```text
frontend/src/pages/Analytics.tsx
```

### O que a página apresenta

- Total de componentes.
- Componentes ativos.
- Contributors.
- Last Updated.
- Crescimento de usuários.
- Distribuição de status.
- Origem de tráfego.
- Receita mensal.
- Atividade recente.
- Link para logs de Analytics.

### Por que parece abandonada

- Todos os valores são hardcoded no próprio componente.
- Os usuários e atividades são fictícios.
- Os valores de receita e tráfego não vêm de nenhuma API.
- A página não está registrada em `frontend/src/config/routes.tsx`.
- Os helpers `orgAnalyticsUrl` e `orgAnalyticsLogsUrl` permanecem em `frontend/src/paths.ts`, mas não são usados pelo roteamento ativo.
- O produto possui outra implementação real de métricas em `Metrics.tsx`, com OpenSearch e Moesif.

### Recomendação

Remover a página e os path helpers se ela não pertence ao roadmap. Se houver intenção de recuperá-la, ela deve ser redesenhada sobre a arquitetura atual de Metrics, sem reaproveitar os dados fictícios.

---

## 3. Integração com repositórios Git

### Conclusão

O sistema possui parte do modelo e da persistência necessários para uma integração com Git, mas não oferece o fluxo de produto correspondente.

### Campos existentes

Projetos possuem:

- `git_provider`
- `git_organization`
- `repository`
- `branch`
- `secret_ref`

Esses campos aparecem nos scripts de banco e em:

```text
icp_server/modules/storage/project_repository.bal
icp_server/schema_graphql.graphql
icp_server/modules/types/types.bal
frontend/src/api/mutations.ts
```

Componentes também possuem inputs planejados para:

- URL do repositório.
- Branch.
- Diretório dentro do repositório.
- Referência de credencial.
- Repositório público ou privado.

O próprio tipo Ballerina documenta esse conjunto como:

```text
Repository Integration (optional - for future use)
```

### Lacunas encontradas

- Create Project não solicita configuração Git.
- Edit Project não permite editar configuração Git.
- Create Component não solicita repositório ou branch.
- O frontend envia `isPublicRepo: false` de forma fixa.
- Não existe integração com um provider Git.
- Não existe clone ou checkout.
- Não existe webhook.
- Não existe polling de commits.
- Não existe build baseado no repositório.
- Não existe deployment originado de commit ou release.
- Não existe gerenciamento real de `secretRef` para credenciais Git.

### Recomendação

Decidir entre:

1. Implementar a feature de source control de ponta a ponta; ou
2. Remover esses campos dos inputs públicos e mantê-los somente quando houver um consumidor real.

Manter campos publicamente graváveis sem comportamento associado cria uma expectativa de funcionalidade que não existe.

---

## 4. Pipelines, releases, API versions e deployment tracks

### Conclusão

Há um modelo de plataforma de build e deployment muito maior do que a aplicação atual implementa. Ele parece herdado de Choreo/Devant ou preservado para evolução futura.

### Estruturas encontradas

- `defaultDeploymentPipelineId`
- `deploymentPipelineIds`
- `ApiVersion`
- `AppEnvVersion`
- `Release`
- `ReleaseMetadata`
- `DeploymentTrack`
- `autoDeployEnabled`
- `autoBuildEnabled`
- `gitHash`
- `gitOpsHash`
- `deploymentStatus`
- `lastDeployedAt`
- `versionStrategy`
- `CellDiagram`

Arquivos principais:

```text
icp_server/modules/types/types.bal
icp_server/schema_graphql.graphql
icp_server/modules/storage/project_repository.bal
```

### Endpoint parcialmente relacionado

O GraphQL oferece `componentDeployment`, que lê informações de deployment a partir dos runtimes registrados:

```text
icp_server/graphql_api.bal
icp_server/modules/storage/component_repository.bal
```

Entretanto, não foi encontrado consumidor frontend para essa query.

### Lacunas encontradas

- Não existe tela de pipelines.
- Não existe CRUD de deployment tracks.
- Não existe gestão de releases.
- Não existe promotion entre ambientes.
- Não existe visualização de commits ou hashes GitOps.
- Não existe processo de build.
- Não existe fluxo de auto-build ou auto-deploy.
- Não existe UI para version strategy.

### Recomendação

Separar o que é compatibilidade estrutural do que é roadmap real. Tipos sem produtor, persistência e consumidor deveriam ser removidos do schema público ou marcados claramente como internos/legados.

---

## 5. Configuração avançada de ambientes

### Conclusão

O tipo de ambiente contém campos avançados de infraestrutura e API management que a experiência atual não permite configurar.

### Campos encontrados

- `region`
- `clusterId`
- `dnsPrefix`
- `choreoEnv`
- `externalApimEnvName`
- `internalApimEnvName`
- `sandboxApimEnvName`
- `vhost`
- `sandboxVhost`
- `apiEnvName`
- `apimEnvId`
- `isMigrating`
- `promoteFrom`
- `namespace`
- `dpId`
- `templateId`
- `isPdp`
- `scaleToZeroEnabled`

Arquivos:

```text
icp_server/schema_graphql.graphql
icp_server/modules/types/types.bal
icp_server/modules/storage/environment_repository.bal
```

Vários desses campos estão marcados no schema como legacy ou deprecated.

### O que a UI atual gerencia

- Nome.
- Handler.
- Descrição.
- Ambiente crítico/produção.

Arquivos:

```text
frontend/src/pages/CreateEnvironment.tsx
frontend/src/pages/EditEnvironment.tsx
```

### Recomendação

Remover campos definitivamente herdados e criar uma especificação de produto antes de expor os demais. Atualmente o schema mistura o ambiente operacional do ICP com conceitos de infraestrutura de outra plataforma.

---

## 6. Console operacional de Micro Integrator

### Conclusão

O projeto já contém praticamente um console de operações de Micro Integrator, mas suas capacidades estão distribuídas dentro das páginas de runtime e detalhes de artefatos.

### Administração do servidor MI

Operações suportadas:

- Restart.
- Graceful restart.
- Shutdown.
- Graceful shutdown.

Arquivos:

```text
frontend/src/components/ServerManagementPanel.tsx
icp_server/mi_server_proxy_service.bal
```

O frontend acompanha a indisponibilidade, o retorno do runtime e entradas de log para tentar confirmar o resultado da operação.

### Carbon Applications

Capacidades:

- Listagem de Carbon Applications.
- Upload de arquivo `.car`.
- Deployment no runtime selecionado.
- Undeploy.
- Verificação de estado após a operação.
- Correlação com novas entradas em `wso2carbon.log`.
- Tratamento dos estados active, faulty, pending e error.
- Exibição de stack trace para aplicações faulty.

Arquivos:

```text
frontend/src/components/ArtifactDetail.tsx
icp_server/mi_applications_proxy_service.bal
```

### Registry Browser

Capacidades:

- Navegação por diretórios.
- Leitura de conteúdo.
- Upload ou criação de resource.
- Remoção de resource.
- Leitura e alteração de propriedades.
- Escolha do runtime alvo.

Arquivos:

```text
frontend/src/components/RegistryBrowser.tsx
frontend/src/api/registry.ts
icp_server/mi_registry_proxy_service.bal
```

### Runtime Users

Capacidades:

- Listar usuários do runtime MI.
- Criar usuário.
- Excluir usuário.
- Definir usuário administrativo.
- Escolher domínio.
- Detectar user store incompatível.

Arquivos:

```text
frontend/src/api/miUsers.ts
frontend/src/components/EntryPoints.tsx
icp_server/graphql_api.bal
```

### Recomendação

Agrupar essas capacidades em uma área explicitamente chamada **MI Operations** ou **Runtime Administration**. Atualmente a funcionalidade é madura, mas sua descoberta depende de conhecer a hierarquia interna dos artefatos.

---

## 7. Desired state e reconciliação de artefatos

### Conclusão

O ICP não é somente um observador. Ele funciona como um control plane que registra o estado desejado dos artefatos e envia comandos para que os runtimes convirjam a esse estado.

### Operações encontradas

- Iniciar e parar artefatos.
- Ativar e desativar listeners.
- Habilitar e desabilitar tracing.
- Habilitar e desabilitar statistics.
- Disparar scheduled tasks.
- Alterar log levels.

GraphQL:

```text
updateArtifactStatus
updateArtifactTracingStatus
updateArtifactStatisticsStatus
triggerArtifact
updateListenerState
updateLogLevel
```

### Funcionamento

1. O usuário solicita uma alteração.
2. O ICP grava o estado desejado ou um comando pendente.
3. O runtime bridge recebe o comando.
4. O runtime aplica a mudança.
5. Heartbeats posteriores reportam o estado real.
6. A UI mostra se o estado está ou não sincronizado.

Documentação:

```text
icp_server/docs/control-command-processing.md
```

Implementação frontend:

```text
frontend/src/components/EntryPoints.tsx
frontend/src/components/ArtifactDetail.tsx
frontend/src/components/ArtifactTabs.tsx
frontend/src/api/artifactToggleMutations.ts
frontend/src/api/mutations.ts
```

### Recomendação

Comunicar melhor na UI a diferença entre:

- Estado desejado.
- Comando pendente.
- Estado reportado pelo runtime.
- Falha de reconciliação.

O indicador `inSync` existe, mas o modelo assíncrono não é óbvio para o usuário.

---

## 8. SSO e controle de acesso federado

### Conclusão

O suporte a SSO é mais avançado que um login OIDC básico. O projeto implementa provisionamento, concessão administrativa por claims e sincronização de grupos do IdP.

### Modos suportados

- Senha local sem SSO.
- Senha local e SSO simultaneamente.
- Login exclusivamente por SSO.
- Controle de acesso federado, com o IdP como fonte autoritativa de memberships.

### Capacidades

- Authorization Code Flow OIDC.
- Configuração de issuer, authorization endpoint, token endpoint, logout endpoint e JWKS.
- Username derivado de claim configurável.
- Claim e valores que concedem Super Admin.
- Mapeamentos de claim para grupos ICP.
- Escopo de mapping por organização, projeto ou integração.
- Reconciliação de memberships a cada login.
- Remoção de memberships federadas obsoletas.
- Identificação da origem do membership: manual, federated ou ambas.
- Bloqueio de novas associações manuais quando o modo federado está ativo.

Arquivos:

```text
icp_server/config.bal
icp_server/auth_service.bal
icp_server/modules/auth/oidc.bal
frontend/src/pages/AccessControl.tsx
frontend/src/pages/access-control/SSOMappingsTab.tsx
frontend/src/api/authQueries.ts
icp_server/custom_auth/OIDC_SETUP_GUIDE.md
```

### Exposição na UI

A aba SSO Group Mappings só aparece quando `ssoEnabled = true`. Isso torna a funcionalidade praticamente invisível em uma instalação padrão.

### Restrição encontrada

O controle de acesso federado requer:

```toml
ssoEnabled = true
passwordLoginDisabled = true
federatedAccessControlEnabled = true
```

A combinação de acesso federado com password login é recusada pela validação de configuração.

---

## 9. LDAP user store

### Conclusão

O projeto possui um backend alternativo de autenticação LDAP completo e ativado exclusivamente por configuração.

### Ativação

```toml
ldapUserStoreEnabled = true
```

### Capacidades

- Bind com usuário de serviço.
- Busca do usuário por filtro LDAP.
- Construção direta do DN por pattern.
- Configuração do atributo de username e display name.
- Leitura de grupos por `memberOf`.
- Busca inversa em grupos quando `memberOf` não está disponível.
- Configuração de base, filtro, atributo de nome e atributo de membership.
- TLS.
- Truststore configurável.
- Grupos LDAP capazes de conceder acesso administrativo.

Arquivos:

```text
icp_server/ldap_user_service.bal
docs/ldap-user-store.md
```

### Recomendação

Exibir no painel administrativo o status do user store atual e um diagnóstico básico, mesmo que as credenciais continuem sendo configuradas via arquivo ou secret externo.

---

## 10. Integração Moesif Metrics

### Conclusão

Além do OpenSearch, o projeto oferece uma integração operacional com Moesif para coleta e visualização de métricas.

### Capacidades

- Selecionar OpenSearch ou Moesif como backend de métricas.
- Consultar aplicações disponíveis via Moesif Management API.
- Criar dashboards a partir de templates.
- Persistir a associação entre integração e aplicação Moesif.
- Gerar dashboard embed.
- Exibir o dashboard dentro do ICP.
- Reconfigurar dashboards existentes.

### Suporte BI

- Snippet para `Config.toml`.
- Import `ballerinax/moesif`.
- Template de dashboard próprio.

### Suporte MI

- Configuração de Log4j.
- Fluent Bit.
- Lua transformation.
- Docker Compose.
- Arquivo `.env`.
- Template de dashboard específico para MI.

Arquivos:

```text
frontend/src/pages/Metrics.tsx
frontend/src/pages/MetricsMoesif.tsx
frontend/src/api/metricsMoesif.ts
frontend/src/assets/moesifMetricsTemplate.ts
frontend/src/assets/moesifMiMetrics.ts
frontend/src/assets/moesifMiMetricsTemplate.ts
icp_server/moesif_client.bal
```

### Recomendação

Documentar Moesif como integração oficial e explicar claramente quais credenciais são usadas somente durante o setup e quais dados permanecem armazenados.

---

## 11. Notificações em tempo real

### Conclusão

O projeto possui um canal WebSocket próprio para eventos operacionais, integrado ao painel global de notificações.

### Eventos encontrados

- Runtime ficou online.
- Runtime ficou offline.
- Log level foi alterado.

### Funcionamento

O browser conecta em:

```text
/runtime-status?environmentId=<uuid>&token=<jwt>
```

O JWT é enviado na query porque browsers não permitem headers customizados no handshake WebSocket padrão.

Arquivos:

```text
icp_server/runtime_ws_service.bal
frontend/src/api/wsClient.ts
frontend/src/api/subscriptions.ts
frontend/src/contexts/NotificationsContext.tsx
frontend/src/layouts/AppLayout.tsx
```

### Preferências

A opção `Runtime & log level alerts` é salva localmente em:

```text
localStorage: icp_notification_prefs
```

Arquivo:

```text
frontend/src/hooks/useNotificationPreferences.ts
```

### Limitações

- As preferências não são persistidas por usuário no backend.
- Não existe histórico durável das notificações no painel.
- Ações das notificações não parecem possuir navegação contextual completa.

---

## 12. Auditoria, sessões e proteção de contas

### Audit logs

O sistema registra eventos estruturados no banco e, opcionalmente, em arquivo.

Capacidades:

- Actor e username.
- Ação.
- Tipo e ID do recurso.
- Resultado.
- IP e User-Agent quando disponíveis.
- Contexto adicional sem copiar payloads sensíveis do upstream.
- Retenção configurável.
- Limpeza periódica.
- Tela de consulta com filtros.

Arquivos:

```text
icp_server/modules/storage/audit_repository.bal
icp_server/audit_proxy_utils.bal
frontend/src/pages/AuditLogs.tsx
```

Configuração:

```toml
enableAuditLogging = true
auditLogFilePath = "../logs/audit.log"
auditLogRetentionDays = 90
auditLogCleanupIntervalSeconds = 86400
```

### Refresh tokens

Capacidades:

- Refresh tokens persistidos somente como hash.
- Rotação opcional a cada uso.
- Limite de tokens ativos por usuário.
- Revogação do token atual.
- Revogação de todos os tokens do usuário.
- Limpeza periódica de tokens expirados e revogados.

Configuração:

```toml
refreshTokenExpiryTime = 86400
enableRefreshTokenRotation = true
maxRefreshTokensPerUser = 10
refreshTokenCleanupIntervalSeconds = 86400
```

Arquivos:

```text
icp_server/auth_service.bal
icp_server/modules/storage/auth_token_repository.bal
icp_server/refresh_token_cleanup_scheduler.bal
```

### Account lockout

Capacidades:

- Contagem de tentativas inválidas.
- Lockout após threshold configurável.
- Duração progressiva/exponencial.
- Limite máximo do período de bloqueio.
- Countdown na tela de login.
- Ação administrativa para desbloquear a conta.

Configuração:

```toml
lockoutThreshold = 5
lockoutBaseMinutes = 15
lockoutMaxMinutes = 60
```

Arquivos:

```text
icp_server/default_user_service.bal
frontend/src/components/LoginForm.tsx
frontend/src/pages/access-control/UsersTab.tsx
```

---

## Outros vestígios e código órfão

### Mock data

O diretório `frontend/src/mock-data` contém modelos e exemplos de:

- Organizations.
- Projects.
- Components.
- Navigation categories.
- Settings navigation.
- Notifications.
- Explore More.

Atualmente, o uso relevante encontrado é principalmente a página órfã de Organizations. Os demais arquivos aparentam ser remanescentes do scaffold inicial da interface.

### Paths legados

`frontend/src/paths.ts` documenta explicitamente uma seção de helpers legados para páginas ainda não migradas à nova matriz de navegação.

Entre eles permanecem URLs para:

- New Organization.
- Edit Organization.
- Organization Analytics.
- Analytics Logs.

Esses paths não possuem rotas equivalentes na configuração ativa.

### Logs de debug no frontend

Foram encontrados `console.log` permanentes em partes da aplicação, como:

- Montagem do NotificationsProvider.
- Conexões WebSocket.
- Eventos WebSocket recebidos.
- Quantidade de ambientes carregados no AppLayout.
- Ações mockadas na tela de Organizations.

Recomenda-se remover ou condicionar esses logs ao modo de desenvolvimento.

---

## Visão arquitetural consolidada

O projeto parece conter três camadas históricas.

### 1. Produto atual e funcional

- Projetos e integrações.
- Ambientes.
- Registro e monitoramento de runtimes.
- Descoberta de artefatos BI e MI.
- Logs e log levels.
- Metrics com OpenSearch e Moesif.
- RBAC por organização, projeto, integração e ambiente.
- Workflow Management.
- Operações de Micro Integrator.
- Audit logs.

### 2. Funcionalidades maduras, mas pouco descobertas

- LDAP.
- SSO-only.
- Controle de acesso federado.
- SSO Group Mappings com escopo.
- MI server management.
- Registry Browser.
- Carbon Application deployment.
- Runtime user management.
- Desired-state reconciliation.
- WebSocket notifications.
- Moesif dashboard automation.
- Account lockout e session rotation.

### 3. Visão de plataforma não concluída

- Multi-organization.
- Git repository integration.
- Pipelines.
- Releases.
- Deployment tracks.
- API versions e promotion.
- Analytics genérico.
- Topologia avançada de ambientes.

---

## Recomendações priorizadas

### Prioridade 1 — Definir o futuro de Organization

Tomar uma decisão explícita entre:

- ICP single-tenant com uma organização interna; ou
- ICP multi-tenant com Organizations gerenciáveis.

Essa decisão afeta quase todos os módulos e deve preceder a criação de uma simples tela de CRUD.

### Prioridade 2 — Remover ou isolar protótipos

- Remover `Organizations.tsx` enquanto o CRUD não existir, ou marcá-la explicitamente como protótipo fora do build.
- Remover `Analytics.tsx` e helpers relacionados se a página foi substituída por Metrics.
- Limpar mock data e settings navigation não utilizados.

### Prioridade 3 — Delimitar o schema público

- Remover campos de Git que não possuem comportamento.
- Marcar tipos legados como deprecated de forma consistente.
- Remover tipos de pipelines e deployment tracks caso não pertençam ao roadmap.
- Evitar que inputs públicos aceitem configurações que serão apenas armazenadas e ignoradas.

### Prioridade 4 — Melhorar a descoberta das features existentes

- Criar uma área MI Operations.
- Exibir status de configuração de LDAP e SSO.
- Explicar desired state e reconciliação na UI.
- Documentar Moesif como backend oficial.
- Oferecer links contextuais nas notificações operacionais.

### Prioridade 5 — Endurecimento e limpeza

- Remover `console.log` de produção.
- Adicionar testes de isolamento organizacional, mesmo enquanto houver apenas uma organização.
- Revisar todos os usos de `orgId = 1` e documentar se são temporários ou intencionais.
- Inventariar campos GraphQL sem consumidores.
- Inventariar páginas e path helpers sem rotas.

---

## Conclusão final

O projeto já é mais poderoso operacionalmente do que a navegação sugere. Em especial, as capacidades de Micro Integrator, controle de artefatos, SSO federado, LDAP, Moesif, notificações e segurança de sessão são funcionalidades reais e relativamente maduras.

Ao mesmo tempo, o código preserva uma visão de produto mais ampla que não foi concluída. Organization é o exemplo mais claro: toda a hierarquia está organizada como multi-tenant, mas a execução real permanece presa à Default Organization. Git, pipelines, releases, deployment tracks e ambientes avançados seguem o mesmo padrão em menor grau: o modelo existe antes da feature.

O melhor próximo passo não é necessariamente implementar tudo que está modelado. É decidir quais conceitos pertencem de fato ao produto, concluir os que fazem parte do roadmap e remover ou internalizar os demais para que o código e a interface comuniquem com precisão o que o ICP realmente oferece.
