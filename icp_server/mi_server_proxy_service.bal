// Copyright (c) 2026, WSO2 LLC. All Rights Reserved.

// Authenticated proxy for the MI Management API server resource.
import icp_server.auth;
import icp_server.storage;
import icp_server.types;

import ballerina/http;
import ballerina/log;

function miServerError(int statusCode, string message) returns http:Response {
    http:Response response = new;
    response.statusCode = statusCode;
    response.setJsonPayload({"error": {"message": message}});
    return response;
}

function isValidServerStatus(string status) returns boolean {
    return status == "shutdown" || status == "shutdownGracefully" || status == "restart" || status == "restartGracefully";
}

function proxyMIServer(string componentId, string environmentId, string runtimeId, http:Request request) returns http:Response {
    string|http:HeaderNotFoundError authHeader = request.getHeader("Authorization");
    if authHeader is http:HeaderNotFoundError {
        return miServerError(401, "Authorization header missing");
    }
    types:UserContextV2|error userContext = auth:extractUserContextV2(authHeader);
    if userContext is error {
        return miServerError(401, "Invalid token: " + userContext.message());
    }

    types:Runtime?|error runtimeResult = storage:getRuntimeById(runtimeId);
    if runtimeResult is error {
        return miServerError(500, "Failed to resolve MI runtime: " + runtimeResult.message());
    }
    types:Runtime? runtime = runtimeResult;
    if runtime is () || runtime.component.id != componentId || runtime.environment.id != environmentId || runtime.runtimeType != types:MI {
        return miServerError(404, "MI runtime not found");
    }

    types:AccessScope scope = auth:buildAccessScope(runtime.component.projectId, componentId, environmentId);
    boolean|error canView = auth:hasAnyPermission(userContext.userId,
        [auth:PERMISSION_INTEGRATION_VIEW, auth:PERMISSION_INTEGRATION_EDIT, auth:PERMISSION_INTEGRATION_MANAGE], scope);
    if canView is error {
        return miServerError(500, "Authorization check failed: " + canView.message());
    }
    if !canView {
        return miServerError(403, "Access denied");
    }
    if request.method == http:PATCH {
        boolean|error canManage = auth:hasAnyPermission(userContext.userId, [auth:PERMISSION_INTEGRATION_MANAGE], scope);
        if canManage is error {
            return miServerError(500, "Authorization check failed: " + canManage.message());
        }
        if !canManage {
            return miServerError(403, "Integration manage permission required");
        }
        if runtime.status != "RUNNING" {
            return miServerError(409, "Commands can only be sent to a running MI runtime");
        }
        json|error payloadResult = request.getJsonPayload();
        boolean validPayload = false;
        if payloadResult is map<json> {
            json? statusValue = payloadResult["status"];
            validPayload = statusValue is string && isValidServerStatus(statusValue);
        }
        if payloadResult is error || !validPayload {
            return miServerError(400, "status must be shutdown, shutdownGracefully, restart or restartGracefully");
        }
        request.setJsonPayload(payloadResult);
    }

    string|error baseUrlResult = storage:buildManagementBaseUrl(runtime.managementHostname, runtime.managementPort);
    if baseUrlResult is error {
        return miServerError(500, "Invalid MI management endpoint: " + baseUrlResult.message());
    }
    string baseUrl = baseUrlResult;
    http:Client|error clientResult = artifactsApiAllowInsecureTLS
        ? new (baseUrl, {secureSocket: {enable: false}}) : new (baseUrl);
    if clientResult is error {
        return miServerError(502, "Failed to connect to MI management API: " + clientResult.message());
    }
    string|error hmacTokenResult = storage:issueRuntimeHmacToken(runtimeId);
    if hmacTokenResult is error {
        return miServerError(500, "Failed to create runtime authentication token: " + hmacTokenResult.message());
    }
    request.removeHeader("Authorization");
    request.setHeader("Authorization", "Bearer " + hmacTokenResult);
    request.setHeader("Accept", "application/json");
    http:Response|error response = clientResult->forward("/management/server", request);
    if response is error {
        log:printError("MI server request failed", response, runtimeId = runtimeId);
        return miServerError(502, "MI management API request failed: " + response.message());
    }
    return response;
}

@http:ServiceConfig {
    auth: [{jwtValidatorConfig: {issuer: frontendJwtIssuer, audience: frontendJwtAudience,
        signatureConfig: {secret: resolvedFrontendJwtHMACSecret}}}],
    cors: {allowOrigins: normalizedCorsAllowedOrigins, allowHeaders: ["Content-Type", "Authorization"]}
}
service /icp/mi_server on httpListener {
    resource function get [string componentId]/[string environmentId]/[string runtimeId](http:Caller caller, http:Request request) returns error? {
        check caller->respond(proxyMIServer(componentId, environmentId, runtimeId, request));
    }
    resource function patch [string componentId]/[string environmentId]/[string runtimeId](http:Caller caller, http:Request request) returns error? {
        check caller->respond(proxyMIServer(componentId, environmentId, runtimeId, request));
    }
}
