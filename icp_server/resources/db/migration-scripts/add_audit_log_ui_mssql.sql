IF COL_LENGTH('audit_logs', 'org_id') IS NULL ALTER TABLE audit_logs ADD org_id INT NULL CONSTRAINT df_audit_org_migration DEFAULT 1;
IF COL_LENGTH('audit_logs', 'event_source') IS NULL ALTER TABLE audit_logs ADD event_source NVARCHAR(30) NOT NULL CONSTRAINT df_audit_source_migration DEFAULT 'RUNTIME';
IF COL_LENGTH('audit_logs', 'actor_username') IS NULL ALTER TABLE audit_logs ADD actor_username NVARCHAR(255) NULL;
DECLARE @constraint nvarchar(200);
SELECT TOP 1 @constraint = cc.name FROM sys.check_constraints cc JOIN sys.tables t ON t.object_id=cc.parent_object_id WHERE t.name='permissions' AND cc.definition LIKE '%Workflow-Management%';
IF @constraint IS NOT NULL EXEC('ALTER TABLE permissions DROP CONSTRAINT ' + @constraint);
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID('permissions') AND name='chk_permission_domain_audit') ALTER TABLE permissions ADD CONSTRAINT chk_permission_domain_audit CHECK (permission_domain IN ('Integration-Management','Environment-Management','Observability-Management','Project-Management','User-Management','Workflow-Management','Audit-Management'));
IF NOT EXISTS (SELECT 1 FROM permissions WHERE permission_name = 'audit_mgt:view')
INSERT INTO permissions (permission_id, permission_name, permission_domain, resource_type, action, description)
VALUES (CONVERT(VARCHAR(36), NEWID()), 'audit_mgt:view', 'Audit-Management', 'audit_logs', 'view', 'View audit logs');
IF NOT EXISTS (SELECT 1 FROM role_permission_mapping m JOIN roles_v2 r ON r.role_id=m.role_id JOIN permissions p ON p.permission_id=m.permission_id WHERE p.permission_name='audit_mgt:view')
INSERT INTO role_permission_mapping (role_id, permission_id) SELECT r.role_id,p.permission_id FROM roles_v2 r CROSS JOIN permissions p WHERE r.role_name IN ('Super Admin','Admin') AND p.permission_name='audit_mgt:view';
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='idx_audit_logs_source_timestamp') CREATE INDEX idx_audit_logs_source_timestamp ON audit_logs(event_source, timestamp);
GO
