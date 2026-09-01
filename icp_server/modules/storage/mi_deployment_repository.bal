import icp_server.types;
import ballerina/sql;

public isolated function persistMIDeploymentEvent(string eventId, string deploymentId, string? targetId, string phase, string message) returns error? {
    sql:ParameterizedQuery query = `INSERT INTO mi_deployment_events
        (event_id, deployment_id, target_id, phase, message, created_at)
        VALUES (${eventId}, ${deploymentId}, ${targetId}, ${phase}, ${message}, CURRENT_TIMESTAMP)`;
    sql:ExecutionResult|sql:Error result = dbClient->execute(query);
    if result is sql:Error { return result; }
}

// Persists the immutable artifact and operation envelope before any runtime
// call. This is intentionally small and dialect-neutral; target/event writes
// can be appended without changing the artifact contract.
public isolated function persistMIDeployment(types:MIDeploymentOperation operation, byte[] content) returns error? {
    sql:ParameterizedQuery artifact = `INSERT INTO mi_deployment_artifacts
        (artifact_id, file_name, artifact_name, artifact_version, sha256, file_size, content, expires_at, created_at)
        VALUES (${operation.artifactId}, ${operation.fileName}, ${operation.artifactName}, ${operation.artifactVersion},
        ${operation.sha256}, ${operation.fileSize}, ${content}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`;
    sql:ExecutionResult|sql:Error artifactResult = dbClient->execute(artifact);
    if artifactResult is sql:Error { return artifactResult; }
    sql:ParameterizedQuery op = `INSERT INTO mi_deployment_operations
        (deployment_id, org_id, org_handler, artifact_id, status, created_by, version, created_at, updated_at)
        VALUES (${operation.deploymentId}, ${operation.orgId}, ${operation.orgHandler}, ${operation.artifactId},
        ${operation.status.toString()}, ${operation.createdBy}, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`;
    sql:ExecutionResult|sql:Error operationResult = dbClient->execute(op);
    if operationResult is sql:Error { return operationResult; }
}

public isolated function persistMIDeploymentTarget(types:MIDeploymentTarget target) returns error? {
    sql:ParameterizedQuery query = `INSERT INTO mi_deployment_targets
        (target_id, deployment_id, project_id, component_id, environment_id, runtime_id,
         production, eligible, conflict, delete_before_upload, phase, attempt, reason, message, evidence, updated_at)
        VALUES (${target.targetId}, ${target.deploymentId}, ${target.projectId}, ${target.componentId},
         ${target.environmentId}, ${target.runtimeId}, ${target.production}, ${target.eligible},
         ${target.conflictDetected}, ${target.deleteBeforeUpload}, ${target.phase.toString()}, ${target.attempt},
         ${target.reason}, ${target.message}, ${string `[]`}, CURRENT_TIMESTAMP)`;
    sql:ExecutionResult|sql:Error result = dbClient->execute(query);
    if result is sql:Error { return result; }
}

public isolated function updateMIDeploymentTarget(types:MIDeploymentTarget target) returns error? {
    sql:ParameterizedQuery query = `UPDATE mi_deployment_targets SET conflict=${target.conflictDetected},
        delete_before_upload=${target.deleteBeforeUpload}, phase=${target.phase.toString()}, attempt=${target.attempt},
        reason=${target.reason}, message=${target.message}, http_status=${target.httpStatus}, updated_at=CURRENT_TIMESTAMP
        WHERE target_id=${target.targetId}`;
    sql:ExecutionResult|sql:Error result = dbClient->execute(query);
    if result is sql:Error { return result; }
}

public isolated function claimMIDeploymentTarget(string targetId, int leaseSeconds) returns boolean|error {
    sql:ParameterizedQuery query = `UPDATE mi_deployment_targets SET lease_until=CURRENT_TIMESTAMP, phase='UPLOADING', updated_at=CURRENT_TIMESTAMP
        WHERE target_id=${targetId} AND phase IN ('VALIDATING','QUEUED','READY')`;
    sql:ExecutionResult|sql:Error result = dbClient->execute(query);
    if result is sql:Error { return result; }
    return (result.affectedRowCount ?: 0) > 0;
}

public isolated function releaseMIDeploymentTarget(string targetId) returns error? {
    sql:ParameterizedQuery query = `UPDATE mi_deployment_targets SET lease_until=NULL, updated_at=CURRENT_TIMESTAMP WHERE target_id=${targetId}`;
    sql:ExecutionResult|sql:Error result = dbClient->execute(query);
    if result is sql:Error { return result; }
}

