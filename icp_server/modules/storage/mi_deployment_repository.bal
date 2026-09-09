import icp_server.types;
import ballerina/sql;
import ballerina/time;
import ballerina/uuid;

public isolated function miDeploymentNow() returns string => time:utcToString(time:utcNow());

public isolated function miDeploymentDuration(string? startedAt, string finishedAt) returns int? {
    if startedAt is () { return (); }
    time:Utc|error startTime = time:utcFromString(startedAt);
    time:Utc|error endTime = time:utcFromString(finishedAt);
    if startTime is error || endTime is error { return (); }
    int elapsed = <int>(time:utcDiffSeconds(endTime, startTime) * 1000);
    return elapsed < 0 ? 0 : elapsed;
}

public isolated function miDeploymentTerminal(types:MIDeploymentTargetPhase phase) returns boolean {
    return phase != types:QUEUED && phase != types:VALIDATING && phase != types:DELETING &&
        phase != types:VERIFYING_DELETE && phase != types:UPLOADING && phase != types:VERIFYING_DEPLOY;
}

public isolated function miDeploymentStatus(types:MIDeploymentTarget[] targets) returns types:MIDeploymentStatus {
    if targets.some(t => !miDeploymentTerminal(t.phase)) { return types:RUNNING; }
    if targets.some(t => t.phase == types:FAILED || t.phase == types:FAULTY || t.phase == types:INDETERMINATE || t.phase == types:STALE_PREFLIGHT) { return types:COMPLETED_WITH_ISSUES; }
    if targets.length() > 0 && targets.every(t => t.phase == types:CANCELLED) { return types:CANCELLED; }
    if targets.some(t => t.phase != types:SUCCEEDED) || targets.length() == 0 { return types:COMPLETED_WITH_ISSUES; }
    return types:COMPLETED;
}

public isolated function miDeploymentSummary(types:MIDeploymentTarget[] targets) returns json {
    return {total: targets.length(), succeeded: targets.filter(t => t.phase == types:SUCCEEDED).length(),
        failed: targets.filter(t => t.phase == types:FAILED || t.phase == types:FAULTY || t.phase == types:STALE_PREFLIGHT).length(),
        indeterminate: targets.filter(t => t.phase == types:INDETERMINATE).length(),
        cancelled: targets.filter(t => t.phase == types:CANCELLED).length(),
        skipped: targets.filter(t => t.phase == types:SKIPPED_CONFLICT || t.phase == types:SKIPPED_INELIGIBLE).length(),
        pending: targets.filter(t => !miDeploymentTerminal(t.phase)).length()};
}

isolated function miPage(sql:ParameterizedQuery query, int pageLimit, int pageOffset) returns sql:ParameterizedQuery {
    int n = pageLimit < 1 ? 10 : pageLimit > 100 ? 100 : pageLimit;
    int skip = pageOffset < 0 ? 0 : pageOffset;
    return dbType == MSSQL || dbType == ORACLE
        ? sql:queryConcat(query, ` OFFSET ${skip} ROWS FETCH NEXT ${n} ROWS ONLY`)
        : sql:queryConcat(query, ` LIMIT ${n} OFFSET ${skip}`);
}

public isolated function persistMIDeploymentEvent(string eventId, string deploymentId, string? targetId, string phase, string message,
        string? reason = (), int? httpStatus = (), string[] evidence = []) returns error? {
    sql:ExecutionResult _ = check dbClient->execute(`INSERT INTO mi_deployment_events
        (event_id, deployment_id, target_id, phase, message, reason, http_status, evidence, created_at)
        VALUES (${eventId}, ${deploymentId}, ${targetId}, ${phase}, ${message.substring(0, message.length() > 4000 ? 4000 : message.length())},
        ${reason}, ${httpStatus}, ${evidence.toJsonString()}, CURRENT_TIMESTAMP)`);
}

