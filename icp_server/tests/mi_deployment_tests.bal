import icp_server.storage;
import icp_server.types;
import ballerina/test;
import ballerina/http;
import ballerina/uuid;

const string MI_TEST_RUNTIME = "bd000000-0000-4000-8000-000000000001";
const int MI_TEST_PORT = 19661;
string miMockState = "missing";
int miMockUploadCode = 200;
int miMockUploads = 0;
int miMockApplicationGets = 0;
int miMockFaultGets = 0;
string miMockAfterUpload = "active";
string miMockFaultMessage = "Simulated runtime deployment failure";
string miMockFaultStack = "org.apache.synapse.SynapseException: simulated failure";
string miTestSecret = "";
string[] miTestOperations = [];
listener http:Listener miMockListener = new (MI_TEST_PORT, {secureSocket: {key: {path: keystorePath, password: resolvedKeystorePassword}}});
service /management/applications on miMockListener {
    resource function get .() returns json {
        miMockApplicationGets += 1;
        return {activeList: miMockState == "active" ? [{name: "history-test", version: "1.0.0"}] : [],
            faultyList: miMockState == "faulty" ? [{name: "history-test", version: "1.0.0"}] : []};
    }

    resource function get [string application]/fault() returns json {
        miMockFaultGets += 1;
        if miMockState != "faulty" { return {"error": "Faulty application not found"}; }
        return {name: application, version: "1.0.0", errorMessage: miMockFaultMessage, faultStackTrace: miMockFaultStack};
    }
    resource function post .() returns http:Response {
        miMockUploads += 1;
        if miMockUploadCode == 200 { miMockState = miMockAfterUpload; }
        http:Response response = new;
        response.statusCode = miMockUploadCode;
        response.setJsonPayload({message: miMockUploadCode == 200 ? "Accepted" : "Simulated runtime rejection"});
        return response;
    }
    resource function delete [string application]() returns http:Response {
        miMockState = "missing";
        http:Response response = new;
        response.statusCode = 200;
        return response;
    }
}

final http:Client miApi = check new (string `https://localhost:${serverPort}/icp/mi_deployments`, secureSocket = {cert: {path: truststorePath, password: truststorePassword}});

function miFixture() returns DeploymentMemory|error {
    DeploymentMemory memory = operationPayload("default", "history-test.car", [0x50, 0x4b, 0x03, 0x04], "550e8400-e29b-41d4-a716-446655440000");
    memory.operation.artifactName = "history-test"; memory.operation.artifactVersion = "1.0.0";
    check storage:persistMIDeployment(memory.operation, memory.content);
    miTestOperations.push(memory.operation.deploymentId);
    return memory;
}
function miTarget(string deploymentId, string runtimeId = MI_TEST_RUNTIME) returns types:MIDeploymentTarget {
    return {targetId: uuid:createType4AsString(), deploymentId, projectId: HB_PROJECT_ID, projectName: "Historical project",
        componentId: HB_COMPONENT_ID, componentName: "Historical component", environmentId: HB_ENV_ID, environmentName: "Dev",
        runtimeId, runtimeName: "Historical runtime", production: false, eligible: true, conflictDetected: false,
        deleteBeforeUpload: false, phase: types:QUEUED, attempt: 0, updatedAt: now()};
}
function miReady(DeploymentMemory memory, types:MIDeploymentTarget[] targets) returns error? {
    memory.operation.status = types:READY;
    memory.operation.selectedProjectIds = [HB_PROJECT_ID];
    check storage:replaceMIDeploymentTargets(memory.operation, targets);
}
function miRun(DeploymentMemory memory) returns DeploymentMemory|error {
    memory.operation.status = types:RUNNING; memory.operation.startedAt = now();
    check storage:beginMIDeployment(memory.operation);
    executeDeployment(memory.operation.deploymentId);
    return hydrateDeployment(memory.operation.deploymentId);
}

