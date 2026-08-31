// Copyright (c) 2026, WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/io;
import ballerina/lang.runtime;
import ballerina/log;
import ballerina/sql;
import ballerina/time;
import icp_server.types as types;

// ── Audit action constants ─────────────────────────────────────────────────

// Authentication events
public const string AUDIT_LOGIN_SUCCESS = "LOGIN_SUCCESS";
public const string AUDIT_LOGIN_FAILURE = "LOGIN_FAILURE";
public const string AUDIT_LOGIN_LOCKED = "LOGIN_LOCKED";
public const string AUDIT_LOGOUT = "LOGOUT";
public const string AUDIT_LOGOUT_ALL = "LOGOUT_ALL";
public const string AUDIT_OIDC_LOGIN_SUCCESS = "OIDC_LOGIN_SUCCESS";
public const string AUDIT_OIDC_LOGIN_FAILURE = "OIDC_LOGIN_FAILURE";

// Password events
public const string AUDIT_PASSWORD_CHANGE = "PASSWORD_CHANGE";
public const string AUDIT_PASSWORD_RESET = "PASSWORD_RESET";
public const string AUDIT_PASSWORD_FORCED_CHANGE = "PASSWORD_FORCED_CHANGE";

// User management events
public const string AUDIT_USER_CREATE = "USER_CREATE";
public const string AUDIT_USER_DELETE = "USER_DELETE";
public const string AUDIT_USER_SESSIONS_REVOKE = "USER_SESSIONS_REVOKE";

// Group management events
public const string AUDIT_GROUP_CREATE = "GROUP_CREATE";
public const string AUDIT_GROUP_UPDATE = "GROUP_UPDATE";
public const string AUDIT_GROUP_DELETE = "GROUP_DELETE";
public const string AUDIT_GROUP_MEMBER_ADD = "GROUP_MEMBER_ADD";
public const string AUDIT_GROUP_MEMBER_REMOVE = "GROUP_MEMBER_REMOVE";
public const string AUDIT_USER_GROUPS_UPDATE = "USER_GROUPS_UPDATE";

// Role management events
public const string AUDIT_ROLE_CREATE = "ROLE_CREATE";
public const string AUDIT_ROLE_UPDATE = "ROLE_UPDATE";
public const string AUDIT_ROLE_DELETE = "ROLE_DELETE";
public const string AUDIT_ROLE_ASSIGNED = "ROLE_ASSIGNED";
public const string AUDIT_ROLE_UNASSIGNED = "ROLE_UNASSIGNED";

// Environment management events
public const string AUDIT_ENVIRONMENT_CREATE = "ENVIRONMENT_CREATE";
public const string AUDIT_ENVIRONMENT_UPDATE = "ENVIRONMENT_UPDATE";
public const string AUDIT_ENVIRONMENT_DELETE = "ENVIRONMENT_DELETE";

// Project management events
public const string AUDIT_PROJECT_CREATE = "PROJECT_CREATE";
public const string AUDIT_PROJECT_UPDATE = "PROJECT_UPDATE";
public const string AUDIT_PROJECT_DELETE = "PROJECT_DELETE";

// Component management events
public const string AUDIT_COMPONENT_CREATE = "COMPONENT_CREATE";
public const string AUDIT_COMPONENT_UPDATE = "COMPONENT_UPDATE";
public const string AUDIT_COMPONENT_DELETE = "COMPONENT_DELETE";

// Runtime management events
public const string AUDIT_RUNTIME_DELETE = "RUNTIME_DELETE";

// Artifact control events
public const string AUDIT_ARTIFACT_STATUS_CHANGE = "ARTIFACT_STATUS_CHANGE";
public const string AUDIT_ARTIFACT_TRACING_CHANGE = "ARTIFACT_TRACING_CHANGE";
public const string AUDIT_ARTIFACT_STATISTICS_CHANGE = "ARTIFACT_STATISTICS_CHANGE";
public const string AUDIT_ARTIFACT_TRIGGER = "ARTIFACT_TRIGGER";

// Logger / listener events
public const string AUDIT_LOG_LEVEL_CHANGE = "LOG_LEVEL_CHANGE";
public const string AUDIT_LOGGER_DELETE = "LOGGER_DELETE";
public const string AUDIT_LISTENER_STATE_CHANGE = "LISTENER_STATE_CHANGE";