isolated function insertMIOperation(types:MIDeploymentOperation o) returns error? {
    sql:ExecutionResult _ = check dbClient->execute(`INSERT INTO mi_deployment_operations
        (deployment_id, org_id, org_handler, artifact_id, status, created_by, parent_deployment_id, version, created_at, updated_at,
         started_at, finished_at, duration_ms, selected_project_ids)
        VALUES (${o.deploymentId}, ${o.orgId}, ${o.orgHandler}, ${o.artifactId}, ${o.status.toString()}, ${o.createdBy},
        ${o.parentDeploymentId}, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ${o.startedAt}, ${o.finishedAt}, ${o.durationMs}, ${o.selectedProjectIds.toJsonString()})`);
}

public isolated function persistMIDeployment(types:MIDeploymentOperation operation, byte[] content) returns error? {
    transaction {
        sql:ExecutionResult _ = check dbClient->execute(`INSERT INTO mi_deployment_artifacts
            (artifact_id, file_name, artifact_name, artifact_version, sha256, file_size, content, expires_at, created_at)
            VALUES (${operation.artifactId}, ${operation.fileName}, ${operation.artifactName}, ${operation.artifactVersion},
            ${operation.sha256}, ${operation.fileSize}, ${content}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)`);
        check insertMIOperation(operation);
        check persistMIDeploymentEvent(uuid:createType4AsString(), operation.deploymentId, (), operation.status.toString(), "Artifact uploaded");
        check commit;
    }
}

public isolated function persistMIDeploymentRetry(types:MIDeploymentOperation operation, types:MIDeploymentTarget[] targets) returns error? {
    transaction {
        // Serialize sharing/deletion of the binary so a retry cannot reference a removed artifact.
        sql:ExecutionResult artifact = check dbClient->execute(`UPDATE mi_deployment_artifacts SET artifact_id=artifact_id WHERE artifact_id=${operation.artifactId}`);
        if artifact.affectedRowCount != 1 { fail error("Deployment artifact is no longer available"); }
        check insertMIOperation(operation);
        foreach var target in targets {
            check persistMIDeploymentTarget(target);
            check persistMIDeploymentEvent(uuid:createType4AsString(), operation.deploymentId, target.targetId, "QUEUED", "New deployment attempt prepared");
        }
        check commit;
    }
}

public isolated function updateMIDeploymentOperation(types:MIDeploymentOperation o) returns error? {
    sql:ExecutionResult result = check dbClient->execute(`UPDATE mi_deployment_operations SET status=${o.status.toString()},
        version=version+1, updated_at=CURRENT_TIMESTAMP, started_at=${o.startedAt}, finished_at=${o.finishedAt},
        duration_ms=${o.durationMs}, selected_project_ids=${o.selectedProjectIds.toJsonString()} WHERE deployment_id=${o.deploymentId}`);
    if result.affectedRowCount != 1 { return error("Deployment no longer exists"); }
}

public isolated function saveMIDeploymentOperation(types:MIDeploymentOperation operation, string message) returns error? {
    transaction {
        check updateMIDeploymentOperation(operation);
        check persistMIDeploymentEvent(uuid:createType4AsString(), operation.deploymentId, (), operation.status.toString(), message);
        check commit;
    }
}

public isolated function persistMIDeploymentTarget(types:MIDeploymentTarget t) returns error? {
    sql:ExecutionResult _ = check dbClient->execute(`INSERT INTO mi_deployment_targets (target_id, deployment_id, project_id, project_name, component_id, component_name, environment_id, environment_name, runtime_id, runtime_name, production, eligible, conflict, delete_before_upload, phase, attempt, reason, http_status, message, evidence, started_at, finished_at, duration_ms, updated_at)
        VALUES (${t.targetId}, ${t.deploymentId}, ${t.projectId}, ${t.projectName}, ${t.componentId}, ${t.componentName}, ${t.environmentId}, ${t.environmentName}, ${t.runtimeId}, ${t.runtimeName}, ${t.production}, ${t.eligible}, ${t.conflictDetected}, ${t.deleteBeforeUpload}, ${t.phase.toString()}, ${t.attempt}, ${t.reason}, ${t.httpStatus}, ${t.message}, ${t.evidence.toJsonString()}, ${t.startedAt}, ${t.finishedAt}, ${t.durationMs}, CURRENT_TIMESTAMP)`);
}

