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

map<DeploymentMemory> deploymentMemory = {};
map<string> deploymentIdempotency = {};

function deploymentError(int status, string message) returns http:Response {
    http:Response response = new;
    response.statusCode = status;
    response.setJsonPayload({"error": {"message": message}});
    return response;
}

function now() returns string => time:utcToString(time:utcNow());

function transitionAllowed(types:MIDeploymentStatus status, string action) returns boolean {
    if action == "preflight" { return status == types:DRAFT || status == types:AWAITING_DECISIONS; }
    if action == "decisions" { return status == types:AWAITING_DECISIONS || status == types:READY; }
    if action == "execute" { return status == types:READY; }
    if action == "cancel" { return status == types:DRAFT || status == types:PREFLIGHT || status == types:AWAITING_DECISIONS || status == types:READY || status == types:RUNNING || status == types:CANCELLING; }
    if action == "recheck" { return status == types:COMPLETED || status == types:COMPLETED_WITH_ISSUES || status == types:RUNNING; }
    return true;
}

function responseFor(DeploymentMemory memory) returns http:Response {
    http:Response response = new;
    response.setJsonPayload({
        id: memory.operation.deploymentId,
        orgHandler: memory.operation.orgHandler,
        status: memory.operation.status.toString(),
        artifactName: memory.operation.artifactName,
        artifactVersion: memory.operation.artifactVersion,
        fileName: memory.operation.fileName,
        fileSize: memory.operation.fileSize,
        sha256: memory.operation.sha256,
        createdAt: memory.operation.createdAt,
        updatedAt: memory.operation.updatedAt,
        targets: memory.targets
    });
    return response;
}

function hydrateDeployment(string deploymentId) returns DeploymentMemory|error {
    record {| types:MIDeploymentOperation operation; byte[] content; |}|error loaded = storage:loadMIDeploymentMemory(deploymentId);
    if loaded is error { error err = loaded; return err; }
    record {| types:MIDeploymentOperation operation; byte[] content; |} loadedValue = loaded;
    DeploymentMemory memory = {operation: loadedValue.operation, targets: [], content: loadedValue.content};
    deploymentMemory[deploymentId] = memory;
    return memory;
}

function callerContext(http:Request request) returns types:UserContextV2|http:Response {
    string|http:HeaderNotFoundError header = request.getHeader("Authorization");
    if header is http:HeaderNotFoundError { return deploymentError(401, "Authorization header missing"); }
    types:UserContextV2|error context = auth:extractUserContextV2(header);
    if context is error { return deploymentError(401, "Invalid token"); }
    return context;
}

