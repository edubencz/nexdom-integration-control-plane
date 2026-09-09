// Durable-operation HTTP contract for organization-wide MI CAR deployments.
// The repository-backed worker is deliberately kept behind this service boundary so
// deployments can be resumed and observed without coupling the browser to MI hosts.
import icp_server.auth;
import icp_server.storage;
import icp_server.types;
import ballerina/http;
import ballerina/mime;
import ballerina/time;
import ballerina/uuid;
import ballerina/url;
import ballerina/crypto;
import ballerina/log;
import ballerina/lang.runtime;
import ballerina/io;
import ballerina/file;
import ballerina/zip;

type DeploymentMemory record {| 
    types:MIDeploymentOperation operation;
    types:MIDeploymentTarget[] targets;
    byte[] content;
|};

map<string> deploymentIdempotency = {};

function deploymentError(int status, string message) returns http:Response {
    http:Response response = new;
    response.statusCode = status;
    response.setJsonPayload({"error": {"message": message}});
    return response;
}

function now() returns string => time:utcToString(time:utcNow());

function transitionAllowed(types:MIDeploymentStatus status, string action) returns boolean {
    if action == "preflight" { return status == types:DRAFT || status == types:AWAITING_DECISIONS || status == types:READY; }
    if action == "decisions" { return status == types:AWAITING_DECISIONS || status == types:READY; }
    if action == "execute" { return status == types:READY; }
    if action == "cancel" { return status == types:DRAFT || status == types:PREFLIGHT || status == types:AWAITING_DECISIONS || status == types:READY || status == types:RUNNING || status == types:CANCELLING; }
    if action == "recheck" { return status == types:COMPLETED || status == types:COMPLETED_WITH_ISSUES || status == types:FAILED; }
    return true;
}

function responseFor(DeploymentMemory memory) returns http:Response {
    http:Response response = new;
    response.setJsonPayload(storage:miDeploymentPayload(memory.operation, memory.targets));
    return response;
}

function hydrateDeployment(string deploymentId) returns DeploymentMemory|error {
    var loaded = check storage:loadMIDeploymentMemory(deploymentId);
    return {operation: loaded.operation, targets: check storage:loadMIDeploymentTargets(deploymentId), content: loaded.content};
}

function deploymentAccess(types:UserContextV2 context, http:Request request, string? deploymentId = (), boolean manage = true) returns http:Response? {
    string? org = request.getQueryParamValue("orgHandler");
    int orgId;
    if deploymentId is string {
        types:MIDeploymentOperation?|error found = storage:loadMIDeploymentOperation(deploymentId);
        if found is error { return deploymentError(503, "Unable to read deployment storage"); }
        if found is () { return deploymentError(404, "Deployment not found"); }
        if org is string && org != found.orgHandler { return deploymentError(404, "Deployment not found in this organization"); }
        orgId = found.orgId;
    } else {
        if org is () || org.trim() == "" { return deploymentError(400, "orgHandler is required"); }
        int|error resolved = storage:getOrgIdByHandle(org);
        if resolved is error { return deploymentError(404, "Organization not found"); }
        orgId = resolved;
    }
    boolean|error allowed = auth:hasAnyPermission(context.userId,
        manage ? [auth:PERMISSION_DEPLOYMENT_MANAGE] : [auth:PERMISSION_DEPLOYMENT_VIEW, auth:PERMISSION_DEPLOYMENT_MANAGE], {orgUuid: orgId});
    if allowed is error { return deploymentError(503, "Unable to verify deployment permission"); }
    return allowed ? () : deploymentError(403, manage ? "Deployment manage permission required" : "Deployment view permission required");
}

function callerContext(http:Request request) returns types:UserContextV2|http:Response {
    string|http:HeaderNotFoundError header = request.getHeader("Authorization");
    if header is http:HeaderNotFoundError { return deploymentError(401, "Authorization header missing"); }
    types:UserContextV2|error context = auth:extractUserContextV2(header);
    if context is error { return deploymentError(401, "Invalid token"); }
    return context;
}

function fileFromRequest(http:Request request) returns [string, byte[]]|http:Response|error {
    mime:Entity[] parts = check request.getBodyParts();
    foreach mime:Entity part in parts {
        mime:ContentDisposition disposition = part.getContentDisposition();
        if disposition.name == "file" || disposition.fileName != "" {
            string fileName = disposition.fileName;
            byte[] content = check part.getByteArray();
            if !fileName.toLowerAscii().endsWith(".car") { return deploymentError(400, "Only .CAR files are accepted"); }
            if content.length() == 0 || content.length() > miDeploymentMaxCarSizeBytes { return deploymentError(413, "CAR exceeds the configured 100 MB limit"); }
            if content.length() < 4 || content[0] != 0x50 || content[1] != 0x4B || content[2] != 0x03 || content[3] != 0x04 {
                return deploymentError(400, "CAR is not a valid ZIP container");
            }
            return [fileName, content];
        }
    }
    return deploymentError(400, "Multipart field 'file' is required");
}