public isolated function updateMIDeploymentTarget(types:MIDeploymentTarget t) returns error? {
    sql:ExecutionResult result = check dbClient->execute(`UPDATE mi_deployment_targets SET
        project_id=${t.projectId}, project_name=${t.projectName}, component_id=${t.componentId}, component_name=${t.componentName}, environment_id=${t.environmentId}, environment_name=${t.environmentName}, runtime_id=${t.runtimeId}, runtime_name=${t.runtimeName}, production=${t.production}, eligible=${t.eligible}, conflict=${t.conflictDetected}, delete_before_upload=${t.deleteBeforeUpload}, phase=${t.phase.toString()}, attempt=${t.attempt}, reason=${t.reason}, http_status=${t.httpStatus}, message=${t.message}, evidence=${t.evidence.toJsonString()}, started_at=${t.startedAt}, finished_at=${t.finishedAt}, duration_ms=${t.durationMs}, updated_at=CURRENT_TIMESTAMP WHERE target_id=${t.targetId} AND deployment_id=${t.deploymentId}`);
    if result.affectedRowCount != 1 { return error("Deployment target no longer exists"); }
}

public isolated function saveMIDeploymentTarget(types:MIDeploymentTarget target) returns error? {
    transaction {
        check updateMIDeploymentTarget(target);
        check persistMIDeploymentEvent(uuid:createType4AsString(), target.deploymentId, target.targetId,
            target.phase.toString(), target.message ?: "Target phase updated", target.reason, target.httpStatus, target.evidence);
        check commit;
    }
}

public isolated function replaceMIDeploymentTargets(types:MIDeploymentOperation operation, types:MIDeploymentTarget[] targets) returns error? {
    transaction {
        sql:ExecutionResult guard = check dbClient->execute(`UPDATE mi_deployment_operations SET version=version+1
            WHERE deployment_id=${operation.deploymentId} AND status IN ('DRAFT','PREFLIGHT','AWAITING_DECISIONS','READY') AND started_at IS NULL`);
        if guard.affectedRowCount != 1 { fail error("Deployment preparation is no longer editable"); }
        sql:ExecutionResult _ = check dbClient->execute(`DELETE FROM mi_deployment_events WHERE deployment_id=${operation.deploymentId} AND target_id IS NOT NULL`);
        sql:ExecutionResult _ = check dbClient->execute(`DELETE FROM mi_deployment_targets WHERE deployment_id=${operation.deploymentId}`);
        foreach var target in targets {
            check persistMIDeploymentTarget(target);
            check persistMIDeploymentEvent(uuid:createType4AsString(), target.deploymentId, target.targetId, target.phase.toString(), target.reason ?: "Preflight target prepared");
        }
        check updateMIDeploymentOperation(operation);
        check persistMIDeploymentEvent(uuid:createType4AsString(), operation.deploymentId, (), operation.status.toString(), "Preflight snapshot replaced");
        check commit;
    }
}

type MITargetRow record {|
    string target_id;
    string deployment_id;
    string project_id;
    string? project_name;
    string component_id;
    string? component_name;
    string environment_id;
    string? environment_name;
    string runtime_id;
    string? runtime_name;
    boolean production;
    boolean eligible;
    boolean conflict_flag;
    boolean delete_before_upload;
    string phase;
    int attempt;
    string? reason;
    int? http_status;
    string? message;
    string? evidence;
    string? started_at;
    string? finished_at;
    int? duration_ms;
    string updated_at;
|};