@test:BeforeGroups {value: ["mi-deployments"]}
function setupMIDeploymentTests() returns error? {
    cleanupRuntime(MI_TEST_RUNTIME);
    types:Heartbeat heartbeat = buildHeartbeat(MI_TEST_RUNTIME, "history-test-runtime");
    heartbeat.runtimeType = "MI"; heartbeat.runtimeHostname = "localhost"; heartbeat.runtimePort = MI_TEST_PORT.toString();
    types:HeartbeatResponse _ = check storage:processHeartbeat(heartbeat, preResolved = true);
    miTestSecret = check storage:createOrgSecret(HB_ENV_ID, "550e8400-e29b-41d4-a716-446655440000");
    int? split = miTestSecret.indexOf(".");
    if split is int { check storage:updateRuntimeKeyId(MI_TEST_RUNTIME, miTestSecret.substring(0, split)); }
}
@test:AfterGroups {value: ["mi-deployments"], alwaysRun: true}
function cleanupMIDeploymentTests() returns error? {
    check storage:recoverMIDeploymentLeases();
    foreach string id in miTestOperations { error? cleanupError = storage:deleteMIDeployment(id); }
    cleanupRuntime(MI_TEST_RUNTIME);
    int? split = miTestSecret.indexOf(".");
    if split is int { error? cleanupError = storage:revokeOrgSecret(miTestSecret.substring(0, split)); }
}

@test:Config {groups: ["mi-deployments"]}
function testMIDeploymentStoredDetailsAndEvents() returns error? {
    DeploymentMemory memory = check miFixture();
    types:MIDeploymentTarget target = miTarget(memory.operation.deploymentId);
    check miReady(memory, [target]);
    target.phase = types:FAILED; target.attempt = 1;
    target.startedAt = "2026-09-08T10:00:00Z"; target.finishedAt = "2026-09-08T10:00:02.500Z";
    target.durationMs = storage:miDeploymentDuration(target.startedAt, <string>target.finishedAt);
    target.reason = "UPLOAD_FAILED"; target.httpStatus = 503; target.message = "Runtime rejected upload";
    target.evidence = ["POST /management/applications returned 503"];
    check storage:saveMIDeploymentTarget(target);
    DeploymentMemory restored = check hydrateDeployment(memory.operation.deploymentId);
    test:assertEquals(restored.targets[0].projectName, "Historical project");
    test:assertEquals(restored.targets[0].durationMs, 2500);
    test:assertEquals(restored.targets[0].httpStatus, 503);
    test:assertEquals(restored.targets[0].evidence, target.evidence);
    test:assertEquals(restored.operation.selectedProjectIds, [HB_PROJECT_ID]);
    var events = check storage:listMIDeploymentEvents(memory.operation.deploymentId, target.targetId, 1, 1);
    test:assertEquals(events.total, 2);
    test:assertEquals(events.items.length(), 1);
    json httpStatus = check events.items[0].httpStatus;
    test:assertEquals(httpStatus, 503);
    var list = check storage:listMIDeploymentOperations("default", 100);
    test:assertTrue(list.items.length() > 0);
    var anotherOrg = check storage:listMIDeploymentOperations("not-this-org");
    test:assertEquals(anotherOrg.total, 0);
}

@test:Config {groups: ["mi-deployments"]}
function testMIDeploymentPreflightRollbackAndReplacement() returns error? {
    DeploymentMemory memory = check miFixture();
    types:MIDeploymentTarget original = miTarget(memory.operation.deploymentId);
    check miReady(memory, [original]);
    types:MIDeploymentTarget replacement = miTarget(memory.operation.deploymentId);
    error? failed = storage:replaceMIDeploymentTargets(memory.operation, [replacement, replacement.clone()]);
    test:assertTrue(failed is error, "Duplicate IDs must fail the entire transaction");
    var restored = check storage:loadMIDeploymentTargets(memory.operation.deploymentId);
    test:assertEquals(restored.length(), 1);
    test:assertEquals(restored[0].targetId, original.targetId);
    check storage:replaceMIDeploymentTargets(memory.operation, [replacement]);
    restored = check storage:loadMIDeploymentTargets(memory.operation.deploymentId);
    test:assertEquals(restored.length(), 1);
    test:assertEquals(restored[0].targetId, replacement.targetId);
    memory.operation.status = types:RUNNING; memory.operation.startedAt = now();
    check storage:beginMIDeployment(memory.operation);
    failed = storage:replaceMIDeploymentTargets(memory.operation, [original]);
    test:assertTrue(failed is error);
    failed = storage:deleteMIDeployment(memory.operation.deploymentId);
    test:assertTrue(failed is error, "Running history cannot be deleted");
    failed = storage:beginMIDeployment(memory.operation);
    test:assertTrue(failed is error, "Execution must be claimed only once");
}

