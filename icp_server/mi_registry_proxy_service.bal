// Copyright (c) 2026, WSO2 LLC. All Rights Reserved.
//
// Authenticated proxy for the WSO2 Integrator: MI Registry Management API.
// Registry writes are deliberately exposed as a runtime-scoped REST API so
// that text and binary resources can be forwarded without GraphQL encoding.

import icp_server.auth;
import icp_server.storage;
import icp_server.types;

import ballerina/http;
import ballerina/url;
import ballerina/log;

function miRegistryError(int statusCode, string message) returns http:Response {
    http:Response response = new;
    response.statusCode = statusCode;
    response.setJsonPayload({"error": {"message": message}});
    return response;
}

function isMutation(http:Request request) returns boolean {
    return request.method == http:POST || request.method == http:PUT || request.method == http:DELETE;
}

function registryPath(http:Request request) returns string|error {
    string? path = request.getQueryParamValue("path");
    if path is () {
        return error("path query parameter is required");
    }
    string trimmed = path.trim();
    // The Management API uses registry/config/... and registry/governance/...
    // paths. Reject traversal before forwarding the decoded query value.
    if trimmed == "" || trimmed.includes("..") || trimmed.includes("\\") ||
            !(trimmed.startsWith("registry/config/") || trimmed.startsWith("registry/governance/")) {
        return error("path must point to a resource below registry/config or registry/governance");
    }
    return trimmed;
}

function registryQuery(http:Request request, string operation, string path) returns string|error {
    string encodedPath = check url:encode(path, "UTF-8");
    string query = "?path=" + encodedPath;
    if operation == "content" && request.method == http:POST {
        string? mediaType = request.getQueryParamValue("mediaType");
        if mediaType is string && mediaType.trim() != "" {
            query += "&mediaType=" + check url:encode(mediaType.trim(), "UTF-8");
        }
    }
    if operation == "properties" && request.method == http:DELETE {
        string? propertyName = request.getQueryParamValue("name");
        if propertyName is string && propertyName.trim() != "" {
            query += "&name=" + check url:encode(propertyName.trim(), "UTF-8");
        }
    }
    return query;
}