function carMetadata(byte[] content) returns [string, string]? {
    string|error tempPath = file:createTemp(".car", "icp-mi-", ());
    if tempPath is error { return (); }
    string tempFile = tempPath;
    error? writeResult = io:fileWriteBytes(tempFile, content);
    if writeResult is error { error? cleanup = file:remove(tempFile); return (); }
    zip:ArchiveReader|error archiveResult = new (tempFile);
    if archiveResult is error { error? cleanup = file:remove(tempFile); return (); }
    zip:ArchiveReader archive = archiveResult;
    byte[]|zip:Error metadataResult = archive.readEntry("artifacts.xml");
    error? closeResult = archive.close();
    error? removeResult = file:remove(tempFile);
    if metadataResult is zip:Error { return (); }
    string|error metadataResultText = string:fromBytes(metadataResult);
    if metadataResultText is error { return (); }
    string metadata = metadataResultText;
    string artifactPrefix = "<artifact name=\"";
    int? artifactStart = metadata.indexOf(artifactPrefix);
    if artifactStart is () { return (); }
    int nameStart = artifactStart + artifactPrefix.length();
    string nameAndVersion = metadata.substring(nameStart);
    int? nameEnd = nameAndVersion.indexOf("\"");
    if nameEnd is () || nameEnd < 1 { return (); }
    string artifactName = nameAndVersion.substring(0, nameEnd);
    int? versionMarker = nameAndVersion.indexOf("version=\"");
    if versionMarker is () { return (); }
    int versionStart = versionMarker + "version=\"".length();
    string versionText = nameAndVersion.substring(versionStart);
    int? versionEnd = versionText.indexOf("\"");
    if versionEnd is () || versionEnd < 1 { return (); }
    return [artifactName, versionText.substring(0, versionEnd)];
}

function operationPayload(string orgHandler, string fileName, byte[] content, string userId) returns DeploymentMemory {
    string stem = fileName.substring(0, fileName.length() - 4);
    string artifactName = stem;
    string version = "unknown";
    int? separator = stem.lastIndexOf("_");
    if separator is int && separator > 0 {
        artifactName = stem.substring(0, separator);
        version = stem.substring(separator + 1);
    }
    [string, string]? metadata = carMetadata(content);
    if metadata is [string, string] {
        artifactName = metadata[0];
        version = metadata[1];
    }
    string id = uuid:createType4AsString();
    string timestamp = now();
    types:MIDeploymentOperation operation = {
        deploymentId: id, orgId: storage:DEFAULT_ORG_ID, orgHandler,
        artifactId: uuid:createType4AsString(), artifactName, artifactVersion: version,
        fileName, fileSize: content.length(), sha256: crypto:hashSha256(content).toBase16(),
        status: types:DRAFT, createdBy: userId, createdAt: timestamp, updatedAt: timestamp
    };
    return {operation, targets: [], content};
}

// Query the authoritative MI application state. The API exposes activeList and
// faultyList; unknown/missing fields are intentionally ignored for compatibility.
function applicationState(http:Client mgmt, string token, string name, string version) returns string|error {
    http:Response response = check mgmt->get("/management/applications", {"Authorization": "Bearer " + token, "Accept": "application/json"});
    if response.statusCode < 200 || response.statusCode >= 300 { return error(string `GET applications returned HTTP ${response.statusCode}`, httpStatus = response.statusCode); }
    json payload = check response.getJsonPayload();
    if payload is map<json> {
        foreach string listKey in ["activeList", "faultyList"] {
            json? list = payload[listKey];
            if list is json[] {
                foreach json item in list {
                    if item is map<json> {
                        string itemName = item["name"] is string ? <string>item["name"] : "";
                        string itemVersion = item["version"] is string ? <string>item["version"] : "";
                        boolean sameIdentity = itemName == name && (itemVersion == version || version == "unknown");
                        // Older CARs may not expose metadata to ICP. In that case
                        // MI commonly reports the base application name plus a
                        // separate version, while the filename contains both.
                        boolean filenameIdentity = version == "unknown" && itemName != "" && name.startsWith(itemName + "-");
                        if sameIdentity || filenameIdentity { return listKey == "activeList" ? "active" : "faulty"; }
                    }
                }
            }
        }
    }
    return "missing";
}

function probeRuntimeConflict(types:Runtime runtime, string artifactName, string artifactVersion) returns boolean|error {
    string baseUrl = check storage:buildManagementBaseUrl(runtime.managementHostname, runtime.managementPort);
    http:Client|error clientResult = artifactsApiAllowInsecureTLS ? new (baseUrl, {secureSocket: {enable: false}}) : new (baseUrl);
    if clientResult is error { return clientResult; }
    string token = check storage:issueRuntimeHmacToken(runtime.runtimeId);
    string|error state = applicationState(clientResult, token, artifactName, artifactVersion);
    if state is error { return state; }
    return state == "active" || state == "faulty";
}