@test:Config {groups: ["mi-deployments"]}
function testMIDeploymentSuccessAndSkippedTargets() returns error? {
    miMockState = "missing"; miMockUploadCode = 200; miMockAfterUpload = "active";
    DeploymentMemory memory = check miFixture();
    types:MIDeploymentTarget skipped = miTarget(memory.operation.deploymentId, "offline-runtime");
    skipped.eligible = false; skipped.phase = types:SKIPPED_INELIGIBLE;
    skipped.projectId = "another-project"; skipped.projectName = "Another project";
    check miReady(memory, [miTarget(memory.operation.deploymentId), skipped]);
    var finished = check miRun(memory);
    test:assertEquals(finished.operation.status, types:COMPLETED_WITH_ISSUES);
    test:assertTrue(finished.operation.durationMs is int);
    test:assertEquals(finished.targets.filter(t => t.phase == types:SUCCEEDED).length(), 1);
    test:assertTrue(miMockApplicationGets >= 3, "Active state must be observed across the stability window");
    test:assertEquals(finished.targets.filter(t => t.phase == types:SKIPPED_INELIGIBLE).length(), 1);
    test:assertEquals(finished.targets.filter(t => t.phase == types:SUCCEEDED)[0].attempt, 1);
}

@test:Config {groups: ["mi-deployments"]}
function testMIDeploymentWaitsForRemovalBeforeReplacement() returns error? {
    miMockState = "active"; miMockUploadCode = 200; miMockAfterUpload = "active";
    DeploymentMemory memory = check miFixture();
    types:MIDeploymentTarget target = miTarget(memory.operation.deploymentId);
    target.deleteBeforeUpload = true;
    check miReady(memory, [target]);
    int before = miMockUploads;
    var finished = check miRun(memory);
    test:assertEquals(finished.targets[0].phase, types:SUCCEEDED);
    test:assertEquals(miMockUploads, before + 1, "Replacement upload starts only after removal confirmation");
}

@test:Config {groups: ["mi-deployments"]}
function testMIDeploymentHttpFailureAndRetry() returns error? {
    miMockState = "missing"; miMockUploadCode = 503;
    DeploymentMemory memory = check miFixture();
    check miReady(memory, [miTarget(memory.operation.deploymentId)]);
    var finished = check miRun(memory);
    test:assertEquals(finished.targets[0].phase, types:FAILED);
    test:assertEquals(finished.targets[0].httpStatus, 503);
    test:assertTrue(finished.targets[0].durationMs is int);
    http:Response response = check miApi->post(string `/${memory.operation.deploymentId}/retry`, {targetIds: [finished.targets[0].targetId]}, {Authorization: createAuthHeader(adminToken)});
    test:assertEquals(response.statusCode, 200);
    json payload = check response.getJsonPayload();
    string retryId = check payload.id.ensureType();
    miTestOperations.push(retryId);
    var retryMemory = check hydrateDeployment(retryId);
    test:assertEquals(retryMemory.operation.parentDeploymentId, memory.operation.deploymentId);
    test:assertNotEquals(retryMemory.targets[0].targetId, finished.targets[0].targetId);
    test:assertEquals(retryMemory.targets[0].durationMs, ());
    var original = check hydrateDeployment(memory.operation.deploymentId);
    test:assertEquals(original.targets[0].phase, types:FAILED);
    check storage:deleteMIDeployment(memory.operation.deploymentId);
    retryMemory = check hydrateDeployment(retryId);
    test:assertTrue(retryMemory.content.length() > 0, "Deleting the parent must retain the shared artifact");
    miMockUploadCode = 200; miMockState = "missing"; miMockAfterUpload = "active";
    var succeeded = check miRun(retryMemory);
    test:assertEquals(succeeded.targets[0].attempt, 2);
    test:assertEquals(succeeded.targets[0].phase, types:SUCCEEDED);
}

