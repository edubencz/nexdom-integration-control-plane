// Copyright (c) 2026, WSO2 LLC. All Rights Reserved.

import icp_server.storage;

import ballerina/http;

// Records the outcome of an already authenticated and authorized REST mutation.
// The helper deliberately receives only safe metadata; request bodies and
// upstream response bodies are never copied into the audit record.
public isolated function auditRestMutation(
        string action,
        string userId,
        string actorUsername,
        http:Request request,
        string resourceType,
        string resourceId,
        string context,
        string outcome,
        int statusCode = 0) {
    string? clientIp = auditClientIp(request);
    string? userAgent = auditUserAgent(request);
    string details = string `${context}; outcome=${outcome}; status=${statusCode}`;
    storage:logAuditEvent(action, userId = userId, actorUsername = actorUsername, resourceType = resourceType,
        resourceId = resourceId, details = details, clientIp = clientIp,
        userAgent = userAgent);
}

isolated function auditClientIp(http:Request request) returns string? {
    string|http:HeaderNotFoundError forwarded = request.getHeader("X-Forwarded-For");
    if forwarded is string && forwarded.trim() != "" {
        return forwarded;
    }
    string|http:HeaderNotFoundError realIp = request.getHeader("X-Real-IP");
    return realIp is string && realIp.trim() != "" ? realIp : ();
}

isolated function auditUserAgent(http:Request request) returns string? {
    string|http:HeaderNotFoundError userAgent = request.getHeader("User-Agent");
    return userAgent is string && userAgent.trim() != "" ? userAgent : ();
}