// Secret events
public const string AUDIT_ORG_SECRET_CREATE = "ORG_SECRET_CREATE";
public const string AUDIT_ORG_SECRET_REVOKE = "ORG_SECRET_REVOKE";

// MI runtime user events
public const string AUDIT_MI_USER_CREATE = "MI_USER_CREATE";
public const string AUDIT_MI_USER_DELETE = "MI_USER_DELETE";
public const string AUDIT_REGISTRY_RESOURCE_CREATE = "REGISTRY_RESOURCE_CREATE";
public const string AUDIT_REGISTRY_RESOURCE_UPDATE = "REGISTRY_RESOURCE_UPDATE";
public const string AUDIT_REGISTRY_RESOURCE_DELETE = "REGISTRY_RESOURCE_DELETE";
public const string AUDIT_REGISTRY_PROPERTIES_UPDATE = "REGISTRY_PROPERTIES_UPDATE";
public const string AUDIT_COMPOSITE_APP_UPLOAD = "COMPOSITE_APP_UPLOAD";
public const string AUDIT_COMPOSITE_APP_DELETE = "COMPOSITE_APP_DELETE";
public const string AUDIT_SERVER_RESTART = "SERVER_RESTART";
public const string AUDIT_SERVER_RESTART_GRACEFULLY = "SERVER_RESTART_GRACEFULLY";
public const string AUDIT_SERVER_SHUTDOWN = "SERVER_SHUTDOWN";
public const string AUDIT_SERVER_SHUTDOWN_GRACEFULLY = "SERVER_SHUTDOWN_GRACEFULLY";

// ── Audit resource type constants ──────────────────────────────────────────

public const string AUDIT_RESOURCE_SESSION = "SESSION";
public const string AUDIT_RESOURCE_USER = "USER";
public const string AUDIT_RESOURCE_GROUP = "GROUP";
public const string AUDIT_RESOURCE_ROLE = "ROLE";
public const string AUDIT_RESOURCE_ENVIRONMENT = "ENVIRONMENT";
public const string AUDIT_RESOURCE_PROJECT = "PROJECT";
public const string AUDIT_RESOURCE_COMPONENT = "COMPONENT";
public const string AUDIT_RESOURCE_RUNTIME = "RUNTIME";
public const string AUDIT_RESOURCE_ARTIFACT = "ARTIFACT";
public const string AUDIT_RESOURCE_COMPOSITE_APP = "COMPOSITE_APP";
public const string AUDIT_RESOURCE_REGISTRY_RESOURCE = "REGISTRY_RESOURCE";
public const string AUDIT_RESOURCE_LOGGER = "LOGGER";
public const string AUDIT_RESOURCE_LISTENER = "LISTENER";
public const string AUDIT_RESOURCE_SECRET = "SECRET";