public isolated function loadMIDeploymentTargets(string deploymentId) returns types:MIDeploymentTarget[]|error {
    stream<MITargetRow, sql:Error?> rows = dbClient->query(`SELECT target_id, deployment_id, project_id, project_name, component_id, component_name, environment_id, environment_name, runtime_id, runtime_name, production, eligible, conflict AS conflict_flag, delete_before_upload, phase, attempt, reason, http_status, message, evidence, started_at, finished_at, duration_ms, updated_at
        FROM mi_deployment_targets WHERE deployment_id=${deploymentId} ORDER BY project_id, environment_id, runtime_id, target_id`);
    MITargetRow[] data = check from var row in rows select row;
    types:MIDeploymentTarget[] targets = [];
    foreach var row in data {
        types:MIDeploymentTargetPhase phase = check row.phase.cloneWithType();
        string[] evidence = [];
        if row.evidence is string { json parsed = check (<string>row.evidence).fromJsonString(); evidence = check parsed.cloneWithType(); }
        targets.push({
            targetId: row.target_id,
            deploymentId: row.deployment_id,
            projectId: row.project_id,
            projectName: row.project_name ?: "",
            componentId: row.component_id,
            componentName: row.component_name ?: "",
            environmentId: row.environment_id,
            environmentName: row.environment_name ?: "",
            runtimeId: row.runtime_id,
            runtimeName: row.runtime_name ?: "",
            production: row.production,
            eligible: row.eligible,
            conflictDetected: row.conflict_flag,
            deleteBeforeUpload: row.delete_before_upload,
            phase: phase,
            attempt: row.attempt,
            reason: row.reason,
            httpStatus: row.http_status,
            message: row.message,
            evidence: evidence,
            startedAt: row.started_at,
            finishedAt: row.finished_at,
            durationMs: row.duration_ms,
            updatedAt: row.updated_at
        });
    }
    return targets;
}

type MIOperationRow record {|
    string deployment_id; int org_id; string org_handler; string artifact_id; string status; string created_by;
    string? parent_deployment_id; string created_at; string updated_at; string? started_at; string? finished_at;
    int? duration_ms; string? selected_project_ids; string file_name; string artifact_name; string artifact_version;
    int file_size; string sha256;
|};

public isolated function loadMIDeploymentOperation(string deploymentId) returns types:MIDeploymentOperation?|error {
    stream<MIOperationRow, sql:Error?> rows = dbClient->query(`SELECT o.deployment_id, o.org_id, o.org_handler, o.artifact_id, o.status,
        o.created_by, o.parent_deployment_id, o.created_at, o.updated_at, o.started_at, o.finished_at, o.duration_ms, o.selected_project_ids,
        a.file_name, a.artifact_name, a.artifact_version, a.file_size, a.sha256
        FROM mi_deployment_operations o JOIN mi_deployment_artifacts a ON a.artifact_id=o.artifact_id WHERE o.deployment_id=${deploymentId}`);
    MIOperationRow[] data = check from var row in rows select row;
    if data.length() == 0 { return (); }
    MIOperationRow row = data[0];
    types:MIDeploymentStatus status = check row.status.cloneWithType();
    string[] selectedProjectIds = [];
    if row.selected_project_ids is string { json parsed = check (<string>row.selected_project_ids).fromJsonString(); selectedProjectIds = check parsed.cloneWithType(); }
    return {deploymentId: row.deployment_id, orgId: row.org_id, orgHandler: row.org_handler, artifactId: row.artifact_id,
        status, createdBy: row.created_by, parentDeploymentId: row.parent_deployment_id, createdAt: row.created_at, updatedAt: row.updated_at,
        startedAt: row.started_at, finishedAt: row.finished_at, durationMs: row.duration_ms, selectedProjectIds,
        fileName: row.file_name, artifactName: row.artifact_name, artifactVersion: row.artifact_version, fileSize: row.file_size, sha256: row.sha256};
}

