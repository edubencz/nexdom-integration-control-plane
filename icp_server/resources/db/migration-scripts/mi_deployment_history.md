# MI deployment history migration

Apply `add_mi_deployment_history_<database>.sql` once, after the existing
`add_mi_deployments_feature_<database>.sql`, before starting this server version.
Supported dialects: PostgreSQL, H2, MySQL, SQL Server, Oracle.
Fresh installations already include both schema revisions in their init script.
Do not rerun the initial schema against an existing installation.

The migration only adds nullable columns and indexes. Existing operations, targets,
events and artifact content are retained. Old records have no reliable start/end
times or name snapshots; these values remain null instead of being reconstructed
from the last update time or present-day runtime names.

- Operations: UTC ISO start/end timestamps, duration in milliseconds, selected
  project IDs (JSON array), and the existing parent operation link for retries.
- Targets: project/component/environment/runtime name snapshots, UTC ISO start/end
  timestamps and duration. Existing result, attempt, HTTP status and evidence
  columns are populated and returned by the API.
- Events: chronological phase/message records with reason, HTTP status and JSON
  evidence. Rechecks append events and do not change the original execution time.

History and referenced artifacts have no automatic expiration. Manual deletion
requires deployment management permission and is rejected for RUNNING/CANCELLING
operations. An artifact is removed only after its final referencing operation is
deleted. The legacy history/artifact retention settings do not expire referenced
history. No runtime log files or credentials are copied into deployment events.

The server recovers interrupted operations once during startup. Unfinished targets
become INDETERMINATE; their actual completion time is unknown and remains null.
Recovery never repeats a runtime DELETE/POST. Recheck and retry are explicit actions.
The current worker model assumes one active control-plane process; this change
is not a distributed worker/leader-election implementation.

## Verification

- `gradlew :icp_server:initTestH2` prepares only the test databases.
- `bal test --offline --groups mi-deployments` runs repository, HTTP permission,
  rollback, recovery, cancellation and simulated HTTPS runtime tests.
- `npm run build:check` in `frontend` checks TypeScript and produces a Vite build.
- HTTP detail: `GET /icp/mi_deployments/{id}?orgHandler=default`.
- Events: `GET /icp/mi_deployments/{id}/events?orgHandler=default&targetId=...&limit=25&offset=0`.
- UI detail links use `?deploymentId=...`; creation uses `?view=new`.