public isolated function getAuditLogs(types:AuditLogFilter filter = {}) returns types:AuditLog[]|error {
    string actor = filter.actor ?: "";
    string search = filter.search ?: "";
    string[] actions = filter.actions ?: [];
    string[] resourceTypes = filter.resourceTypes ?: [];
    sql:ParameterizedQuery query = `SELECT id, user_id, actor_username, action, event_source,
        resource_type, resource_id, details, client_ip, user_agent, timestamp
        FROM audit_logs WHERE event_source = 'CONTROL_PLANE' AND org_id = 1`;
    if actor.trim().length() > 0 {
        query = sql:queryConcat(query, ` AND UPPER(COALESCE(actor_username, '')) LIKE UPPER(${"%" + actor.trim() + "%"})`);
    }
    if actions.length() > 0 {
        sql:ParameterizedQuery values = `(`;
        foreach int i in 0 ..< actions.length() {
            if i > 0 { values = sql:queryConcat(values, `, `); }
            values = sql:queryConcat(values, `${actions[i]}`);
        }
        values = sql:queryConcat(values, `)`);
        query = sql:queryConcat(query, ` AND action IN `, values);
    }
    if resourceTypes.length() > 0 {
        sql:ParameterizedQuery values = `(`;
        foreach int i in 0 ..< resourceTypes.length() {
            if i > 0 { values = sql:queryConcat(values, `, `); }
            values = sql:queryConcat(values, `${resourceTypes[i]}`);
        }
        values = sql:queryConcat(values, `)`);
        query = sql:queryConcat(query, ` AND resource_type IN `, values);
    }
    if search.trim().length() > 0 {
        string term = "%" + search.trim() + "%";
        query = sql:queryConcat(query, ` AND (UPPER(COALESCE(actor_username, '')) LIKE UPPER(${term}) OR UPPER(COALESCE(details, '')) LIKE UPPER(${term}) OR UPPER(COALESCE(resource_id, '')) LIKE UPPER(${term}))`);
    }
    if filter.startTime is string {
        query = sql:queryConcat(query, ` AND timestamp >= ${filter.startTime}`);
    }
    if filter.endTime is string {
        query = sql:queryConcat(query, ` AND timestamp <= ${filter.endTime}`);
    }
    query = sql:queryConcat(query, ` ORDER BY timestamp DESC, id DESC`);
    stream<record {|int id; string? user_id; string? actor_username; string action; string event_source; string? resource_type; string? resource_id; string? details; string? client_ip; string? user_agent; string timestamp;|}, sql:Error?> rows = dbClient->query(query);
    types:AuditLog[] result = [];
    check from record {|int id; string? user_id; string? actor_username; string action; string event_source; string? resource_type; string? resource_id; string? details; string? client_ip; string? user_agent; string timestamp;|} row in rows do {
        result.push({id: row.id, actorUserId: row.user_id, actorUsername: row.actor_username,
            action: row.action, eventSource: row.event_source, resourceType: row.resource_type,
            resourceId: row.resource_id, details: row.details, clientIp: row.client_ip,
            userAgent: row.user_agent, timestamp: convertDbDateTimeToISO8601(row.timestamp)});
    };
    return result;
}

public isolated function cleanupAuditLogs(int retentionDays) returns error? {
    if retentionDays <= 0 {
        return;
    }
    // Compute the cutoff in the server and bind it as a timestamp value to keep
    // the statement portable across all supported database engines.
    time:Utc cutoff = time:utcAddSeconds(time:utcNow(), -retentionDays * 86400);
    time:Civil civil = time:utcToCivil(cutoff);
    string cutoffText = string `${civil.year}-${civil.month.toString().padStart(2, "0")}-${civil.day.toString().padStart(2, "0")}T${civil.hour.toString().padStart(2, "0")}:${civil.minute.toString().padStart(2, "0")}:00Z`;
    sql:ExecutionResult|sql:Error result = dbClient->execute(`DELETE FROM audit_logs WHERE event_source = 'CONTROL_PLANE' AND timestamp < ${cutoffText}`);
    if result is sql:Error {
        return result;
    }
}

// ── Module-level isolated state ────────────────────────────────────────────

isolated boolean auditEnabled = false;
// Set to true only while the file-drainer strand is running successfully.
// Prevents unbounded queue growth when file output is disabled or the file
// cannot be opened.
isolated boolean auditFileDraining = false;
type AuditEvent record {|
    string timestamp;
    string? orgId;
    string action;
    string? userId;
    string? actorUsername;
    string? resourceType;
    string? resourceId;
    string? details;
    string? clientIp;
    string? userAgent;
|} & readonly;
isolated AuditEvent[] pendingAuditEvents = [];

// ── Initialization ─────────────────────────────────────────────────────────

// Called from the non-isolated init() in init.bal.
// Starts a background strand that drains pending audit events to the database
// and optional audit log file.
public function initAuditLogging(boolean enabled, string filePath) {
    lock {
        auditEnabled = enabled;
    }

    if enabled {
        log:printInfo("Audit logging enabled",
                auditFile = filePath.length() > 0 ? filePath : "application log only");
    }

    if enabled {
        lock {
            auditFileDraining = true;
        }
        _ = start runAuditFileDrainer(filePath);
    }
}

// ── Core audit function ────────────────────────────────────────────────────

