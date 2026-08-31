ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS org_id INT NULL DEFAULT 1;
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS event_source VARCHAR(30) NOT NULL DEFAULT 'RUNTIME';
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS actor_username VARCHAR(255) NULL;
ALTER TABLE permissions MODIFY permission_domain ENUM('Integration-Management','Environment-Management','Observability-Management','Project-Management','User-Management','Workflow-Management','Audit-Management') NOT NULL;
INSERT INTO permissions (permission_id, permission_name, permission_domain, resource_type, action, description)
SELECT UUID(), 'audit_mgt:view', 'Audit-Management', 'audit_logs', 'view', 'View audit logs'
WHERE NOT EXISTS (SELECT 1 FROM permissions WHERE permission_name = 'audit_mgt:view');
INSERT INTO role_permission_mapping (role_id, permission_id)
SELECT r.role_id, p.permission_id FROM roles_v2 r, permissions p
WHERE r.role_name IN ('Super Admin', 'Admin') AND p.permission_name = 'audit_mgt:view'
AND NOT EXISTS (SELECT 1 FROM role_permission_mapping m WHERE m.role_id = r.role_id AND m.permission_id = p.permission_id);
CREATE INDEX idx_audit_logs_source_timestamp ON audit_logs(event_source, timestamp);