@test:Config {groups: ["mi-deployments"]}
function testMIDeploymentFaultyAndConflict() returns error? {
    miMockState = "missing"; miMockUploadCode = 200; miMockAfterUpload = "faulty";
    DeploymentMemory memory = check miFixture();
    check miReady(memory, [miTarget(memory.operation.deploymentId)]);
    var faulty = check miRun(memory);
    test:assertEquals(faulty.targets[0].phase, types:FAULTY);
    test:assertTrue(faulty.targets[0].evidence.some(e => e.indexOf("simulated failure") >= 0));
    test:assertTrue(miMockFaultGets > 0);
    memory = check miFixture();
    check miReady(memory, [miTarget(memory.operation.deploymentId)]);
    int before = miMockUploads;
    var skipped = check miRun(memory);
    test:assertEquals(skipped.targets[0].phase, types:SKIPPED_CONFLICT);
    test:assertEquals(miMockUploads, before);
}

@test:Config {groups: ["mi-deployments"]}
function testMIDeploymentTimeoutRecheckPreservesDuration() returns error? {
    miMockState = "missing"; miMockUploadCode = 200; miMockAfterUpload = "missing";
    DeploymentMemory memory = check miFixture();
    check miReady(memory, [miTarget(memory.operation.deploymentId)]);
    var timedOut = check miRun(memory);
    test:assertEquals(timedOut.targets[0].phase, types:INDETERMINATE);
    test:assertEquals(timedOut.targets[0].reason, "VERIFICATION_TIMEOUT");
    int? elapsed = timedOut.targets[0].durationMs;
    miMockState = "active";
    http:Response response = check miApi->post(string `/${memory.operation.deploymentId}/recheck`, {targetId: timedOut.targets[0].targetId}, {Authorization: createAuthHeader(adminToken)});
    test:assertEquals(response.statusCode, 200);
    var restored = check hydrateDeployment(memory.operation.deploymentId);
    test:assertEquals(restored.targets[0].phase, types:SUCCEEDED);
    test:assertEquals(restored.targets[0].durationMs, elapsed);
    var events = check storage:listMIDeploymentEvents(memory.operation.deploymentId, restored.targets[0].targetId, 100);
    test:assertTrue(events.items.length() >= 5);
}

@test:Config {groups: ["mi-deployments"]}
function testMIDeploymentRestartAndCancellation() returns error? {
    DeploymentMemory memory = check miFixture();
    types:MIDeploymentTarget one = miTarget(memory.operation.deploymentId);
    types:MIDeploymentTarget two = miTarget(memory.operation.deploymentId, "second-runtime");
    check miReady(memory, [one, two]);
    memory.operation.status = types:RUNNING; memory.operation.startedAt = now();
    check storage:beginMIDeployment(memory.operation);
    one.phase = types:UPLOADING; one.startedAt = now();
    check storage:saveMIDeploymentTarget(one);
    check storage:cancelMIDeploymentTargets(memory.operation, two.targetId);
    check storage:recoverMIDeploymentLeases();
    var restored = check hydrateDeployment(memory.operation.deploymentId);
    test:assertEquals(restored.operation.status, types:COMPLETED_WITH_ISSUES);
    test:assertEquals(restored.targets.filter(t => t.phase == types:CANCELLED).length(), 1);
    var interrupted = restored.targets.filter(t => t.phase == types:INDETERMINATE);
    test:assertEquals(interrupted.length(), 1);
    test:assertEquals(interrupted[0].durationMs, ());
    test:assertEquals(interrupted[0].finishedAt, ());
    int before = miMockUploads;
    executeDeployment(memory.operation.deploymentId);
    test:assertEquals(miMockUploads, before, "Recovered targets must never be uploaded automatically");
}

