BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE audit_logs ADD (org_id NUMBER(10) DEFAULT 1)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE audit_logs ADD (event_source VARCHAR2(30 CHAR) DEFAULT ''RUNTIME'' NOT NULL)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE audit_logs ADD (actor_username VARCHAR2(255 CHAR))';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF;
END;
/
BEGIN
  FOR c IN (SELECT constraint_name FROM user_constraints WHERE table_name = 'PERMISSIONS' AND constraint_type = 'C') LOOP
    EXECUTE IMMEDIATE 'ALTER TABLE permissions DROP CONSTRAINT ' || c.constraint_name;
  END LOOP;
  EXECUTE IMMEDIATE 'ALTER TABLE permissions ADD CONSTRAINT chk_permission_domain_audit CHECK (permission_domain IN (''Integration-Management'',''Environment-Management'',''Observability-Management'',''Project-Management'',''User-Management'',''Workflow-Management'',''Audit-Management''))';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -2275 THEN RAISE; END IF;
END;
/
INSERT INTO permissions (permission_id, permission_name, permission_domain, resource_type, action, description)
SELECT REGEXP_REPLACE(LOWER(RAWTOHEX(SYS_GUID())), '^(.{8})(.{4})(.{4})(.{4})(.{12})$', '\1-\2-\3-\4-\5'), 'audit_mgt:view', 'Audit-Management', 'audit_logs', 'view', 'View audit logs' FROM dual
WHERE NOT EXISTS (SELECT 1 FROM permissions WHERE permission_name = 'audit_mgt:view');
INSERT INTO role_permission_mapping (role_id, permission_id)
SELECT r.role_id, p.permission_id FROM roles_v2 r CROSS JOIN permissions p
WHERE r.role_name IN ('Super Admin', 'Admin') AND p.permission_name = 'audit_mgt:view'
AND NOT EXISTS (SELECT 1 FROM role_permission_mapping m WHERE m.role_id = r.role_id AND m.permission_id = p.permission_id);
BEGIN
  EXECUTE IMMEDIATE 'CREATE INDEX idx_audit_logs_source_timestamp ON audit_logs(event_source, timestamp)';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -955 THEN RAISE; END IF;
END;
/