public isolated function miDeploymentPayload(types:MIDeploymentOperation o, types:MIDeploymentTarget[] targets, boolean detail = true) returns json {
    // Keep the immutable user id in storage, but expose the human-readable
    // display name in history responses. If the account was removed, the
    // resolver deliberately falls back to the original id.
    string? author = getDisplayNameById(o.createdBy);
    map<json> payload = {id: o.deploymentId, orgHandler: o.orgHandler, status: o.status.toString(), createdBy: author,
        parentDeploymentId: o.parentDeploymentId, createdAt: o.createdAt, updatedAt: o.updatedAt, startedAt: o.startedAt,
        finishedAt: o.finishedAt, durationMs: o.durationMs, selectedProjectIds: o.selectedProjectIds,
        fileName: o.fileName, artifactName: o.artifactName, artifactVersion: o.artifactVersion, fileSize: o.fileSize,
        sha256: o.sha256, summary: miDeploymentSummary(targets)};
    if detail { payload["targets"] = targets; }
    return payload;
}

public isolated function getMIDeploymentOperation(string deploymentId) returns json?|error {
    types:MIDeploymentOperation? operation = check loadMIDeploymentOperation(deploymentId);
    if operation is () { return (); }
    return miDeploymentPayload(operation, check loadMIDeploymentTargets(deploymentId));
}

public isolated function listMIDeploymentOperations(string? orgHandler, int pageLimit = 10, int pageOffset = 0) returns record {| json[] items; int total; |}|error {
    if orgHandler is () { return error("Organization is required"); }
    record {|int total;|} count = check dbClient->queryRow(`SELECT COUNT(*) AS total FROM mi_deployment_operations WHERE org_handler=${orgHandler}`);
    stream<record {|string deployment_id;|}, sql:Error?> rows = dbClient->query(miPage(`SELECT deployment_id FROM mi_deployment_operations
        WHERE org_handler=${orgHandler} ORDER BY created_at DESC, deployment_id DESC`, pageLimit, pageOffset));
    record {|string deployment_id;|}[] data = check from var row in rows select row;
    json[] items = [];
    foreach var row in data {
        types:MIDeploymentOperation? operation = check loadMIDeploymentOperation(row.deployment_id);
        if operation is types:MIDeploymentOperation { items.push(miDeploymentPayload(operation, check loadMIDeploymentTargets(row.deployment_id), false)); }
    }
    return {items, total: count.total};
}

public isolated function loadMIDeploymentMemory(string deploymentId) returns record {| types:MIDeploymentOperation operation; byte[] content; |}|error {
    types:MIDeploymentOperation? operation = check loadMIDeploymentOperation(deploymentId);
    if operation is () { return error("Deployment not found"); }
    record {|byte[] content;|} row = check dbClient->queryRow(`SELECT content FROM mi_deployment_artifacts WHERE artifact_id=${operation.artifactId}`);
    return {operation, content: row.content};
}

public isolated function listMIDeploymentEvents(string deploymentId, string? targetId = (), int pageLimit = 25, int pageOffset = 0) returns record {| json[] items; int total; |}|error {
    sql:ParameterizedQuery condition = targetId is string ? ` WHERE deployment_id=${deploymentId} AND target_id=${targetId}` : ` WHERE deployment_id=${deploymentId}`;
    record {|int total;|} count = check dbClient->queryRow(sql:queryConcat(`SELECT COUNT(*) AS total FROM mi_deployment_events`, condition));
    stream<record {|string event_id; string deployment_id; string? target_id; string phase; string message; string created_at; string? reason; int? http_status; string? evidence;|}, sql:Error?> rows = dbClient->query(miPage(sql:queryConcat(
        `SELECT event_id, deployment_id, target_id, phase, message, created_at, reason, http_status, evidence FROM mi_deployment_events`, condition, ` ORDER BY created_at, event_id`), pageLimit, pageOffset));
    json[] items = [];
    check from var row in rows do {
        json evidence = row.evidence is string ? check (<string>row.evidence).fromJsonString() : [];
        items.push({eventId: row.event_id, deploymentId: row.deployment_id, targetId: row.target_id, phase: row.phase,
            message: row.message, createdAt: row.created_at, reason: row.reason, httpStatus: row.http_status, evidence});
    };
    return {items, total: count.total};
}