function persistTargetState(string deploymentId, int targetIndex, types:MIDeploymentTarget target) returns error? {
    target.updatedAt = now();
    error? persisted = storage:saveMIDeploymentTarget(target);
    if persisted is error { return error("Deployment persistence failed", persisted); }
}

function uploadTarget(DeploymentMemory memory, types:MIDeploymentTarget target, string deploymentId, int targetIndex) returns [types:MIDeploymentTarget, string]|error {
    types:Runtime?|error runtimeResult = storage:getRuntimeById(target.runtimeId);
    if runtimeResult is error { return error("Unable to resolve runtime"); }
    if runtimeResult is () || runtimeResult.runtimeType != types:MI || runtimeResult.status != "RUNNING" {
        target.phase = types:SKIPPED_INELIGIBLE; target.reason = "Runtime is not running"; return [target, "Runtime is not running"];
    }
    string baseUrl = check storage:buildManagementBaseUrl(runtimeResult.managementHostname, runtimeResult.managementPort);
    http:Client|error clientResult = new (baseUrl, artifactsApiAllowInsecureTLS ? {secureSocket: {enable: false}} : {});
    if clientResult is error { return clientResult; }
    http:Client mgmtClient = clientResult;
    string token = check storage:issueRuntimeHmacToken(target.runtimeId);
    string|error existing = applicationState(mgmtClient, token, memory.operation.artifactName, memory.operation.artifactVersion);
    if existing is error { target.httpStatus = runtimeErrorStatus(existing); target.phase = types:INDETERMINATE; target.message = existing.message(); return [target, "Preflight verification failed"]; }
    if (existing == "active" || existing == "faulty") && !target.deleteBeforeUpload {
        target.phase = types:SKIPPED_CONFLICT; target.reason = "Exact name/version already exists";
        return [target, "Conflict skipped"];
    }
    if target.deleteBeforeUpload {
        target.phase = types:DELETING;
        target.message = "Removing existing Carbon Application";
        check persistTargetState(deploymentId, targetIndex, target);
        // MI identifies Carbon Applications as <artifact name>-<version>. When
        // the CAR does not expose a version, artifactName already contains the
        // complete runtime application name and must be used as-is.
        string applicationName = memory.operation.artifactVersion == "unknown"
            ? memory.operation.artifactName
            : memory.operation.artifactName + "-" + memory.operation.artifactVersion;
        string encodedName = check url:encode(applicationName, "UTF-8");
        // Ballerina's DELETE client method receives headers as its third
        // argument. Passing them in the second argument does not authenticate
        // the outbound request and causes the runtime to return HTTP 401.
        http:Response|error deleted = mgmtClient->delete("/management/applications/" + encodedName, (), {
            "Authorization": "Bearer " + token,
            "Accept": "application/json"
        });
        if deleted is error {
            target.phase = types:FAILED; target.message = string `Unable to remove the existing Carbon Application: ${deleted.message()}`; return [target, "DELETE failed"];
        }
        target.httpStatus = deleted.statusCode;
        if deleted.statusCode < 200 || deleted.statusCode >= 300 {
            target.phase = types:FAILED; target.reason = "DELETE_FAILED"; target.message = string `Unable to remove the existing Carbon Application (HTTP ${deleted.statusCode})`; return [target, "DELETE failed"];
        }
        // A successful DELETE is the authoritative removal result. The
        // applications listing may remain stale briefly after deletion, so an
        // immediate GET must not prevent the subsequent CAR upload.
        target.phase = types:VERIFYING_DELETE;
        check persistTargetState(deploymentId, targetIndex, target);
    }
    target.phase = types:UPLOADING; target.message = "Uploading Carbon Application";
    check persistTargetState(deploymentId, targetIndex, target);
    mime:Entity part = new;
    part.setByteArray(memory.content, "application/octet-stream");
    part.setContentDisposition(mime:getContentDispositionObject(string `form-data; name=file; filename=${memory.operation.fileName}`));
    http:Request outbound = new;
    outbound.method = http:POST;
    outbound.setBodyParts([part]);
    outbound.setHeader("Authorization", "Bearer " + token);
    outbound.setHeader("Accept", "application/json");
    http:Response|error uploaded = mgmtClient->post("/management/applications", outbound);
    if uploaded is http:Response { target.httpStatus = uploaded.statusCode; }
    if uploaded is error || uploaded.statusCode < 200 || uploaded.statusCode >= 300 {
        target.phase = types:FAILED; target.reason = "UPLOAD_FAILED"; target.message = uploaded is error ? uploaded.message() : string `POST returned HTTP ${uploaded.statusCode}`; return [target, "POST failed"];
    }
    target.phase = types:VERIFYING_DEPLOY; target.message = "Upload accepted; verifying runtime application";
    check persistTargetState(deploymentId, targetIndex, target);
    int remaining = miDeploymentVerifyAttempts;
    while remaining > 0 {
        string|error state = applicationState(mgmtClient, token, memory.operation.artifactName, memory.operation.artifactVersion);
        if state == "active" { target.reason = (); target.phase = types:SUCCEEDED; target.message = "Runtime confirmed active"; return [target, "Succeeded"]; }
        if state == "faulty" { target.reason = "RUNTIME_FAULTY"; target.phase = types:FAULTY; target.message = "Runtime reported faulty application"; return [target, "Faulty"]; }
        if state is error { target.httpStatus = runtimeErrorStatus(state); target.phase = types:INDETERMINATE; target.message = state.message(); return [target, "Verification unavailable"]; }
        remaining -= 1;
        if remaining > 0 {
            // Do not exhaust all verification attempts in a tight loop. MI may
            // need several seconds to finish deploying the uploaded CAR.
            runtime:sleep(<decimal>miDeploymentVerifyIntervalSeconds);
        }
    }
    target.phase = types:INDETERMINATE; target.reason = "VERIFICATION_TIMEOUT"; target.message = "Upload accepted but runtime confirmation timed out";
    return [target, "Indeterminate"];
}

