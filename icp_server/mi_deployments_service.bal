// Durable-operation HTTP contract for organization-wide MI CAR deployments.
// The repository-backed worker is deliberately kept behind this service boundary so
// deployments can be resumed and observed without coupling the browser to MI hosts.
import icp_server.auth;
import icp_server.storage;
import icp_server.types;
import icp_server.mi_management;
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

type ApplicationObservation record {|
    string state;
    string? name = ();
    string? version = ();
    string? errorMessage = ();
    string? faultStackTrace = ();
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

function verificationError(string message, int? status = (), string reason = "VERIFICATION_INVALID_RESPONSE") returns error {
    if status is int { return error(message, httpStatus = status, verificationReason = reason); }
    return error(message, verificationReason = reason);
}

function observationString(map<json> item, string key) returns string? {
    json? value = item[key];
    return value is string ? value : ();
}

function applicationMatches(string itemName, string itemVersion, string name, string version) returns boolean {
    if itemName == "" || itemName.endsWith(".car") { return false; }
    if version != "unknown" {
        return itemName == name && itemVersion == version;
    }
    // A CAR without metadata can be represented by its complete name or by a
    // runtime name plus a version suffix. Only complete filename candidates are
    // accepted; a bare prefix is never enough.
    string stem = name.endsWith(".car") ? name.substring(0, name.length() - 4) : name;
    return itemName == stem || (itemVersion != "" &&
        (itemName + "-" + itemVersion == stem || itemName + "_" + itemVersion == stem));
}

// Query the authoritative MI application state. Both lists are examined before
// deciding: a matching faulty entry always wins over an active entry.
function applicationState(http:Client mgmt, string token, string name, string version) returns ApplicationObservation|error {
    http:Response response = check mgmt->get("/management/applications", {"Authorization": "Bearer " + token, "Accept": "application/json"});
    if response.statusCode < 200 || response.statusCode >= 300 {
        string reason = response.statusCode == 401 || response.statusCode == 403 ? "VERIFICATION_UNAUTHORIZED" :
            (response.statusCode == 429 || response.statusCode >= 500 ? "VERIFICATION_TRANSIENT_HTTP" : "VERIFICATION_INVALID_RESPONSE");
        return verificationError(string `GET /management/applications returned HTTP ${response.statusCode}`, response.statusCode, reason);
    }
    json|error payloadResult = response.getJsonPayload();
    if payloadResult is error { return verificationError("Runtime returned an invalid applications JSON payload"); }
    json payload = payloadResult;
    if payload !is map<json> { return verificationError("Runtime returned a non-object applications payload"); }
    ApplicationObservation? active = ();
    ApplicationObservation? faulty = ();
    int activeMatches = 0;
    int faultyMatches = 0;
    foreach [string, string] list in [["activeList", "active"], ["faultyList", "faulty"]] {
        json? raw = payload[list[0]];
        if raw is () || raw !is json[] { return verificationError(string `Runtime applications payload is missing ${list[0]}`); }
        foreach json item in raw {
            if item !is map<json> { continue; }
            string itemName = observationString(item, "name") ?: "";
            string itemVersion = observationString(item, "version") ?: "";
            if !applicationMatches(itemName, itemVersion, name, version) { continue; }
            ApplicationObservation observation = {state: list[1], name: itemName, version: itemVersion,
                errorMessage: observationString(item, "errorMessage")};
            if list[1] == "faulty" { faultyMatches += 1; faulty = observation; }
            else { activeMatches += 1; active = observation; }
        }
    }
    if faultyMatches > 1 || activeMatches > 1 || (faultyMatches > 0 && activeMatches > 1) {
        return {state: "ambiguous", name: name, version: version};
    }
    if faulty is ApplicationObservation { return faulty; }
    if active is ApplicationObservation { return active; }
    return {state: "missing"};
}

function probeRuntimeConflict(types:Runtime runtime, string artifactName, string artifactVersion) returns ApplicationObservation|error {
    string baseUrl = check storage:buildManagementBaseUrl(runtime.managementHostname, runtime.managementPort);
    http:ClientConfiguration clientConfig = {timeout: 10};
    if artifactsApiAllowInsecureTLS { clientConfig.secureSocket = {enable: false}; }
    http:Client|error clientResult = new (baseUrl, clientConfig);
    if clientResult is error { return clientResult; }
    string token = check storage:issueRuntimeHmacToken(runtime.runtimeId);
    ApplicationObservation|error state = applicationState(clientResult, token, artifactName, artifactVersion);
    if state is error { return state; }
    return state;
}

function persistTargetState(string deploymentId, int targetIndex, types:MIDeploymentTarget target) returns error? {
    target.updatedAt = now();
    error? persisted = storage:saveMIDeploymentTarget(target);
    if persisted is error { return error("Deployment persistence failed", persisted); }
}

function verificationReason(error failure) returns string {
    var reason = failure.detail()["verificationReason"];
    return reason is string ? reason : "VERIFICATION_UNAVAILABLE";
}

function elapsedVerificationSeconds(time:Utc startedAt) returns decimal {
    return time:utcDiffSeconds(time:utcNow(), startedAt);
}

function boundedEvidence(string value) returns string {
    if value.length() <= 32768 { return value; }
    string suffix = " [truncated]";
    return value.substring(0, 32768 - suffix.length()) + suffix;
}

function applicationIdentity(DeploymentMemory memory) returns string {
    return memory.operation.artifactVersion == "unknown" ? memory.operation.artifactName :
        memory.operation.artifactName + "-" + memory.operation.artifactVersion;
}

function observeEvidence(ApplicationObservation observation) returns string {
    string identity = observation.name ?: "unknown";
    string version = observation.version ?: "unknown";
    return string `GET /management/applications observed ${observation.state} (${identity}:${version}) at ${now()}`;
}

function uploadTarget(DeploymentMemory memory, types:MIDeploymentTarget target, string deploymentId, int targetIndex) returns [types:MIDeploymentTarget, string]|error {
    types:Runtime?|error runtimeResult = storage:getRuntimeById(target.runtimeId);
    if runtimeResult is error { return error("Unable to resolve runtime"); }
    if runtimeResult is () || runtimeResult.runtimeType != types:MI || runtimeResult.status != "RUNNING" {
        target.phase = types:SKIPPED_INELIGIBLE; target.reason = "Runtime is not running"; return [target, "Runtime is not running"];
    }
    string baseUrl = check storage:buildManagementBaseUrl(runtimeResult.managementHostname, runtimeResult.managementPort);
    http:ClientConfiguration clientConfig = {timeout: 10};
    if artifactsApiAllowInsecureTLS { clientConfig.secureSocket = {enable: false}; }
    http:Client|error clientResult = new (baseUrl, clientConfig);
    if clientResult is error { return clientResult; }
    http:Client mgmtClient = clientResult;
    string token = check storage:issueRuntimeHmacToken(target.runtimeId);
    ApplicationObservation|error existing = applicationState(mgmtClient, token, memory.operation.artifactName, memory.operation.artifactVersion);
    if existing is error { target.httpStatus = runtimeErrorStatus(existing); target.reason = verificationReason(existing); target.phase = types:INDETERMINATE; target.message = existing.message(); return [target, "Preflight verification failed"]; }
    if existing.state == "ambiguous" {
        target.reason = "APPLICATION_IDENTITY_AMBIGUOUS"; target.phase = types:INDETERMINATE; target.message = "Runtime returned multiple matching application identities";
        return [target, "Preflight identity is ambiguous"];
    }
    if (existing.state == "active" || existing.state == "faulty") && !target.deleteBeforeUpload {
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
        target.phase = types:VERIFYING_DELETE;
        target.message = "Delete accepted; waiting for runtime removal confirmation";
        check persistTargetState(deploymentId, targetIndex, target);
        time:Utc deleteStarted = time:utcNow();
        int deleteChecks = 0;
        int missingChecks = 0;
        boolean removalConfirmed = false;
        while deleteChecks < miDeploymentVerifyAttempts && elapsedVerificationSeconds(deleteStarted) <= <decimal>miDeploymentDeleteVerifyTimeoutSeconds {
            ApplicationObservation|error removal = applicationState(mgmtClient, token, memory.operation.artifactName, memory.operation.artifactVersion);
            deleteChecks += 1;
            if removal is error {
                missingChecks = 0;
                target.reason = verificationReason(removal);
                target.message = removal.message();
                target.evidence.push(string `GET /management/applications returned HTTP ${runtimeErrorStatus(removal) ?: "no status"} at ${now()}`);
                check persistTargetState(deploymentId, targetIndex, target);
                if target.reason == "VERIFICATION_UNAUTHORIZED" || target.reason == "VERIFICATION_INVALID_RESPONSE" {
                    target.phase = types:INDETERMINATE; return [target, "Delete verification unavailable"];
                }
            } else if removal.state == "ambiguous" {
                target.phase = types:INDETERMINATE; target.reason = "APPLICATION_IDENTITY_AMBIGUOUS";
                target.message = "Runtime returned multiple matching application identities while confirming removal";
                return [target, "Delete verification is ambiguous"];
            } else if removal.state == "missing" {
                missingChecks += 1;
                if missingChecks >= 2 { removalConfirmed = true; break; }
            } else {
                missingChecks = 0;
            }
            if !removalConfirmed && deleteChecks < miDeploymentVerifyAttempts && elapsedVerificationSeconds(deleteStarted) < <decimal>miDeploymentDeleteVerifyTimeoutSeconds {
                runtime:sleep(<decimal>miDeploymentVerifyIntervalSeconds);
            }
        }
        if !removalConfirmed {
            target.phase = types:INDETERMINATE; target.reason = "DELETE_VERIFICATION_TIMEOUT";
            target.message = "Delete was accepted but the runtime still reports the application or could not confirm its removal";
            return [target, "Delete verification timed out"];
        }
        target.evidence.push(string `GET /management/applications confirmed removal at ${now()}`);
        target.reason = ();
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
    time:Utc verificationStarted = time:utcNow();
    time:Utc? activeSince = ();
    string lastObservation = "";
    int checks = 0;
    while checks < miDeploymentVerifyAttempts && elapsedVerificationSeconds(verificationStarted) <= <decimal>miDeploymentVerifyTimeoutSeconds {
        ApplicationObservation|error state = applicationState(mgmtClient, token, memory.operation.artifactName, memory.operation.artifactVersion);
        checks += 1;
        if state is error {
            string reason = verificationReason(state);
            target.httpStatus = runtimeErrorStatus(state);
            if reason == "VERIFICATION_UNAUTHORIZED" || reason == "VERIFICATION_INVALID_RESPONSE" {
                target.reason = reason; target.phase = types:INDETERMINATE; target.message = state.message(); return [target, "Verification unavailable"];
            }
            activeSince = ();
            if lastObservation != "error:" + reason {
                target.evidence.push(string `GET /management/applications returned ${reason} at ${now()}`);
                target.message = "Runtime verification temporarily unavailable; retrying";
                check persistTargetState(deploymentId, targetIndex, target);
                lastObservation = "error:" + reason;
            }
        } else if state.state == "faulty" {
            target.reason = "RUNTIME_FAULTY"; target.phase = types:FAULTY;
            target.message = state.errorMessage ?: "Runtime reported faulty application";
            target.evidence.push(observeEvidence(state));
            string faultName = state.name ?: applicationIdentity(memory);
            mi_management:MgmtCompositeAppFaultResponse|error diagnostic = mi_management:fetchCompositeAppFaultDiagnostic(mgmtClient, token, faultName);
            if diagnostic is mi_management:MgmtCompositeAppFaultResponse {
                boolean sameVersion = diagnostic.version is () || state.version is () || diagnostic.version == state.version;
                if diagnostic.name == faultName && sameVersion {
                    string? diagnosticMessage = diagnostic.errorMessage;
                    if diagnosticMessage is string && diagnosticMessage.trim() != "" {
                        target.message = diagnosticMessage;
                    }
                    string? diagnosticStack = diagnostic.faultStackTrace;
                    if diagnosticStack is string && diagnosticStack.trim() != "" {
                        target.evidence.push(boundedEvidence(string `Runtime fault stack trace:\n${diagnosticStack}`));
                    } else {
                        target.evidence.push("Runtime fault diagnostic did not include a stack trace");
                    }
                } else {
                    target.evidence.push("Runtime fault diagnostic identity did not match the deployed application");
                }
            } else {
                target.httpStatus = runtimeErrorStatus(diagnostic) ?: target.httpStatus;
                target.evidence.push("Runtime did not expose a fault stack trace through /management/applications/{name}/fault");
            }
            return [target, "Faulty"];
        } else if state.state == "ambiguous" {
            target.reason = "APPLICATION_IDENTITY_AMBIGUOUS"; target.phase = types:INDETERMINATE;
            target.message = "Runtime returned multiple matching application identities";
            return [target, "Verification identity is ambiguous"];
        } else if state.state == "active" {
            if activeSince is () { activeSince = time:utcNow(); }
            if lastObservation != "active" {
                target.evidence.push(observeEvidence(state));
                target.message = "Runtime reports active; waiting for stability confirmation";
                check persistTargetState(deploymentId, targetIndex, target);
                lastObservation = "active";
            }
            if activeSince is time:Utc && time:utcDiffSeconds(time:utcNow(), activeSince) >= <decimal>miDeploymentVerifyStableSeconds {
                target.reason = (); target.phase = types:SUCCEEDED; target.message = "Runtime confirmed active and stable";
                target.evidence.push(string `Active state remained stable for ${miDeploymentVerifyStableSeconds} seconds`);
                return [target, "Succeeded"];
            }
        } else {
            activeSince = ();
            if lastObservation != "missing" {
                target.evidence.push(observeEvidence(state));
                target.message = "Upload accepted; application is not visible yet";
                check persistTargetState(deploymentId, targetIndex, target);
                lastObservation = "missing";
            }
        }
        if checks < miDeploymentVerifyAttempts && elapsedVerificationSeconds(verificationStarted) < <decimal>miDeploymentVerifyTimeoutSeconds {
            runtime:sleep(<decimal>miDeploymentVerifyIntervalSeconds);
        }
    }
    target.phase = types:INDETERMINATE; target.reason = "VERIFICATION_TIMEOUT";
    target.message = "Upload accepted but runtime confirmation timed out; consult the runtime logs for deployment errors";
    return [target, "Indeterminate"];
}

function recheckTarget(DeploymentMemory memory, types:MIDeploymentTarget target) returns types:MIDeploymentTarget {
    target.httpStatus = ();
    types:Runtime?|error runtimeResult = storage:getRuntimeById(target.runtimeId);
    if runtimeResult is error || runtimeResult is () { target.phase = types:INDETERMINATE; target.message = "Runtime unavailable during recheck"; return target; }
    string|error base = storage:buildManagementBaseUrl(runtimeResult.managementHostname, runtimeResult.managementPort);
    if base is error { target.phase = types:INDETERMINATE; target.message = base.message(); return target; }
    http:ClientConfiguration recheckConfig = {timeout: 10};
    if artifactsApiAllowInsecureTLS { recheckConfig.secureSocket = {enable: false}; }
    http:Client|error mgmt = new (base, recheckConfig);
    if mgmt is error { target.phase = types:INDETERMINATE; target.message = mgmt.message(); return target; }
    string|error token = storage:issueRuntimeHmacToken(target.runtimeId);
    if token is error { target.phase = types:INDETERMINATE; target.message = token.message(); return target; }
    time:Utc started = time:utcNow();
    time:Utc? activeSince = ();
    int checks = 0;
    while checks < miDeploymentVerifyAttempts && elapsedVerificationSeconds(started) <= <decimal>miDeploymentVerifyTimeoutSeconds {
        ApplicationObservation|error state = applicationState(mgmt, token, memory.operation.artifactName, memory.operation.artifactVersion);
        checks += 1;
        if state is error {
            target.httpStatus = runtimeErrorStatus(state); target.reason = verificationReason(state);
            target.phase = types:INDETERMINATE; target.message = "Recheck could not query the runtime: " + state.message(); activeSince = ();
        } else if state.state == "active" {
            if activeSince is () { activeSince = time:utcNow(); }
            target.reason = (); target.message = "Recheck reports active; waiting for stability confirmation";
            if activeSince is time:Utc && time:utcDiffSeconds(time:utcNow(), activeSince) >= <decimal>miDeploymentVerifyStableSeconds {
                target.phase = types:SUCCEEDED; target.message = "Runtime confirmed active and stable during recheck"; return target;
            }
        } else if state.state == "faulty" {
            target.reason = "RUNTIME_FAULTY"; target.phase = types:FAULTY;
            target.message = state.errorMessage ?: "Runtime reported faulty application";
            string faultName = state.name ?: applicationIdentity(memory);
            mi_management:MgmtCompositeAppFaultResponse|error diagnostic = mi_management:fetchCompositeAppFaultDiagnostic(mgmt, token, faultName);
            if diagnostic is mi_management:MgmtCompositeAppFaultResponse {
                string? diagnosticStack = diagnostic.faultStackTrace;
                if diagnosticStack is string && diagnosticStack.trim() != "" {
                    target.evidence.push(boundedEvidence(string `Runtime fault stack trace:\n${diagnosticStack}`));
                }
            } else {
                target.httpStatus = runtimeErrorStatus(diagnostic) ?: target.httpStatus;
            }
            return target;
        } else if state.state == "ambiguous" {
            target.reason = "APPLICATION_IDENTITY_AMBIGUOUS"; target.phase = types:INDETERMINATE;
            target.message = "Runtime returned multiple matching application identities"; return target;
        } else {
            activeSince = (); target.reason = "VERIFICATION_TIMEOUT"; target.phase = types:INDETERMINATE;
            target.message = "Recheck still cannot confirm the application";
        }
        if checks < miDeploymentVerifyAttempts && elapsedVerificationSeconds(started) < <decimal>miDeploymentVerifyTimeoutSeconds {
            runtime:sleep(<decimal>miDeploymentVerifyIntervalSeconds);
        }
    }
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
                    ApplicationObservation|error probe = probeRuntimeConflict(runtime, memory.operation.artifactName, memory.operation.artifactVersion);
                    if probe is error { eligible = false; reason = "Unable to query Management API: " + probe.message(); }
                    else if probe.state == "ambiguous" { eligible = false; reason = "APPLICATION_IDENTITY_AMBIGUOUS"; }
                    else { hasConflict = probe.state == "active" || probe.state == "faulty"; }
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