// Marks only the selected operation; no runtime mutation is replayed.
public isolated function interruptMIDeployment(string deploymentId, string message) returns error? {
    types:MIDeploymentOperation? operation = check loadMIDeploymentOperation(deploymentId);
    if operation is () || (operation.status != types:RUNNING && operation.status != types:CANCELLING) { return; }
    types:MIDeploymentTarget[] targets = check loadMIDeploymentTargets(deploymentId);
    transaction {
        foreach var target in targets {
            if !miDeploymentTerminal(target.phase) {
                target.phase = types:INDETERMINATE;
                target.reason = "EXECUTION_INTERRUPTED"; target.message = message;
                // The actual end time is unknown; do not invent a duration.
                target.updatedAt = miDeploymentNow();
                check updateMIDeploymentTarget(target);
                check persistMIDeploymentEvent(uuid:createType4AsString(), target.deploymentId, target.targetId, "INDETERMINATE", message, target.reason);
            }
        }
        operation.status = types:COMPLETED_WITH_ISSUES;
        check updateMIDeploymentOperation(operation);
        check persistMIDeploymentEvent(uuid:createType4AsString(), operation.deploymentId, (), operation.status.toString(), message);
        check commit;
    }
}

// Run once at startup, never periodically against live workers.
public isolated function recoverMIDeploymentLeases() returns error? {
    stream<record {|string deployment_id;|}, sql:Error?> rows = dbClient->query(`SELECT deployment_id FROM mi_deployment_operations WHERE status IN ('RUNNING','CANCELLING')`);
    record {|string deployment_id;|}[] data = check from var row in rows select row;
    foreach var row in data {
        check interruptMIDeployment(row.deployment_id, "Execution interrupted by server restart; explicit runtime recheck required");
    }
}

public isolated function deleteMIDeployment(string deploymentId) returns error? {
    transaction {
        types:MIDeploymentOperation? operation = check loadMIDeploymentOperation(deploymentId);
        if operation is () { fail error("Deployment not found"); }
        sql:ExecutionResult _ = check dbClient->execute(`UPDATE mi_deployment_artifacts SET artifact_id=artifact_id WHERE artifact_id=${operation.artifactId}`);
        sql:ExecutionResult deleted = check dbClient->execute(`DELETE FROM mi_deployment_operations WHERE deployment_id=${deploymentId} AND status NOT IN ('RUNNING','CANCELLING')`);
        if deleted.affectedRowCount != 1 { fail error("An active deployment cannot be deleted"); }
        sql:ExecutionResult _ = check dbClient->execute(`DELETE FROM mi_deployment_artifacts WHERE artifact_id=${operation.artifactId}
            AND NOT EXISTS (SELECT 1 FROM mi_deployment_operations WHERE artifact_id=${operation.artifactId})`);
        check commit;
    }
}

public isolated function cleanupMIDeploymentData() returns error? {
    // Retain metadata and content referenced by history or retries. History has no automatic expiration.
    sql:ExecutionResult _ = check dbClient->execute(`DELETE FROM mi_deployment_artifacts WHERE expires_at < CURRENT_TIMESTAMP
        AND NOT EXISTS (SELECT 1 FROM mi_deployment_operations o WHERE o.artifact_id=mi_deployment_artifacts.artifact_id)`);
}

public isolated function beginMIDeployment(types:MIDeploymentOperation operation) returns error? {
    transaction {
        sql:ExecutionResult guard = check dbClient->execute(`UPDATE mi_deployment_operations SET status='RUNNING'
            WHERE deployment_id=${operation.deploymentId} AND status='READY'`);
        if guard.affectedRowCount != 1 { fail error("Deployment already started or no longer ready"); }
        check updateMIDeploymentOperation(operation);
        check persistMIDeploymentEvent(uuid:createType4AsString(), operation.deploymentId, (), "RUNNING", "Deployment execution started");
        check commit;
    }
}