function recheckTarget(DeploymentMemory memory, types:MIDeploymentTarget target) returns types:MIDeploymentTarget {
    target.httpStatus = ();
    types:Runtime?|error runtimeResult = storage:getRuntimeById(target.runtimeId);
    if runtimeResult is error || runtimeResult is () { target.phase = types:INDETERMINATE; target.message = "Runtime unavailable during recheck"; return target; }
    string|error base = storage:buildManagementBaseUrl(runtimeResult.managementHostname, runtimeResult.managementPort);
    if base is error { target.phase = types:INDETERMINATE; target.message = base.message(); return target; }
    http:Client|error mgmt = artifactsApiAllowInsecureTLS ? new (base, {secureSocket: {enable: false}}) : new (base);
    if mgmt is error { target.phase = types:INDETERMINATE; target.message = mgmt.message(); return target; }
    string|error token = storage:issueRuntimeHmacToken(target.runtimeId);
    if token is error { target.phase = types:INDETERMINATE; target.message = token.message(); return target; }
    string|error state = applicationState(mgmt, token, memory.operation.artifactName, memory.operation.artifactVersion);
    if state == "active" { target.reason = (); target.phase = types:SUCCEEDED; target.message = "Runtime confirmed active"; }
    else if state == "faulty" { target.reason = "RUNTIME_FAULTY"; target.phase = types:FAULTY; target.message = "Runtime reported faulty application"; }
    else if state is error { target.httpStatus = runtimeErrorStatus(state); target.phase = types:INDETERMINATE; target.message = state.message(); }
    else { target.phase = types:INDETERMINATE; target.message = "Application not present"; }
    return target;
}

map<string> deploymentWorkerErrors = {};

function executeDeployment(string deploymentId) {
    do {
        DeploymentMemory memory = check hydrateDeployment(deploymentId);
        if memory.operation.status != types:RUNNING && memory.operation.status != types:CANCELLING { return; }
        foreach int index in 0 ..< memory.targets.length() {
            types:MIDeploymentTarget[] fresh = check storage:loadMIDeploymentTargets(deploymentId);
            types:MIDeploymentTarget target = fresh[index];
            if !target.eligible || target.phase != types:QUEUED { continue; }
            target.phase = types:VALIDATING;
            target.reason = ();
            target.message = "Validating runtime before deployment";
            target.startedAt = now();
            target.attempt += 1;
            boolean claimed = check storage:claimMIDeploymentTarget(target);
            if !claimed { continue; }
            [types:MIDeploymentTarget, string]|error result = uploadTarget(memory, target, deploymentId, index);
            if result is error {
                // A failed persistence boundary must stop the worker, not become a successful in-memory result.
                if result.message() == "Deployment persistence failed" { fail result; }
                target.phase = types:FAILED; target.reason = "EXECUTION_FAILED"; target.message = result.message();
            } else { target = result[0]; }
            target.finishedAt = now();
            target.durationMs = storage:miDeploymentDuration(target.startedAt, <string>target.finishedAt);
            check persistTargetState(deploymentId, index, target);
        }
        DeploymentMemory finished = check hydrateDeployment(deploymentId);
        finished.operation.status = storage:miDeploymentStatus(finished.targets);
        finished.operation.finishedAt = now();
        finished.operation.durationMs = storage:miDeploymentDuration(finished.operation.startedAt, <string>finished.operation.finishedAt);
        finished.operation.updatedAt = now();
        check storage:saveMIDeploymentOperation(finished.operation, "Deployment execution finished");
    } on fail error e {
        lock { deploymentWorkerErrors[deploymentId] = "Execution stopped because deployment storage could not be updated. Runtime state must be rechecked."; }
        error? recorded = storage:interruptMIDeployment(deploymentId, "Execution stopped after a persistence error; runtime recheck required");
        if recorded is error { log:printError("Unable to persist interrupted deployment", recorded); }
        log:printError("Deployment worker stopped", e, deploymentId = deploymentId);
    }
}