function canDeploy(types:UserContextV2 context) returns boolean|error {
    return auth:hasAnyPermission(context.userId,
        [auth:PERMISSION_DEPLOYMENT_MANAGE, auth:PERMISSION_INTEGRATION_MANAGE,
         auth:PERMISSION_INTEGRATION_EDIT], auth:buildAccessScope());
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
    if response.statusCode < 200 || response.statusCode >= 300 { return error(string `GET applications returned HTTP ${response.statusCode}`); }
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

function persistTargetState(string deploymentId, int targetIndex, types:MIDeploymentTarget target) {
    error? targetUpdate = storage:updateMIDeploymentTarget(target);
    if targetUpdate is error { log:printWarn("Unable to persist deployment target state", targetUpdate); }
    error? eventPersisted = storage:persistMIDeploymentEvent(uuid:createType4AsString(), deploymentId, target.targetId, target.phase.toString(), target.message ?: "Target phase updated");
    if eventPersisted is error { log:printWarn("Unable to persist deployment event", eventPersisted); }
    DeploymentMemory? current = deploymentMemory[deploymentId];
    if current is DeploymentMemory && targetIndex < current.targets.length() {
        current.targets[targetIndex] = target;
        current.operation.updatedAt = now();
        deploymentMemory[deploymentId] = current;
    }
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
    if existing is error { target.phase = types:INDETERMINATE; target.message = existing.message(); return [target, "Preflight verification failed"]; }
    if (existing == "active" || existing == "faulty") && !target.deleteBeforeUpload {
        target.phase = types:SKIPPED_CONFLICT; target.reason = "Exact name/version already exists";
        return [target, "Conflict skipped"];
    }
    if target.deleteBeforeUpload {
        target.phase = types:DELETING;
        target.message = "Removing existing Carbon Application";
        persistTargetState(deploymentId, targetIndex, target);
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
        if deleted.statusCode < 200 || deleted.statusCode >= 300 {
            target.phase = types:FAILED; target.message = string `Unable to remove the existing Carbon Application (HTTP ${deleted.statusCode})`; return [target, "DELETE failed"];
        }
        // A successful DELETE is the authoritative removal result. The
        // applications listing may remain stale briefly after deletion, so an
        // immediate GET must not prevent the subsequent CAR upload.
        target.phase = types:VERIFYING_DELETE;
        persistTargetState(deploymentId, targetIndex, target);
    }
    target.phase = types:UPLOADING;
    persistTargetState(deploymentId, targetIndex, target);
    mime:Entity part = new;
    part.setByteArray(memory.content, "application/octet-stream");
    part.setContentDisposition(mime:getContentDispositionObject(string `form-data; name=file; filename=${memory.operation.fileName}`));
    http:Request outbound = new;
    outbound.method = http:POST;
    outbound.setBodyParts([part]);
    outbound.setHeader("Authorization", "Bearer " + token);
    outbound.setHeader("Accept", "application/json");
    http:Response|error uploaded = mgmtClient->post("/management/applications", outbound);
    if uploaded is error || uploaded.statusCode < 200 || uploaded.statusCode >= 300 {
        target.phase = types:FAILED; target.message = uploaded is error ? uploaded.message() : string `POST returned HTTP ${uploaded.statusCode}`; return [target, "POST failed"];
    }
    target.phase = types:VERIFYING_DEPLOY; target.attempt += 1;
    persistTargetState(deploymentId, targetIndex, target);
    int remaining = miDeploymentVerifyAttempts;
    while remaining > 0 {
        string|error state = applicationState(mgmtClient, token, memory.operation.artifactName, memory.operation.artifactVersion);
        if state == "active" { target.phase = types:SUCCEEDED; target.message = "Runtime confirmed active"; return [target, "Succeeded"]; }
        if state == "faulty" { target.phase = types:FAULTY; target.message = "Runtime reported faulty application"; return [target, "Faulty"]; }
        if state is error { target.phase = types:INDETERMINATE; target.message = state.message(); return [target, "Verification unavailable"]; }
        remaining -= 1;
        if remaining > 0 {
            // Do not exhaust all verification attempts in a tight loop. MI may
            // need several seconds to finish deploying the uploaded CAR.
            runtime:sleep(<decimal>miDeploymentVerifyIntervalSeconds);
        }
    }
    target.phase = types:INDETERMINATE; target.message = "Upload accepted but runtime confirmation timed out";
    return [target, "Indeterminate"];
}

function recheckTarget(DeploymentMemory memory, types:MIDeploymentTarget target) returns types:MIDeploymentTarget {
    types:Runtime?|error runtimeResult = storage:getRuntimeById(target.runtimeId);
    if runtimeResult is error || runtimeResult is () { target.phase = types:INDETERMINATE; target.message = "Runtime unavailable during recheck"; return target; }
    string|error base = storage:buildManagementBaseUrl(runtimeResult.managementHostname, runtimeResult.managementPort);
    if base is error { target.phase = types:INDETERMINATE; target.message = base.message(); return target; }
    http:Client|error mgmt = artifactsApiAllowInsecureTLS ? new (base, {secureSocket: {enable: false}}) : new (base);
    if mgmt is error { target.phase = types:INDETERMINATE; target.message = mgmt.message(); return target; }
    string|error token = storage:issueRuntimeHmacToken(target.runtimeId);
    if token is error { target.phase = types:INDETERMINATE; target.message = token.message(); return target; }
    string|error state = applicationState(mgmt, token, memory.operation.artifactName, memory.operation.artifactVersion);
    if state == "active" { target.phase = types:SUCCEEDED; target.message = "Runtime confirmed active"; }
    else if state == "faulty" { target.phase = types:FAULTY; target.message = "Runtime reported faulty application"; }
    else if state is error { target.phase = types:INDETERMINATE; target.message = state.message(); }
    else { target.phase = types:INDETERMINATE; target.message = "Application not present"; }
    return target;
}

function executeDeployment(string deploymentId) {
    DeploymentMemory? found = deploymentMemory[deploymentId];
    if found is () { return; }
    DeploymentMemory memory = found;
    foreach int index in 0 ..< memory.targets.length() {
        if !memory.targets[index].eligible || memory.targets[index].phase == types:SKIPPED_CONFLICT { continue; }
        memory.targets[index].phase = types:VALIDATING;
        memory.targets[index].message = "Validating runtime before deployment";
        persistTargetState(deploymentId, index, memory.targets[index]);
        boolean|error claimed = storage:claimMIDeploymentTarget(memory.targets[index].targetId, miDeploymentVerifyIntervalSeconds * miDeploymentVerifyAttempts);
        if claimed is error || !claimed {
            memory.targets[index].phase = types:INDETERMINATE;
            memory.targets[index].message = "Target is already leased by another worker";
            persistTargetState(deploymentId, index, memory.targets[index]);
            continue;
        }
        [types:MIDeploymentTarget, string]|error result = uploadTarget(memory, memory.targets[index], deploymentId, index);
        if result is error { memory.targets[index].phase = types:FAILED; memory.targets[index].message = result.message(); }
        else { memory.targets[index] = result[0]; }
        persistTargetState(deploymentId, index, memory.targets[index]);
        error? released = storage:releaseMIDeploymentTarget(memory.targets[index].targetId);
        if released is error { log:printWarn("Unable to release deployment target lease", released); }
    }
    boolean hasIssues = memory.targets.some((target) => target.phase == types:FAILED || target.phase == types:FAULTY || target.phase == types:INDETERMINATE);
    memory.operation.status = hasIssues ? types:COMPLETED_WITH_ISSUES : types:COMPLETED;
    memory.operation.updatedAt = now();
    error? operationPersisted = storage:updateMIDeploymentOperation(memory.operation);
    if operationPersisted is error { log:printWarn("Unable to persist deployment status", operationPersisted); }
    deploymentMemory[deploymentId] = memory;
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
        boolean|error permitted = canDeploy(contextResult);
        if permitted is error || !permitted { check caller->respond(deploymentError(403, "Deployment manage permission required")); return; }
        [string, byte[]]|http:Response|error fileResult = fileFromRequest(request);
        if fileResult is error { check caller->respond(deploymentError(400, fileResult.message())); return; }
        if fileResult is http:Response { check caller->respond(fileResult); return; }
        string? orgHandler = request.getQueryParamValue("orgHandler");
        if orgHandler is () || orgHandler.trim() == "" { check caller->respond(deploymentError(400, "orgHandler is required")); return; }
        string org = orgHandler is string ? orgHandler : "";
        string|http:HeaderNotFoundError idempotencyHeader = request.getHeader("Idempotency-Key");
        if idempotencyHeader is string && deploymentIdempotency.hasKey(idempotencyHeader) {
            string? existingId = deploymentIdempotency[idempotencyHeader];
            if existingId is string {
                DeploymentMemory? existing = deploymentMemory[existingId];
                if existing is DeploymentMemory { check caller->respond(responseFor(existing)); return; }
            }
        }
        DeploymentMemory memory = operationPayload(org, fileResult[0], fileResult[1], contextResult.userId);
        error? persisted = storage:persistMIDeployment(memory.operation, memory.content);
        if persisted is error { check caller->respond(deploymentError(503, "Unable to persist deployment artifact: " + persisted.message())); return; }
        deploymentMemory[memory.operation.deploymentId] = memory;
        if idempotencyHeader is string && idempotencyHeader.trim() != "" { deploymentIdempotency[idempotencyHeader] = memory.operation.deploymentId; }
        auditRestMutation(storage:AUDIT_MI_DEPLOYMENT_CREATE, contextResult.userId, contextResult.username, request, storage:AUDIT_RESOURCE_MI_DEPLOYMENT, memory.operation.deploymentId, string `artifact=${memory.operation.sha256}; org=${org}`, "SUCCESS");
        check caller->respond(responseFor(memory));
    }

    resource function get .(http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        boolean|error permitted = auth:hasAnyPermission(contextResult.userId, [auth:PERMISSION_DEPLOYMENT_VIEW, auth:PERMISSION_DEPLOYMENT_MANAGE], auth:buildAccessScope());
        if permitted is error || !permitted { check caller->respond(deploymentError(403, "Deployment view permission required")); return; }
        int pageLimit = 10;
        int pageOffset = 0;
        string? limitParam = request.getQueryParamValue("limit");
        string? offsetParam = request.getQueryParamValue("offset");
        if limitParam is string { int|error parsedLimit = int:fromString(limitParam); if parsedLimit is int { pageLimit = parsedLimit; } }
        if offsetParam is string { int|error parsedOffset = int:fromString(offsetParam); if parsedOffset is int { pageOffset = parsedOffset; } }
        record {| json[] items; int total; |}|error persisted = storage:listMIDeploymentOperations(request.getQueryParamValue("orgHandler"), pageLimit, pageOffset);
        if persisted is error { check caller->respond(deploymentError(503, "Unable to load deployment history")); return; }
        check caller->respond({items: persisted.items, total: persisted.total});
    }

    resource function get [string deploymentId](http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        boolean|error canView = auth:hasAnyPermission(contextResult.userId, [auth:PERMISSION_DEPLOYMENT_VIEW, auth:PERMISSION_DEPLOYMENT_MANAGE], auth:buildAccessScope());
        if canView is error || !canView { check caller->respond(deploymentError(canView is error ? 500 : 403, "Deployment view permission required")); return; }
        if !deploymentMemory.hasKey(deploymentId) {
            json?|error persisted = storage:getMIDeploymentOperation(deploymentId);
            if persisted is json { check caller->respond(persisted); return; }
            check caller->respond(deploymentError(404, "Deployment not found")); return;
        }
        DeploymentMemory? found = deploymentMemory[deploymentId];
        if found is () { check caller->respond(deploymentError(404, "Deployment not found")); return; }
        check caller->respond(responseFor(found));
    }

    resource function delete [string deploymentId](http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        boolean|error permitted = canDeploy(contextResult);
        if permitted is error || !permitted { check caller->respond(deploymentError(403, "Deployment manage permission required")); return; }
        error? deleted = storage:deleteMIDeployment(deploymentId);
        if deleted is error { check caller->respond(deploymentError(500, "Unable to delete deployment: " + deleted.message())); return; }
        if deploymentMemory.hasKey(deploymentId) {
            anydata removed = deploymentMemory.remove(deploymentId);
        }
        check caller->respond({"deleted": true, "id": deploymentId});
    }

    resource function post [string deploymentId]/preflight(http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        boolean|error permitted = canDeploy(contextResult);
        if permitted is error || !permitted { check caller->respond(deploymentError(403, "Deployment manage permission required")); return; }
        if !deploymentMemory.hasKey(deploymentId) { DeploymentMemory|error hydrated = hydrateDeployment(deploymentId); if hydrated is error { check caller->respond(deploymentError(404, "Deployment not found")); return; } }
        json|error payload = request.getJsonPayload();
        if payload is error { check caller->respond(deploymentError(400, "projectIds JSON payload is required")); return; }
        string[] projectIds = payload is map<json> && payload["projectIds"] is json
            ? check (<json>payload["projectIds"]).cloneWithType()
            : check payload.cloneWithType();
        DeploymentMemory? found = deploymentMemory[deploymentId];
        if found is () { check caller->respond(deploymentError(404, "Deployment not found")); return; }
        DeploymentMemory memory = found;
        if !transitionAllowed(memory.operation.status, "preflight") { check caller->respond(deploymentError(409, "Deployment cannot be preflighted in its current state")); return; }
        memory.targets = [];
        foreach string projectId in projectIds {
            // Snapshot every registered MI runtime so offline/ineligible targets
            // remain visible in the final report instead of silently disappearing.
            types:Runtime[]|error runtimes = storage:getRuntimes((), "MI", (), projectId, ());
            if runtimes is error { continue; }
            foreach types:Runtime runtime in runtimes {
                string timestamp = now();
                boolean eligible = runtime.status == "RUNNING" && runtime.managementHostname is string && runtime.managementPort is string;
                boolean hasConflict = false;
                string? probeReason = ();
                if eligible {
                    boolean|error probe = probeRuntimeConflict(runtime, memory.operation.artifactName, memory.operation.artifactVersion);
                    if probe is error { eligible = false; probeReason = "Unable to query Management API: " + probe.message(); }
                    else { hasConflict = probe; }
                }
                types:MIDeploymentTarget snapshotTarget = {targetId: uuid:createType4AsString(), deploymentId, projectId, projectName: projectId, componentId: runtime.component.id, componentName: runtime.component.displayName, environmentId: runtime.environment.id, environmentName: runtime.environment.name, runtimeId: runtime.runtimeId, runtimeName: runtime?.runtimeName ?: runtime.runtimeId, production: runtime.environment.name.toLowerAscii().indexOf("prod") >= 0, eligible, conflictDetected: hasConflict, deleteBeforeUpload: false, phase: !eligible ? types:SKIPPED_INELIGIBLE : types:QUEUED, attempt: 0, reason: !eligible ? (probeReason ?: "Runtime is not running or has no management endpoint") : (hasConflict ? "Exact name/version already exists" : "No exact conflict found"), evidence: [], updatedAt: timestamp};
                error? targetPersisted = storage:persistMIDeploymentTarget(snapshotTarget);
                if targetPersisted is error { check caller->respond(deploymentError(503, "Unable to persist deployment target: " + targetPersisted.message())); return; }
                memory.targets.push(snapshotTarget);
                error? eventPersisted = storage:persistMIDeploymentEvent(uuid:createType4AsString(), deploymentId, snapshotTarget.targetId, snapshotTarget.phase.toString(), "Target added to immutable preflight snapshot");
                if eventPersisted is error { log:printWarn("Unable to persist deployment event", eventPersisted); }
            }
        }
        memory.operation.status = types:AWAITING_DECISIONS;
        memory.operation.updatedAt = now();
        error? operationPersisted = storage:updateMIDeploymentOperation(memory.operation);
        if operationPersisted is error { log:printWarn("Unable to persist deployment status", operationPersisted); }
        deploymentMemory[deploymentId] = memory;
        auditRestMutation(storage:AUDIT_MI_DEPLOYMENT_PREFLIGHT, contextResult.userId, contextResult.username, request, storage:AUDIT_RESOURCE_MI_DEPLOYMENT, deploymentId, string `targets=${memory.targets.length()}`, "SUCCESS");
        check caller->respond(responseFor(memory));
    }

    resource function post [string deploymentId]/cancel(http:Caller caller, http:Request callerRequest) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(callerRequest);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        boolean|error permitted = canDeploy(contextResult);
        if permitted is error || !permitted { check caller->respond(deploymentError(403, "Deployment manage permission required")); return; }
        if !deploymentMemory.hasKey(deploymentId) { DeploymentMemory|error hydrated = hydrateDeployment(deploymentId); if hydrated is error { check caller->respond(deploymentError(404, "Deployment not found")); return; } }
        DeploymentMemory? found = deploymentMemory[deploymentId];
        if found is () { check caller->respond(deploymentError(404, "Deployment not found")); return; }
        DeploymentMemory memory = found;
        if !transitionAllowed(memory.operation.status, "cancel") { check caller->respond(deploymentError(409, "Deployment cannot be cancelled in its current state")); return; }
        json|error cancelPayload = callerRequest.getJsonPayload();
        string? requestedTargetId = cancelPayload is json && cancelPayload is map<json> && cancelPayload["targetId"] is string
            ? <string>cancelPayload["targetId"] : ();
        if requestedTargetId is string {
            boolean cancelled = false;
            foreach int index in 0 ..< memory.targets.length() {
                if memory.targets[index].targetId == requestedTargetId && memory.targets[index].phase == types:QUEUED {
                    memory.targets[index].phase = types:CANCELLED;
                    memory.targets[index].message = "Target cancellation requested";
                    error? targetPersisted = storage:updateMIDeploymentTarget(memory.targets[index]);
                    if targetPersisted is error { log:printWarn("Unable to persist cancelled deployment target", targetPersisted); }
                    error? eventPersisted = storage:persistMIDeploymentEvent(uuid:createType4AsString(), deploymentId, memory.targets[index].targetId, memory.targets[index].phase.toString(), memory.targets[index].message ?: "Target cancellation requested");
                    if eventPersisted is error { log:printWarn("Unable to persist deployment event", eventPersisted); }
                    cancelled = true;
                }
            }
            if !cancelled { check caller->respond(deploymentError(409, "Target is not queued or was not found")); return; }
            memory.operation.updatedAt = now();
            deploymentMemory[deploymentId] = memory;
            auditRestMutation(storage:AUDIT_MI_DEPLOYMENT_CANCEL, contextResult.userId, contextResult.username, callerRequest, storage:AUDIT_RESOURCE_MI_DEPLOYMENT, deploymentId, string `target=${requestedTargetId}`, "SUCCESS");
            check caller->respond(responseFor(memory));
            return;
        }
        memory.operation.status = types:CANCELLED;
        memory.operation.updatedAt = now();
        error? operationPersisted = storage:updateMIDeploymentOperation(memory.operation);
        if operationPersisted is error { log:printWarn("Unable to persist deployment status", operationPersisted); }
        deploymentMemory[deploymentId] = memory;
        auditRestMutation(storage:AUDIT_MI_DEPLOYMENT_CANCEL, contextResult.userId, contextResult.username, callerRequest, storage:AUDIT_RESOURCE_MI_DEPLOYMENT, deploymentId, "cancel requested", "SUCCESS");
        check caller->respond(responseFor(memory));
    }

    resource function patch [string deploymentId]/targets(http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        boolean|error permitted = canDeploy(contextResult);
        if permitted is error || !permitted { check caller->respond(deploymentError(403, "Deployment manage permission required")); return; }
        if !deploymentMemory.hasKey(deploymentId) { DeploymentMemory|error hydrated = hydrateDeployment(deploymentId); if hydrated is error { check caller->respond(deploymentError(404, "Deployment not found")); return; } }
        json|error payload = request.getJsonPayload();
        if payload is error { check caller->respond(deploymentError(400, "decisions payload is required")); return; }
        DeploymentMemory? found = deploymentMemory[deploymentId];
        if found is () { check caller->respond(deploymentError(404, "Deployment not found")); return; }
        DeploymentMemory memory = found;
        if !transitionAllowed(memory.operation.status, "decisions") { check caller->respond(deploymentError(409, "Conflict decisions are no longer editable")); return; }
        if payload is map<json> {
            json? decisions = payload["decisions"];
            if decisions is json[] {
                foreach json item in decisions {
                    if item is map<json> && item["targetId"] is string && item["deleteBeforeUpload"] is boolean {
                        string targetId = <string>item["targetId"];
                        foreach int index in 0 ..< memory.targets.length() {
                            if memory.targets[index].targetId == targetId {
                                memory.targets[index].deleteBeforeUpload = <boolean>item["deleteBeforeUpload"];
                                error? decisionPersisted = storage:updateMIDeploymentTarget(memory.targets[index]);
                                if decisionPersisted is error { log:printWarn("Unable to persist conflict decision", decisionPersisted); }
                            }
                        }
                    }
                }
            }
        }
        memory.operation.status = types:READY; memory.operation.updatedAt = now(); deploymentMemory[deploymentId] = memory;
        check caller->respond(responseFor(memory));
    }

    resource function post [string deploymentId]/execute(http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        boolean|error permitted = canDeploy(contextResult);
        if permitted is error || !permitted { check caller->respond(deploymentError(403, "Deployment manage permission required")); return; }
        if !deploymentMemory.hasKey(deploymentId) { DeploymentMemory|error hydrated = hydrateDeployment(deploymentId); if hydrated is error { check caller->respond(deploymentError(404, "Deployment not found")); return; } }
        DeploymentMemory? found = deploymentMemory[deploymentId];
        if found is () { check caller->respond(deploymentError(404, "Deployment not found")); return; }
        DeploymentMemory memory = found;
        if !transitionAllowed(memory.operation.status, "execute") { check caller->respond(deploymentError(409, "Deployment must be READY before execution")); return; }
        memory.operation.status = types:RUNNING;
        json|error executePayload = request.getJsonPayload();
        boolean hasProduction = memory.targets.some((target) => target.production && target.eligible);
        string expected = string `DEPLOY ${memory.operation.artifactName}:${memory.operation.artifactVersion}`;
        string confirmation = executePayload is json && executePayload is map<json> && executePayload["productionConfirmation"] is string
            ? <string>executePayload["productionConfirmation"] : "";
        if hasProduction && confirmation != expected {
            check caller->respond(deploymentError(409, "Production confirmation does not match the required phrase")); return;
        }
        memory.operation.updatedAt = now();
        error? operationPersisted = storage:updateMIDeploymentOperation(memory.operation);
        if operationPersisted is error { log:printWarn("Unable to persist deployment status", operationPersisted); }
        deploymentMemory[deploymentId] = memory;
        auditRestMutation(storage:AUDIT_MI_DEPLOYMENT_EXECUTE, contextResult.userId, contextResult.username, request, storage:AUDIT_RESOURCE_MI_DEPLOYMENT, deploymentId, string `targets=${memory.targets.length()}`, "SUCCESS");
        _ = start executeDeployment(deploymentId);
        check caller->respond(responseFor(memory));
    }

    resource function post [string deploymentId]/recheck(http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        boolean|error permitted = canDeploy(contextResult);
        if permitted is error || !permitted { check caller->respond(deploymentError(403, "Deployment manage permission required")); return; }
        if !deploymentMemory.hasKey(deploymentId) { DeploymentMemory|error hydrated = hydrateDeployment(deploymentId); if hydrated is error { check caller->respond(deploymentError(404, "Deployment not found")); return; } }
        DeploymentMemory? found = deploymentMemory[deploymentId];
        if found is () { check caller->respond(deploymentError(404, "Deployment not found")); return; }
        DeploymentMemory memory = found;
        if !transitionAllowed(memory.operation.status, "recheck") { check caller->respond(deploymentError(409, "Deployment is not eligible for recheck")); return; }
        json|error recheckPayload = request.getJsonPayload();
        string? requestedTargetId = recheckPayload is json && recheckPayload is map<json> && recheckPayload["targetId"] is string
            ? <string>recheckPayload["targetId"] : ();
        foreach int index in 0 ..< memory.targets.length() {
            if memory.targets[index].phase == types:INDETERMINATE && (requestedTargetId is () || memory.targets[index].targetId == requestedTargetId) {
                memory.targets[index] = recheckTarget(memory, memory.targets[index]);
                error? targetUpdate = storage:updateMIDeploymentTarget(memory.targets[index]);
                if targetUpdate is error { log:printWarn("Unable to persist deployment target update", targetUpdate); }
                error? eventPersisted = storage:persistMIDeploymentEvent(uuid:createType4AsString(), deploymentId, memory.targets[index].targetId, memory.targets[index].phase.toString(), memory.targets[index].message ?: "Target rechecked");
                if eventPersisted is error { log:printWarn("Unable to persist deployment event", eventPersisted); }
            }
        }
        boolean hasUnresolved = memory.targets.some((target) => target.phase == types:INDETERMINATE);
        memory.operation.status = hasUnresolved ? types:COMPLETED_WITH_ISSUES : types:COMPLETED; memory.operation.updatedAt = now();
        error? operationPersisted = storage:updateMIDeploymentOperation(memory.operation);
        if operationPersisted is error { log:printWarn("Unable to persist deployment status", operationPersisted); }
        deploymentMemory[deploymentId] = memory;
        check caller->respond(responseFor(memory));
    }

    resource function post [string deploymentId]/'retry(http:Caller caller, http:Request request) returns error? {
        types:UserContextV2|http:Response contextResult = callerContext(request);
        if contextResult is http:Response { check caller->respond(contextResult); return; }
        boolean|error permitted = canDeploy(contextResult);
        if permitted is error || !permitted { check caller->respond(deploymentError(403, "Deployment manage permission required")); return; }
        if !deploymentMemory.hasKey(deploymentId) { DeploymentMemory|error hydrated = hydrateDeployment(deploymentId); if hydrated is error { check caller->respond(deploymentError(404, "Deployment not found")); return; } }
        DeploymentMemory? found = deploymentMemory[deploymentId];
        if found is () { check caller->respond(deploymentError(404, "Deployment not found")); return; }
        DeploymentMemory original = found; DeploymentMemory retryMemory = original;
        string[] requestedTargetIds = [];
        json|error retryPayload = request.getJsonPayload();
        if retryPayload is json && retryPayload is map<json> && retryPayload["targetIds"] is json {
            requestedTargetIds = check (<json>retryPayload["targetIds"]).cloneWithType();
        }
        retryMemory.operation.deploymentId = uuid:createType4AsString(); retryMemory.operation.parentDeploymentId = original.operation.deploymentId; retryMemory.operation.status = types:READY; retryMemory.operation.createdAt = now(); retryMemory.operation.updatedAt = retryMemory.operation.createdAt;
        retryMemory.targets = original.targets.filter((target) => (target.phase == types:FAILED || target.phase == types:FAULTY || target.phase == types:INDETERMINATE) && (requestedTargetIds.length() == 0 || requestedTargetIds.indexOf(target.targetId) >= 0));
        if retryMemory.targets.length() == 0 { check caller->respond(deploymentError(409, "No failed or indeterminate targets selected for retry")); return; }
        foreach int index in 0 ..< retryMemory.targets.length() { retryMemory.targets[index].deploymentId = retryMemory.operation.deploymentId; retryMemory.targets[index].phase = types:QUEUED; retryMemory.targets[index].attempt += 1; }
        deploymentMemory[retryMemory.operation.deploymentId] = retryMemory; check caller->respond(responseFor(retryMemory));
    }
}