public isolated function claimMIDeploymentTarget(types:MIDeploymentTarget target) returns boolean|error {
    boolean claimed = false;
    transaction {
        sql:ExecutionResult guard = check dbClient->execute(`UPDATE mi_deployment_targets SET phase='VALIDATING'
            WHERE target_id=${target.targetId} AND deployment_id=${target.deploymentId} AND phase='QUEUED'`);
        if guard.affectedRowCount == 1 {
            check updateMIDeploymentTarget(target);
            check persistMIDeploymentEvent(uuid:createType4AsString(), target.deploymentId, target.targetId, "VALIDATING", "Execution attempt started");
            claimed = true;
        }
        check commit;
    }
    return claimed;
}

public isolated function saveMIDeploymentDecisions(types:MIDeploymentOperation operation, types:MIDeploymentTarget[] targets) returns error? {
    transaction {
        sql:ExecutionResult guard = check dbClient->execute(`UPDATE mi_deployment_operations SET version=version+1
            WHERE deployment_id=${operation.deploymentId} AND status IN ('AWAITING_DECISIONS','READY') AND started_at IS NULL`);
        if guard.affectedRowCount != 1 { fail error("Deployment is no longer editable"); }
        foreach var target in targets {
            check updateMIDeploymentTarget(target);
            check persistMIDeploymentEvent(uuid:createType4AsString(), target.deploymentId, target.targetId, target.phase.toString(),
                target.deleteBeforeUpload ? "Replace existing application approved" : "Preserve existing application");
        }
        check updateMIDeploymentOperation(operation);
        check commit;
    }
}

public isolated function cancelMIDeploymentTargets(types:MIDeploymentOperation operation, string? targetId) returns error? {
    transaction {
        // Lock the operation before examining targets, serializing cancellation with execute/preflight.
        sql:ExecutionResult guard = check dbClient->execute(`UPDATE mi_deployment_operations SET version=version+1
            WHERE deployment_id=${operation.deploymentId} AND status IN ('DRAFT','PREFLIGHT','AWAITING_DECISIONS','READY','RUNNING','CANCELLING')`);
        if guard.affectedRowCount != 1 { fail error("Deployment cannot be cancelled"); }
        types:MIDeploymentTarget[] targets = check loadMIDeploymentTargets(operation.deploymentId);
        boolean changed = false;
        foreach var target in targets {
            if targetId is () || target.targetId == targetId {
                sql:ExecutionResult cancelled = check dbClient->execute(`UPDATE mi_deployment_targets SET phase='CANCELLED'
                    WHERE target_id=${target.targetId} AND phase='QUEUED'`);
                if cancelled.affectedRowCount == 1 {
                    target.phase = types:CANCELLED; target.message = "Cancelled before execution"; target.updatedAt = miDeploymentNow();
                    check updateMIDeploymentTarget(target);
                    check persistMIDeploymentEvent(uuid:createType4AsString(), target.deploymentId, target.targetId, "CANCELLED", "Cancelled before execution");
                    changed = true;
                }
            }
        }
        if targetId is string && !changed { fail error("Target is not queued or was not found"); }
        targets = check loadMIDeploymentTargets(operation.deploymentId);
        types:MIDeploymentOperation? fresh = check loadMIDeploymentOperation(operation.deploymentId);
        if fresh is () { fail error("Deployment not found"); }
        if targetId is () {
            fresh.status = targets.some(t => !miDeploymentTerminal(t.phase)) ? types:CANCELLING : types:CANCELLED;
            if fresh.status == types:CANCELLED && fresh.startedAt is string {
                fresh.finishedAt = miDeploymentNow(); fresh.durationMs = miDeploymentDuration(fresh.startedAt, <string>fresh.finishedAt);
            }
            check updateMIDeploymentOperation(fresh);
        }
        check persistMIDeploymentEvent(uuid:createType4AsString(), operation.deploymentId, (), fresh.status.toString(), "Cancellation requested; in-flight runtime requests are allowed to finish");
        check commit;
    }
}