@http:ServiceConfig {
    auth: [{jwtValidatorConfig: {issuer: frontendJwtIssuer, audience: frontendJwtAudience,
        signatureConfig: {secret: resolvedFrontendJwtHMACSecret}}}],
    cors: {allowOrigins: normalizedCorsAllowedOrigins,
        allowHeaders: ["Content-Type", "Authorization", "Idempotency-Key"]}
}
service /icp/mi_deployments on httpListener {
    resource function post .(http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        http:Response? denied = deploymentAccess(contextResult, request);
        if denied is http:Response { check caller->respond(denied); return; }
        [string, byte[]]|http:Response|error fileResult = fileFromRequest(request);
        if fileResult is error { check caller->respond(deploymentError(400, fileResult.message())); return; }
        if fileResult is http:Response { check caller->respond(fileResult); return; }
        string? orgHandler = request.getQueryParamValue("orgHandler");
        if orgHandler is () || orgHandler.trim() == "" { check caller->respond(deploymentError(400, "orgHandler is required")); return; }
        string org = orgHandler is string ? orgHandler : "";
        string|http:HeaderNotFoundError idempotencyHeader = request.getHeader("Idempotency-Key");
        if idempotencyHeader is string && deploymentIdempotency.hasKey(contextResult.userId + ":" + org + ":" + idempotencyHeader) {
            string? existingId = deploymentIdempotency[contextResult.userId + ":" + org + ":" + idempotencyHeader];
            if existingId is string {
                DeploymentMemory|error existing = hydrateDeployment(existingId);
                if existing is DeploymentMemory { check caller->respond(responseFor(existing)); return; }
            }
        }
        DeploymentMemory memory = operationPayload(org, fileResult[0], fileResult[1], contextResult.userId);
        memory.operation.orgId = check storage:getOrgIdByHandle(org);
        error? persisted = storage:persistMIDeployment(memory.operation, memory.content);
        if persisted is error { check caller->respond(deploymentError(503, "Unable to persist deployment artifact: " + persisted.message())); return; }
        if idempotencyHeader is string && idempotencyHeader.trim() != "" { deploymentIdempotency[contextResult.userId + ":" + org + ":" + idempotencyHeader] = memory.operation.deploymentId; }
        auditRestMutation(storage:AUDIT_MI_DEPLOYMENT_CREATE, contextResult.userId, contextResult.username, request, storage:AUDIT_RESOURCE_MI_DEPLOYMENT, memory.operation.deploymentId, string `artifact=${memory.operation.sha256}; org=${org}`, "SUCCESS");
        check caller->respond(responseFor(memory));
    }

    resource function get .(http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        http:Response? denied = deploymentAccess(contextResult, request, (), false);
        if denied is http:Response { check caller->respond(denied); return; }
        var result = storage:listMIDeploymentOperations(request.getQueryParamValue("orgHandler"), pageParameter(request, "limit", 10), pageParameter(request, "offset", 0));
        if result is error { check caller->respond(deploymentError(503, "Unable to load deployment history")); return; }
        check caller->respond(result);
    }

    resource function get [string deploymentId](http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        http:Response? denied = deploymentAccess(contextResult, request, deploymentId, false);
        if denied is http:Response { check caller->respond(denied); return; }
        string? workerError;
        lock { workerError = deploymentWorkerErrors[deploymentId]; }
        json?|error result = storage:getMIDeploymentOperation(deploymentId);
        if result is error { check caller->respond(deploymentError(503, "Unable to load deployment details")); return; }
        if result is () { check caller->respond(deploymentError(404, "Deployment not found")); return; }
        if result is map<json> && workerError is string { result["executionError"] = workerError; }
        check caller->respond(result);
    }

    resource function get [string deploymentId]/events(http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        http:Response? denied = deploymentAccess(contextResult, request, deploymentId, false);
        if denied is http:Response { check caller->respond(denied); return; }
        var result = storage:listMIDeploymentEvents(deploymentId, request.getQueryParamValue("targetId"), pageParameter(request, "limit", 25), pageParameter(request, "offset", 0));
        if result is error { check caller->respond(deploymentError(503, "Unable to load deployment events")); return; }
        check caller->respond(result);
    }

    resource function delete [string deploymentId](http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        http:Response? denied = deploymentAccess(contextResult, request, deploymentId, true);
        if denied is http:Response { check caller->respond(denied); return; }
        error? deleted = storage:deleteMIDeployment(deploymentId);
        if deleted is error { check caller->respond(deploymentError(409, deleted.message())); return; }
        check caller->respond({deleted: true});
    }

    resource function post [string deploymentId]/preflight(http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        http:Response? denied = deploymentAccess(contextResult, request, deploymentId, true);
        if denied is http:Response { check caller->respond(denied); return; }
        DeploymentMemory|error loaded = hydrateDeployment(deploymentId);
        if loaded is error { check caller->respond(deploymentError(503, "Unable to load deployment details")); return; }
        DeploymentMemory memory = loaded;
        if !transitionAllowed(memory.operation.status, "preflight") { check caller->respond(deploymentError(409, "Deployment preparation is no longer editable")); return; }
        json|error payload = request.getJsonPayload();
        if payload is error || payload !is map<json> || payload["projectIds"] !is json[] { check caller->respond(deploymentError(400, "projectIds must be an array")); return; }
        string[]|error projectIds = (<json>payload["projectIds"]).cloneWithType();
        if projectIds is error { check caller->respond(deploymentError(400, "projectIds must contain strings")); return; }
        if projectIds.length() == 0 { check caller->respond(deploymentError(400, "Select at least one project")); return; }
        memory.targets = [];
        memory.operation.selectedProjectIds = [];
        foreach string projectId in projectIds {
            if memory.operation.selectedProjectIds.indexOf(projectId) >= 0 { continue; }
            types:Project|error project = storage:getProjectById(projectId);
            if project is error { check caller->respond(deploymentError(400, "Selected project not found")); return; }
            if project.orgId != memory.operation.orgId { check caller->respond(deploymentError(403, "Project does not belong to deployment organization")); return; }
            memory.operation.selectedProjectIds.push(projectId);
            types:Runtime[]|error runtimes = storage:getRuntimes((), "MI", (), projectId, ());
            if runtimes is error { check caller->respond(deploymentError(503, "Unable to resolve project runtimes")); return; }
            foreach types:Runtime runtime in runtimes {
                boolean eligible = runtime.status == "RUNNING" && runtime.managementHostname is string && runtime.managementPort is string;
                boolean hasConflict = false;
                string? reason = eligible ? () : "Runtime is not running or has no management endpoint";
                if eligible {
                    boolean|error probe = probeRuntimeConflict(runtime, memory.operation.artifactName, memory.operation.artifactVersion);
                    if probe is error { eligible = false; reason = "Unable to query Management API: " + probe.message(); }
                    else { hasConflict = probe; }
                }
                memory.targets.push({targetId: uuid:createType4AsString(), deploymentId, projectId, projectName: project.name,
                    componentId: runtime.component.id, componentName: runtime.component.displayName, environmentId: runtime.environment.id,
                    environmentName: runtime.environment.name, runtimeId: runtime.runtimeId, runtimeName: runtime?.runtimeName ?: runtime.runtimeId,
                    production: runtime.environment.name.toLowerAscii().indexOf("prod") >= 0, eligible, conflictDetected: hasConflict, deleteBeforeUpload: false,
                    phase: eligible ? types:QUEUED : types:SKIPPED_INELIGIBLE, attempt: 0, reason: reason ?: (hasConflict ? "Exact name/version already exists" : "No exact conflict found"), updatedAt: now()});
            }
        }
        memory.operation.status = types:AWAITING_DECISIONS;
        memory.operation.updatedAt = now();
        error? saved = storage:replaceMIDeploymentTargets(memory.operation, memory.targets);
        if saved is error { check caller->respond(deploymentError(503, "Unable to save preflight snapshot")); return; }
        auditRestMutation(storage:AUDIT_MI_DEPLOYMENT_PREFLIGHT, contextResult.userId, contextResult.username, request, storage:AUDIT_RESOURCE_MI_DEPLOYMENT, deploymentId, string `targets=${memory.targets.length()}`, "SUCCESS");
        check caller->respond(responseFor(memory));
    }

    resource function patch [string deploymentId]/targets(http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        http:Response? denied = deploymentAccess(contextResult, request, deploymentId, true);
        if denied is http:Response { check caller->respond(denied); return; }
        DeploymentMemory|error loaded = hydrateDeployment(deploymentId);
        if loaded is error { check caller->respond(deploymentError(503, "Unable to load deployment details")); return; }
        DeploymentMemory memory = loaded;
        if !transitionAllowed(memory.operation.status, "decisions") { check caller->respond(deploymentError(409, "Conflict decisions are no longer editable")); return; }
        json|error payload = request.getJsonPayload();
        if payload is error || payload !is map<json> || payload["decisions"] !is json[] { check caller->respond(deploymentError(400, "decisions must be an array")); return; }
        foreach json item in <json[]>payload["decisions"] {
            if item !is map<json> || item["targetId"] !is string || item["deleteBeforeUpload"] !is boolean { check caller->respond(deploymentError(400, "Invalid target decision")); return; }
            boolean matched = false;
            foreach var target in memory.targets {
                if target.targetId == item["targetId"] { target.deleteBeforeUpload = <boolean>item["deleteBeforeUpload"]; matched = true; }
            }
            if !matched { check caller->respond(deploymentError(400, "Unknown target")); return; }
        }
        memory.operation.status = types:READY;
        error? saved = storage:saveMIDeploymentDecisions(memory.operation, memory.targets);
        if saved is error { check caller->respond(deploymentError(503, "Unable to save deployment decisions")); return; }
        check caller->respond(responseFor(memory));
    }

    resource function post [string deploymentId]/execute(http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        http:Response? denied = deploymentAccess(contextResult, request, deploymentId, true);
        if denied is http:Response { check caller->respond(denied); return; }
        DeploymentMemory|error loaded = hydrateDeployment(deploymentId);
        if loaded is error { check caller->respond(deploymentError(503, "Unable to load deployment details")); return; }
        DeploymentMemory memory = loaded;
        if memory.operation.status != types:READY { check caller->respond(deploymentError(409, "Deployment must be READY before execution")); return; }
        if !memory.targets.some(t => t.eligible && (!t.conflictDetected || t.deleteBeforeUpload)) { check caller->respond(deploymentError(409, "No eligible targets selected")); return; }
        json|error payload = request.getJsonPayload();
        string confirmation = payload is map<json> && payload["productionConfirmation"] is string ? <string>payload["productionConfirmation"] : "";
        if memory.targets.some(t => t.production && t.eligible && (!t.conflictDetected || t.deleteBeforeUpload)) && confirmation != string `DEPLOY ${memory.operation.artifactName}:${memory.operation.artifactVersion}` {
            check caller->respond(deploymentError(409, "Production confirmation does not match the required phrase")); return;
        }
        memory.operation.status = types:RUNNING; memory.operation.startedAt = now(); memory.operation.updatedAt = now();
        error? saved = storage:beginMIDeployment(memory.operation);
        if saved is error { check caller->respond(deploymentError(409, "Unable to start deployment; refresh its current state")); return; }
        auditRestMutation(storage:AUDIT_MI_DEPLOYMENT_EXECUTE, contextResult.userId, contextResult.username, request, storage:AUDIT_RESOURCE_MI_DEPLOYMENT, deploymentId, string `targets=${memory.targets.length()}`, "SUCCESS");
        _ = start executeDeployment(deploymentId);
        check caller->respond(responseFor(memory));
    }

    resource function post [string deploymentId]/cancel(http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        http:Response? denied = deploymentAccess(contextResult, request, deploymentId, true);
        if denied is http:Response { check caller->respond(denied); return; }
        DeploymentMemory|error loaded = hydrateDeployment(deploymentId);
        if loaded is error { check caller->respond(deploymentError(503, "Unable to load deployment details")); return; }
        DeploymentMemory memory = loaded;
        if !transitionAllowed(memory.operation.status, "cancel") { check caller->respond(deploymentError(409, "Deployment cannot be cancelled in its current state")); return; }
        json|error payload = request.getJsonPayload();
        string? targetId = payload is map<json> && payload["targetId"] is string ? <string>payload["targetId"] : ();
        error? saved = storage:cancelMIDeploymentTargets(memory.operation, targetId);
        if saved is error { check caller->respond(deploymentError(409, saved.message())); return; }
        auditRestMutation(storage:AUDIT_MI_DEPLOYMENT_CANCEL, contextResult.userId, contextResult.username, request, storage:AUDIT_RESOURCE_MI_DEPLOYMENT, deploymentId, "Cancellation requested", "SUCCESS");
        check caller->respond(check storage:getMIDeploymentOperation(deploymentId));
    }

    resource function post [string deploymentId]/recheck(http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        http:Response? denied = deploymentAccess(contextResult, request, deploymentId, true);
        if denied is http:Response { check caller->respond(denied); return; }
        boolean workerStopped;
        lock { workerStopped = deploymentWorkerErrors.hasKey(deploymentId); }
        if workerStopped {
            error? recovered = storage:interruptMIDeployment(deploymentId, "Recovering after deployment persistence failure; runtime recheck requested");
            if recovered is error { check caller->respond(deploymentError(503, "Deployment storage is still unavailable")); return; }
        }
        DeploymentMemory|error loaded = hydrateDeployment(deploymentId);
        if loaded is error { check caller->respond(deploymentError(503, "Unable to load deployment details")); return; }
        DeploymentMemory memory = loaded;
        if !transitionAllowed(memory.operation.status, "recheck") { check caller->respond(deploymentError(409, "Deployment is not eligible for recheck")); return; }
        json|error payload = request.getJsonPayload();
        string? targetId = payload is map<json> && payload["targetId"] is string ? <string>payload["targetId"] : ();
        boolean matched = targetId is ();
        foreach var target in memory.targets {
            if targetId is () || target.targetId == targetId {
                matched = true;
                if target.phase == types:INDETERMINATE {
                    types:MIDeploymentTarget checked = recheckTarget(memory, target.clone());
                    checked.updatedAt = now();
                    error? saved = storage:saveMIDeploymentTarget(checked);
                    if saved is error { check caller->respond(deploymentError(503, "Unable to save runtime recheck")); return; }
                }
            }
        }
        if !matched { check caller->respond(deploymentError(404, "Target not found")); return; }
        memory.targets = check storage:loadMIDeploymentTargets(deploymentId);
        memory.operation.status = storage:miDeploymentStatus(memory.targets);
        memory.operation.updatedAt = now();
        error? saved = storage:saveMIDeploymentOperation(memory.operation, "Runtime recheck completed");
        if saved is error { check caller->respond(deploymentError(503, "Unable to save recheck result")); return; }
        lock { if deploymentWorkerErrors.hasKey(deploymentId) { string removedError = deploymentWorkerErrors.remove(deploymentId); } }
        check caller->respond(responseFor(memory));
    }

    resource function post [string deploymentId]/'retry(http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        http:Response? denied = deploymentAccess(contextResult, request, deploymentId, true);
        if denied is http:Response { check caller->respond(denied); return; }
        DeploymentMemory|error loaded = hydrateDeployment(deploymentId);
        if loaded is error { check caller->respond(deploymentError(503, "Unable to load deployment details")); return; }
        DeploymentMemory memory = loaded;
        if memory.operation.status == types:RUNNING || memory.operation.status == types:CANCELLING { check caller->respond(deploymentError(409, "Wait for deployment execution to finish")); return; }
        json|error payload = request.getJsonPayload();
        if payload is error || payload !is map<json> || payload["targetIds"] !is json[] { check caller->respond(deploymentError(400, "targetIds must be an array")); return; }
        string[]|error targetIds = (<json>payload["targetIds"]).cloneWithType();
        if targetIds is error { check caller->respond(deploymentError(400, "targetIds must contain strings")); return; }
        foreach string id in targetIds { if !memory.targets.some(t => t.targetId == id) { check caller->respond(deploymentError(400, "Unknown target")); return; } }
        string[] requestedIds = targetIds;
        DeploymentMemory retryMemory = memory.clone();
        retryMemory.operation.deploymentId = uuid:createType4AsString();
        retryMemory.operation.parentDeploymentId = deploymentId;
        retryMemory.operation.createdBy = contextResult.userId;
        retryMemory.operation.status = types:READY;
        retryMemory.operation.createdAt = now(); retryMemory.operation.updatedAt = now();
        retryMemory.operation.startedAt = (); retryMemory.operation.finishedAt = (); retryMemory.operation.durationMs = ();
        retryMemory.targets = retryMemory.targets.filter(t => (t.phase == types:FAILED || t.phase == types:FAULTY || t.phase == types:INDETERMINATE) && (requestedIds.length() == 0 || requestedIds.indexOf(t.targetId) >= 0));
        if retryMemory.targets.length() == 0 { check caller->respond(deploymentError(409, "No failed or indeterminate targets selected for retry")); return; }
        foreach var target in retryMemory.targets {
            target.targetId = uuid:createType4AsString(); target.deploymentId = retryMemory.operation.deploymentId;
            target.phase = types:QUEUED; target.startedAt = (); target.finishedAt = (); target.durationMs = ();
            target.reason = (); target.message = (); target.httpStatus = (); target.evidence = []; target.updatedAt = now();
        }
        error? saved = storage:persistMIDeploymentRetry(retryMemory.operation, retryMemory.targets);
        if saved is error { check caller->respond(deploymentError(503, "Unable to persist deployment retry")); return; }
        auditRestMutation(storage:AUDIT_MI_DEPLOYMENT_RETRY, contextResult.userId, contextResult.username, request, storage:AUDIT_RESOURCE_MI_DEPLOYMENT, retryMemory.operation.deploymentId, string `parent=${deploymentId}`, "SUCCESS");
        check caller->respond(responseFor(retryMemory));
    }
}

function pageParameter(http:Request request, string name, int fallback) returns int {
    string? value = request.getQueryParamValue(name);
    if value is () { return fallback; }
    int|error parsed = int:fromString(value);
    return parsed is int && parsed >= 0 ? parsed : fallback;
}

function runtimeErrorStatus(error failure) returns int? {
    var code = failure.detail()["httpStatus"];
    return code is int ? code : ();
}