@test:Config {groups: ["mi-deployments"]}
function testMIDeploymentApiScopeAndDetails() returns error? {
    DeploymentMemory memory = check miFixture();
    check miReady(memory, [miTarget(memory.operation.deploymentId)]);
    string path = string `/${memory.operation.deploymentId}`;
    http:Response response = check miApi->get(path + "?orgHandler=default", {Authorization: createAuthHeader(adminToken)});
    test:assertEquals(response.statusCode, 200);
    json payload = check response.getJsonPayload();
    json[] targets = check payload.targets.ensureType();
    test:assertEquals(targets.length(), 1);
    response = check miApi->get(path + "?orgHandler=another-org", {Authorization: createAuthHeader(adminToken)});
    test:assertEquals(response.statusCode, 404);
    response = check miApi->get(path + "/events?orgHandler=another-org", {Authorization: createAuthHeader(adminToken)});
    test:assertEquals(response.statusCode, 404);
    response = check miApi->get(path);
    test:assertEquals(response.statusCode, 401);
    response = check miApi->post(path + "/execute", {}, {Authorization: createAuthHeader(projectAdminToken)});
    test:assertEquals(response.statusCode, 403);
    response = check miApi->get("/missing-deployment?orgHandler=default", {Authorization: createAuthHeader(adminToken)});
    test:assertEquals(response.statusCode, 404);
}

@test:Config {groups: ["mi-deployments"]}
function testMIDeploymentPersistenceBoundaryStopsRuntimeMutation() returns error? {
    miMockState = "active"; miMockUploadCode = 200;
    DeploymentMemory memory = check miFixture();
    // This target deliberately does not exist in SQL. Its DELETE checkpoint must fail first.
    types:MIDeploymentTarget target = miTarget(memory.operation.deploymentId);
    target.deleteBeforeUpload = true;
    int before = miMockUploads;
    var result = uploadTarget(memory, target, memory.operation.deploymentId, 0);
    test:assertTrue(result is error);
    test:assertEquals(miMockUploads, before);
    test:assertEquals(miMockState, "active", "No DELETE may occur after a failed persistence boundary");
}

@test:Config {groups: ["mi-deployments"]}
function testMIDeploymentConnectionFailure() returns error? {
    string offlineId = "bd000000-0000-4000-8000-000000000002";
    types:Heartbeat heartbeat = buildHeartbeat(offlineId, "unreachable-history-test");
    heartbeat.runtimeType = "MI"; heartbeat.runtimeHostname = "127.0.0.1"; heartbeat.runtimePort = "19662";
    types:HeartbeatResponse _ = check storage:processHeartbeat(heartbeat, preResolved = true);
    int? split = miTestSecret.indexOf(".");
    if split is int { check storage:updateRuntimeKeyId(offlineId, miTestSecret.substring(0, split)); }
    DeploymentMemory memory = check miFixture();
    check miReady(memory, [miTarget(memory.operation.deploymentId, offlineId)]);
    var finished = check miRun(memory);
    test:assertEquals(finished.targets[0].phase, types:INDETERMINATE);
    test:assertTrue(finished.targets[0].message is string);
    test:assertTrue(finished.targets[0].durationMs is int);
    cleanupRuntime(offlineId);
}

@test:Config {groups: ["mi-deployments"]}
function testMIDeploymentCancellationSkipsQueuedRuntime() returns error? {
    miMockState = "missing"; miMockUploadCode = 200; miMockAfterUpload = "active";
    DeploymentMemory memory = check miFixture();
    types:MIDeploymentTarget target = miTarget(memory.operation.deploymentId);
    check miReady(memory, [target]);
    memory.operation.status = types:RUNNING; memory.operation.startedAt = now();
    check storage:beginMIDeployment(memory.operation);
    check storage:cancelMIDeploymentTargets(memory.operation, target.targetId);
    int before = miMockUploads;
    executeDeployment(memory.operation.deploymentId);
    var finished = check hydrateDeployment(memory.operation.deploymentId);
    test:assertEquals(finished.operation.status, types:CANCELLED);
    test:assertEquals(miMockUploads, before);
    test:assertEquals(finished.targets[0].startedAt, ());
}
