-- Apply once after add_mi_deployments_feature_oracle.sql. Existing history is retained.
ALTER TABLE mi_deployment_operations ADD started_at VARCHAR2(40) NULL;
ALTER TABLE mi_deployment_operations ADD finished_at VARCHAR2(40) NULL;
ALTER TABLE mi_deployment_operations ADD duration_ms NUMBER(19) NULL;
ALTER TABLE mi_deployment_operations ADD selected_project_ids CLOB NULL;
ALTER TABLE mi_deployment_targets ADD project_name VARCHAR2(255) NULL;
ALTER TABLE mi_deployment_targets ADD component_name VARCHAR2(255) NULL;
ALTER TABLE mi_deployment_targets ADD environment_name VARCHAR2(255) NULL;
ALTER TABLE mi_deployment_targets ADD runtime_name VARCHAR2(255) NULL;
ALTER TABLE mi_deployment_targets ADD started_at VARCHAR2(40) NULL;
ALTER TABLE mi_deployment_targets ADD finished_at VARCHAR2(40) NULL;
ALTER TABLE mi_deployment_targets ADD duration_ms NUMBER(19) NULL;
ALTER TABLE mi_deployment_events ADD reason VARCHAR2(1000) NULL;
ALTER TABLE mi_deployment_events ADD http_status NUMBER(10) NULL;
ALTER TABLE mi_deployment_events ADD evidence CLOB NULL;
CREATE INDEX idx_mi_dep_org_created ON mi_deployment_operations (org_handler, created_at);
CREATE INDEX idx_mi_dep_target_op ON mi_deployment_targets (deployment_id);
CREATE INDEX idx_mi_dep_event_op ON mi_deployment_events (deployment_id, created_at);
