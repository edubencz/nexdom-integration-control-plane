// Copyright (c) 2026, WSO2 LLC. All Rights Reserved.

// Authenticated proxy for the Micro Integrator Carbon Applications Management API.
// The browser must not connect to the runtime directly: the ICP signs the outbound
// request with the runtime HMAC token and selects the runtime by its registered id.

import icp_server.auth;
import icp_server.storage;
import icp_server.types;

import ballerina/http;
import ballerina/url;
import ballerina/log;

function miApplicationsError(int statusCode, string message) returns http:Response {
    http:Response response = new;
    response.statusCode = statusCode;
    response.setJsonPayload({"error": {"message": message}});
    return response;
}

function proxyMIApplications(string componentId, string environmentId, string runtimeId,
        string[] appPath, http:Request request) returns http:Response {
    string|http:HeaderNotFoundError authHeader = request.getHeader("Authorization");
    if authHeader is http:HeaderNotFoundError {
        return miApplicationsError(401, "Authorization header missing");
    }
    types:UserContextV2|error userContext = auth:extractUserContextV2(authHeader);
    if userContext is error {
        return miApplicationsError(401, "Invalid token: " + userContext.message());
    }

    types:Runtime?|error runtimeResult = storage:getRuntimeById(runtimeId);
    if runtimeResult is error {
        return miApplicationsError(500, "Failed to resolve MI runtime: " + runtimeResult.message());
    }
    types:Runtime? runtime = runtimeResult;
    if runtime is () || runtime.component.id != componentId || runtime.environment.id != environmentId ||
            runtime.runtimeType != types:MI || runtime.status != "RUNNING" {
        return miApplicationsError(404, "MI runtime not found or is not running");
    }

    types:AccessScope scope = auth:buildAccessScope(runtime.component.projectId, componentId, environmentId);
    boolean|error permitted = auth:hasAnyPermission(userContext.userId,
            [auth:PERMISSION_INTEGRATION_VIEW, auth:PERMISSION_INTEGRATION_EDIT, auth:PERMISSION_INTEGRATION_MANAGE], scope);
    if permitted is error {
        return miApplicationsError(500, "Authorization check failed: " + permitted.message());
    }
    if !permitted {
        return miApplicationsError(403, "Access denied");
    }
    if request.method != http:GET {
        boolean|error canManage = auth:hasAnyPermission(userContext.userId,
                [auth:PERMISSION_INTEGRATION_EDIT, auth:PERMISSION_INTEGRATION_MANAGE], scope);
        if canManage is error || !canManage {
            return miApplicationsError(canManage is error ? 500 : 403, "Access denied");
        }
    }

    boolean auditMutation = request.method != http:GET;
    string? artifactName = ();
    if request.method == http:POST {
        string|http:HeaderNotFoundError artifactHeader = request.getHeader("X-ICP-Artifact-Name");
        artifactName = artifactHeader is string && artifactHeader.trim() != "" ? artifactHeader.trim() : ();
        request.removeHeader("X-ICP-Artifact-Name");
    }
    string action = request.method == http:POST ? storage:AUDIT_COMPOSITE_APP_UPLOAD : storage:AUDIT_COMPOSITE_APP_DELETE;
    string resourceId = request.method == http:POST ? (artifactName ?: "unknown") : (appPath.length() > 0 ? appPath[0] : "unknown");
    string auditContext = string `operation=${request.method}; componentId=${componentId}; environmentId=${environmentId}; runtimeId=${runtimeId}; target=${resourceId}`;

    string|error baseUrlResult = storage:buildManagementBaseUrl(runtime.managementHostname, runtime.managementPort);
    if baseUrlResult is error {
        if auditMutation { auditRestMutation(action, userContext.userId, userContext.username, request, storage:AUDIT_RESOURCE_COMPOSITE_APP, resourceId, auditContext, "FAILED"); }
        return miApplicationsError(500, "Invalid MI management endpoint: " + baseUrlResult.message());
    }
    string baseUrl = baseUrlResult;
    http:Client|error clientResult = artifactsApiAllowInsecureTLS
            ? new (baseUrl, {secureSocket: {enable: false}})
            : new (baseUrl);
    if clientResult is error {
        if auditMutation { auditRestMutation(action, userContext.userId, userContext.username, request, storage:AUDIT_RESOURCE_COMPOSITE_APP, resourceId, auditContext, "FAILED"); }
        return miApplicationsError(502, "Failed to connect to MI management API: " + clientResult.message());
    }
    string|error hmacTokenResult = storage:issueRuntimeHmacToken(runtimeId);
    if hmacTokenResult is error {
        if auditMutation { auditRestMutation(action, userContext.userId, userContext.username, request, storage:AUDIT_RESOURCE_COMPOSITE_APP, resourceId, auditContext, "FAILED"); }
        return miApplicationsError(500, "Failed to create runtime authentication token: " + hmacTokenResult.message());
    }
    string hmacToken = hmacTokenResult;
    request.removeHeader("Authorization");
    request.setHeader("Authorization", "Bearer " + hmacToken);
    request.setHeader("Accept", "application/json");

    string suffix = "";
    if appPath.length() > 0 {
        string|error encodedAppName = url:encode(appPath[0], "UTF-8");
        if encodedAppName is error {
            return miApplicationsError(400, "Invalid Carbon Application name");
        }
        suffix = "/" + encodedAppName;
    }
    http:Response|error response = clientResult->forward("/management/applications" + suffix, request);
    if response is error {
        log:printError("MI Carbon Applications request failed", response, runtimeId = runtimeId);
        if auditMutation { auditRestMutation(action, userContext.userId, userContext.username, request, storage:AUDIT_RESOURCE_COMPOSITE_APP, resourceId, auditContext, "FAILED"); }
        return miApplicationsError(502, "MI management API request failed: " + response.message());
    }
    string outcome = response.statusCode >= 200 && response.statusCode < 300 ? "SUCCESS" : "FAILED";
    if auditMutation { auditRestMutation(action, userContext.userId, userContext.username, request, storage:AUDIT_RESOURCE_COMPOSITE_APP, resourceId, auditContext, outcome, response.statusCode); }
    return response;
}

@http:ServiceConfig {
    auth: [{jwtValidatorConfig: {issuer: frontendJwtIssuer, audience: frontendJwtAudience,
        signatureConfig: {secret: resolvedFrontendJwtHMACSecret}}}],
    cors: {allowOrigins: normalizedCorsAllowedOrigins,
        allowHeaders: ["Content-Type", "Authorization", "X-ICP-Artifact-Name"]}
}
service /icp/mi_applications on httpListener {
    resource function get [string componentId]/[string environmentId]/[string runtimeId](http:Caller caller, http:Request request) returns error? {
        check caller->respond(proxyMIApplications(componentId, environmentId, runtimeId, [], request));
    }
    resource function post [string componentId]/[string environmentId]/[string runtimeId](http:Caller caller, http:Request request) returns error? {
        check caller->respond(proxyMIApplications(componentId, environmentId, runtimeId, [], request));
    }
    resource function delete [string componentId]/[string environmentId]/[string runtimeId]/[string appName](http:Caller caller, http:Request request) returns error? {
        check caller->respond(proxyMIApplications(componentId, environmentId, runtimeId, [appName], request));
    }
}