function proxyMIRegistry(string componentId, string environmentId, string runtimeId,
        string registryOperation, http:Request request) returns http:Response {
    string|http:HeaderNotFoundError authHeader = request.getHeader("Authorization");
    if authHeader is http:HeaderNotFoundError {
        return miRegistryError(401, "Authorization header missing");
    }
    types:UserContextV2|error userContext = auth:extractUserContextV2(authHeader);
    if userContext is error {
        return miRegistryError(401, "Invalid token: " + userContext.message());
    }

    types:Runtime?|error runtimeResult = storage:getRuntimeById(runtimeId);
    if runtimeResult is error {
        return miRegistryError(500, "Failed to resolve MI runtime: " + runtimeResult.message());
    }
    types:Runtime? runtime = runtimeResult;
    if runtime is () || runtime.component.id != componentId || runtime.environment.id != environmentId ||
            runtime.runtimeType != types:MI {
        return miRegistryError(404, "MI runtime not found");
    }
    if runtime.status != types:RUNNING {
        return miRegistryError(409, "Registry operations require a running MI runtime");
    }

    types:AccessScope scope = auth:buildAccessScope(runtime.component.projectId, componentId, environmentId);
    boolean|error canView = auth:hasAnyPermission(userContext.userId,
            [auth:PERMISSION_INTEGRATION_VIEW, auth:PERMISSION_INTEGRATION_EDIT, auth:PERMISSION_INTEGRATION_MANAGE], scope);
    if canView is error {
        return miRegistryError(500, "Authorization check failed: " + canView.message());
    }
    if !canView {
        return miRegistryError(403, "Access denied");
    }
    if isMutation(request) {
        boolean|error canEdit = auth:hasAnyPermission(userContext.userId,
                [auth:PERMISSION_INTEGRATION_EDIT, auth:PERMISSION_INTEGRATION_MANAGE], scope);
        if canEdit is error {
            return miRegistryError(500, "Authorization check failed: " + canEdit.message());
        }
        if !canEdit {
            return miRegistryError(403, "Integration edit or manage permission required");
        }
    }

    string|error pathResult = registryPath(request);
    if pathResult is error {
        return miRegistryError(400, pathResult.message());
    }
    string path = pathResult;
    if registryOperation == "content" && request.method == http:POST {
        string? mediaType = request.getQueryParamValue("mediaType");
        if mediaType is () || mediaType.trim() == "" {
            return miRegistryError(400, "mediaType query parameter is required when creating a resource");
        }
    }
    if registryOperation == "properties" && request.method == http:POST {
        json|error payloadResult = request.getJsonPayload();
        if payloadResult is error || payloadResult !is json[] {
            return miRegistryError(400, "properties payload must be a JSON array");
        }
        foreach json property in payloadResult {
            if property !is map<json> {
                return miRegistryError(400, "each property must contain non-empty string name and value fields");
            }
            json? nameValue = property["name"];
            json? valueValue = property["value"];
            if nameValue !is string || nameValue.trim() == "" || valueValue !is string {
                return miRegistryError(400, "each property must contain non-empty string name and value fields");
            }
        }
        request.setJsonPayload(payloadResult);
    }

    string action = registryOperation == "properties" ? storage:AUDIT_REGISTRY_PROPERTIES_UPDATE :
        request.method == http:POST ? storage:AUDIT_REGISTRY_RESOURCE_CREATE :
        request.method == http:PUT ? storage:AUDIT_REGISTRY_RESOURCE_UPDATE : storage:AUDIT_REGISTRY_RESOURCE_DELETE;
    string auditContext = string `operation=${request.method}; componentId=${componentId}; environmentId=${environmentId}; runtimeId=${runtimeId}; path=${path}`;

    string|error baseUrlResult = storage:buildManagementBaseUrl(runtime.managementHostname, runtime.managementPort);
    if baseUrlResult is error {
        auditRestMutation(action, userContext.userId, userContext.username, request, storage:AUDIT_RESOURCE_REGISTRY_RESOURCE, path, auditContext, "FAILED");
        return miRegistryError(500, "Invalid MI management endpoint: " + baseUrlResult.message());
    }
    string baseUrl = baseUrlResult;
    http:Client|error clientResult = artifactsApiAllowInsecureTLS
            ? new (baseUrl, {secureSocket: {enable: false}})
            : new (baseUrl);
    if clientResult is error {
        auditRestMutation(action, userContext.userId, userContext.username, request, storage:AUDIT_RESOURCE_REGISTRY_RESOURCE, path, auditContext, "FAILED");
        return miRegistryError(502, "Failed to connect to MI management API: " + clientResult.message());
    }
    string|error hmacTokenResult = storage:issueRuntimeHmacToken(runtimeId);
    if hmacTokenResult is error {
        auditRestMutation(action, userContext.userId, userContext.username, request, storage:AUDIT_RESOURCE_REGISTRY_RESOURCE, path, auditContext, "FAILED");
        return miRegistryError(500, "Failed to create runtime authentication token: " + hmacTokenResult.message());
    }
    request.removeHeader("Authorization");
    request.setHeader("Authorization", "Bearer " + hmacTokenResult);
    // Keep the caller's Content-Type for text and binary payloads. MI uses it
    // to select the resource media type and to decode multipart uploads.
    request.setHeader("Accept", "application/json");
    string|error queryResult = registryQuery(request, registryOperation, path);
    if queryResult is error {
        return miRegistryError(400, "Invalid registry request: " + queryResult.message());
    }
    http:Response|error upstream = clientResult->forward(
        "/management/registry-resources/" + registryOperation + queryResult, request);
    if upstream is error {
        log:printError("MI Registry request failed", upstream, runtimeId = runtimeId, operation = registryOperation, path = path);
        auditRestMutation(action, userContext.userId, userContext.username, request, storage:AUDIT_RESOURCE_REGISTRY_RESOURCE, path, auditContext, "FAILED");
        return miRegistryError(502, "MI management API request failed: " + upstream.message());
    }

    if isMutation(request) {
        string outcome = upstream.statusCode >= 200 && upstream.statusCode < 300 ? "SUCCESS" : "FAILED";
        auditRestMutation(action, userContext.userId, userContext.username, request, storage:AUDIT_RESOURCE_REGISTRY_RESOURCE, path, auditContext, outcome, upstream.statusCode);
    }
    return upstream;
}

@http:ServiceConfig {
    auth: [{jwtValidatorConfig: {issuer: frontendJwtIssuer, audience: frontendJwtAudience,
        signatureConfig: {secret: resolvedFrontendJwtHMACSecret}}}],
    cors: {allowOrigins: normalizedCorsAllowedOrigins,
        allowHeaders: ["Content-Type", "Authorization"]}
}
service /icp/mi_registry on httpListener {
    resource function get [string componentId]/[string environmentId]/[string runtimeId]/content(
            http:Caller caller, http:Request request) returns error? {
        check caller->respond(proxyMIRegistry(componentId, environmentId, runtimeId, "content", request));
    }
    resource function post [string componentId]/[string environmentId]/[string runtimeId]/content(
            http:Caller caller, http:Request request) returns error? {
        check caller->respond(proxyMIRegistry(componentId, environmentId, runtimeId, "content", request));
    }
    resource function put [string componentId]/[string environmentId]/[string runtimeId]/content(
            http:Caller caller, http:Request request) returns error? {
        check caller->respond(proxyMIRegistry(componentId, environmentId, runtimeId, "content", request));
    }
    resource function delete [string componentId]/[string environmentId]/[string runtimeId]/content(
            http:Caller caller, http:Request request) returns error? {
        check caller->respond(proxyMIRegistry(componentId, environmentId, runtimeId, "content", request));
    }
    resource function post [string componentId]/[string environmentId]/[string runtimeId]/properties(
            http:Caller caller, http:Request request) returns error? {
        check caller->respond(proxyMIRegistry(componentId, environmentId, runtimeId, "properties", request));
    }
    resource function delete [string componentId]/[string environmentId]/[string runtimeId]/properties(
            http:Caller caller, http:Request request) returns error? {
        check caller->respond(proxyMIRegistry(componentId, environmentId, runtimeId, "properties", request));
    }
}