// Write a structured audit event to the application log and (when configured)
// enqueue a JSONL line for the background file-drainer. Isolated so it can be
// called from any isolated service resource.
public isolated function logAuditEvent(
        string action,
        string? userId = (),
        string? resourceType = (),
        string? resourceId = (),
        string? details = (),
        string? clientIp = (),
        string? userAgent = (),
        string? actorUsername = ()
) {
    boolean enabled;
    lock {
        enabled = auditEnabled;
    }
    if !enabled {
        return;
    }

    // Always emit to the application log with an AUDIT prefix so the event
    // is visible in any log aggregator / SIEM that reads the application log.
    log:printInfo("AUDIT",
            action = action,
            userId = userId ?: "",
            resourceType = resourceType ?: "",
            resourceId = resourceId ?: "",
            details = details ?: "",
            clientIp = clientIp ?: "");

    string timestamp = buildTimestamp();
    string? resolvedActor = actorUsername;
    if resolvedActor is () && userId is string {
        resolvedActor = getDisplayNameById(userId);
    }
    AuditEvent event = {
        timestamp: timestamp,
        action: action,
        orgId: "1",
        userId: userId,
        actorUsername: resolvedActor,
        resourceType: resourceType,
        resourceId: resourceId,
        details: details,
        clientIp: clientIp,
        userAgent: userAgent
    };

    // Enqueue for the background file-drainer only while it is active.
    boolean fileDraining;
    lock {
        fileDraining = auditFileDraining;
    }
    if fileDraining {
        lock {
            pendingAuditEvents.push(event);
        }
    }
}

// ── Background file drainer ────────────────────────────────────────────────

// Runs as a separate strand (started from initAuditLogging). Opens the audit
// log file once, then continuously drains pending audit events until the process
// exits. Uses a short sleep when the queue is empty to avoid busy-waiting.
function runAuditFileDrainer(string filePath) {
    io:WritableCharacterChannel? charChannel = ();
    if filePath.length() > 0 {
        io:WritableByteChannel|io:Error byteChannel = io:openWritableFile(filePath, option = io:APPEND);
        if byteChannel is io:Error {
            log:printError("Cannot open audit log file; file output disabled", byteChannel, filePath = filePath);
        } else {
            charChannel = new (byteChannel, "UTF-8");
        }
    }
    while true {
        AuditEvent? event = ();
        lock {
            if pendingAuditEvents.length() > 0 {
                event = pendingAuditEvents.remove(0);
            }
        }
        if event is AuditEvent {
            sql:ParameterizedQuery auditQuery = sql:queryConcat(`
                INSERT INTO audit_logs (org_id, event_source, user_id, actor_username, action,
                    resource_type, resource_id, details, client_ip, user_agent, timestamp)
                VALUES (${event.orgId}, 'CONTROL_PLANE', ${event.userId}, COALESCE(${event.actorUsername}, (SELECT username FROM users WHERE user_id = ${event.userId})), ${event.action},
                    ${event.resourceType}, ${event.resourceId}, ${event.details}, ${event.clientIp},
                    ${event.userAgent}, `, sql:queryConcat(sqlQueryFromString(timestampCast(event.timestamp)), `)`));
            sql:ExecutionResult|sql:Error result = dbClient->execute(auditQuery);
            if result is sql:Error {
                log:printError("Failed to persist audit entry to database", result, action = event.action);
            }
            if charChannel is io:WritableCharacterChannel {
                int|io:Error writeResult = charChannel.write(event.toJsonString() + "\n", 0);
                if writeResult is io:Error {
                    log:printError("Failed to write audit entry to log file", writeResult);
                }
            }
        } else {
            // Nothing queued — yield for 100 ms before checking again.
            runtime:sleep(0.1);
        }
    }
}

// ── Timestamp helper ───────────────────────────────────────────────────────

isolated function buildTimestamp() returns string {
    time:Utc utcNow = time:utcNow();
    time:Civil c = time:utcToCivil(utcNow);
    string month = c.month < 10 ? "0" + c.month.toString() : c.month.toString();
    string day = c.day < 10 ? "0" + c.day.toString() : c.day.toString();
    string hour = c.hour < 10 ? "0" + c.hour.toString() : c.hour.toString();
    string minute = c.minute < 10 ? "0" + c.minute.toString() : c.minute.toString();
    decimal second = c.second ?: 0d;
    int secondInt = <int>second;
    string secondStr = secondInt < 10 ? "0" + secondInt.toString() : secondInt.toString();
    return string `${c.year}-${month}-${day}T${hour}:${minute}:${secondStr}Z`;
}