public isolated function updateMIDeploymentOperation(types:MIDeploymentOperation operation) returns error? {
    sql:ParameterizedQuery query = `UPDATE mi_deployment_operations SET status=${operation.status.toString()}, version=version+1, updated_at=CURRENT_TIMESTAMP WHERE deployment_id=${operation.deploymentId}`;
    sql:ExecutionResult|sql:Error result = dbClient->execute(query);
    if result is sql:Error { return result; }
}

public isolated function listMIDeploymentOperations(string? orgHandler, int pageLimit = 10, int pageOffset = 0) returns record {| json[] items; int total; |}|error {
    int safePageLimit = pageLimit < 1 ? 10 : pageLimit > 100 ? 100 : pageLimit;
    int safePageOffset = pageOffset < 0 ? 0 : pageOffset;
    sql:ParameterizedQuery countQuery = orgHandler is string
        ? `SELECT COUNT(*) AS total FROM mi_deployment_operations WHERE org_handler=${orgHandler}`
        : `SELECT COUNT(*) AS total FROM mi_deployment_operations`;
    record {| int total; |}|sql:Error countRow = dbClient->queryRow(countQuery);
    if countRow is sql:Error { return countRow; }
    sql:ParameterizedQuery query = orgHandler is string
        ? `SELECT o.deployment_id, o.org_handler, o.status, o.created_by, o.created_at, o.updated_at,
             a.file_name, a.artifact_name, a.artifact_version, a.file_size, a.sha256
             FROM mi_deployment_operations o JOIN mi_deployment_artifacts a ON a.artifact_id=o.artifact_id
             WHERE o.org_handler=${orgHandler} ORDER BY o.created_at DESC LIMIT ${safePageLimit} OFFSET ${safePageOffset}`
        : `SELECT o.deployment_id, o.org_handler, o.status, o.created_by, o.created_at, o.updated_at,
             a.file_name, a.artifact_name, a.artifact_version, a.file_size, a.sha256
             FROM mi_deployment_operations o JOIN mi_deployment_artifacts a ON a.artifact_id=o.artifact_id ORDER BY o.created_at DESC LIMIT ${safePageLimit} OFFSET ${safePageOffset}`;
    stream<record {| string deployment_id; string org_handler; string status; string created_by; string created_at; string updated_at; string file_name; string artifact_name; string artifact_version; int file_size; string sha256; |}, sql:Error?> rows = dbClient->query(query);
    json[] result = [];
    check from record {| string deployment_id; string org_handler; string status; string created_by; string created_at; string updated_at; string file_name; string artifact_name; string artifact_version; int file_size; string sha256; |} row in rows
        do { result.push({id: row.deployment_id, orgHandler: row.org_handler, status: row.status, artifactName: row.artifact_name, artifactVersion: row.artifact_version, fileName: row.file_name, fileSize: row.file_size, sha256: row.sha256, createdAt: row.created_at, updatedAt: row.updated_at, targets: []}); };
    return {items: result, total: countRow.total};
}

public isolated function getMIDeploymentOperation(string deploymentId) returns json?|error {
    sql:ParameterizedQuery query = `SELECT o.deployment_id, o.org_handler, o.status, o.created_by, o.created_at, o.updated_at,
        a.file_name, a.artifact_name, a.artifact_version, a.file_size, a.sha256
        FROM mi_deployment_operations o JOIN mi_deployment_artifacts a ON a.artifact_id=o.artifact_id
        WHERE o.deployment_id=${deploymentId}`;
    record {| string deployment_id; string org_handler; string status; string created_by; string created_at; string updated_at; string file_name; string artifact_name; string artifact_version; int file_size; string sha256; |}|sql:Error row = dbClient->queryRow(query);
    if row is sql:Error { return row; }
    json[] targets = [];
    sql:ParameterizedQuery targetQuery = `SELECT target_id, project_id, component_id, environment_id, runtime_id, production, eligible, conflict AS conflict_flag, delete_before_upload, phase, attempt, reason, message, updated_at FROM mi_deployment_targets WHERE deployment_id=${deploymentId}`;
    stream<record {| string target_id; string project_id; string component_id; string environment_id; string runtime_id; boolean production; boolean eligible; boolean conflict_flag; boolean delete_before_upload; string phase; int attempt; string? reason; string? message; string updated_at; |}, sql:Error?> targetRows = dbClient->query(targetQuery);
    check from record {| string target_id; string project_id; string component_id; string environment_id; string runtime_id; boolean production; boolean eligible; boolean conflict_flag; boolean delete_before_upload; string phase; int attempt; string? reason; string? message; string updated_at; |} target in targetRows
        do { targets.push({targetId: target.target_id, deploymentId, projectId: target.project_id, componentId: target.component_id, environmentId: target.environment_id, runtimeId: target.runtime_id, production: target.production, eligible: target.eligible, conflictDetected: target.conflict_flag, deleteBeforeUpload: target.delete_before_upload, phase: target.phase, attempt: target.attempt, reason: target.reason, message: target.message, updatedAt: target.updated_at}); };
    return {id: row.deployment_id, orgHandler: row.org_handler, status: row.status, artifactName: row.artifact_name, artifactVersion: row.artifact_version, fileName: row.file_name, fileSize: row.file_size, sha256: row.sha256, createdAt: row.created_at, updatedAt: row.updated_at, targets};
}

public isolated function loadMIDeploymentMemory(string deploymentId) returns record {| types:MIDeploymentOperation operation; byte[] content; |}|error {
    sql:ParameterizedQuery query = `SELECT o.deployment_id, o.org_id, o.org_handler, o.artifact_id, o.status, o.created_by, o.created_at, o.updated_at,
        a.file_name, a.artifact_name, a.artifact_version, a.file_size, a.sha256, a.content
        FROM mi_deployment_operations o JOIN mi_deployment_artifacts a ON a.artifact_id=o.artifact_id WHERE o.deployment_id=${deploymentId}`;
    record {| string deployment_id; int org_id; string org_handler; string artifact_id; string status; string created_by; string created_at; string updated_at; string file_name; string artifact_name; string artifact_version; int file_size; string sha256; byte[] content; |} row = check dbClient->queryRow(query);
    types:MIDeploymentStatus status = row.status == "DRAFT" ? types:DRAFT : row.status == "PREFLIGHT" ? types:PREFLIGHT : row.status == "AWAITING_DECISIONS" ? types:AWAITING_DECISIONS : row.status == "READY" ? types:READY : row.status == "RUNNING" ? types:RUNNING : row.status == "CANCELLING" ? types:CANCELLING : row.status == "CANCELLED" ? types:CANCELLED : row.status == "FAILED" ? types:FAILED : row.status == "COMPLETED" ? types:COMPLETED : types:COMPLETED_WITH_ISSUES;
    types:MIDeploymentOperation operation = {deploymentId: row.deployment_id, orgId: row.org_id, orgHandler: row.org_handler, artifactId: row.artifact_id, artifactName: row.artifact_name, artifactVersion: row.artifact_version, fileName: row.file_name, fileSize: row.file_size, sha256: row.sha256, status, createdBy: row.created_by, createdAt: row.created_at, updatedAt: row.updated_at};
    return {operation, content: row.content};
}

// On process restart, any target left in a mutating phase must be treated as
// indeterminate; the next explicit recheck can safely determine whether MI
// accepted the request without replaying a DELETE/POST blindly.
public isolated function recoverMIDeploymentLeases() returns error? {
    sql:ParameterizedQuery query = `UPDATE mi_deployment_targets SET phase='INDETERMINATE', message='Recovered after ICP restart; runtime recheck required', updated_at=CURRENT_TIMESTAMP WHERE phase IN ('DELETING','VERIFYING_DELETE','UPLOADING','VERIFYING_DEPLOY')`;
    sql:ExecutionResult|sql:Error result = dbClient->execute(query);
    if result is sql:Error { return result; }
}

public isolated function deleteMIDeployment(string deploymentId) returns error? {
    sql:ParameterizedQuery query = `DELETE FROM mi_deployment_operations WHERE deployment_id=${deploymentId}`;
    sql:ExecutionResult|sql:Error result = dbClient->execute(query);
    if result is sql:Error { return result; }
}

public isolated function cleanupMIDeploymentData() returns error? {
    sql:ParameterizedQuery artifacts = `DELETE FROM mi_deployment_artifacts WHERE expires_at < CURRENT_TIMESTAMP`;
    sql:ExecutionResult|sql:Error artifactResult = dbClient->execute(artifacts);
    if artifactResult is sql:Error { return artifactResult; }
}
