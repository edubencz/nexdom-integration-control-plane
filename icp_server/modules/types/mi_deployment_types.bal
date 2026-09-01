// Durable organization-wide MI Carbon Application deployment contracts.
public enum MIDeploymentStatus {
    DRAFT,
    PREFLIGHT,
    AWAITING_DECISIONS,
    READY,
    RUNNING,
    CANCELLING,
    COMPLETED,
    COMPLETED_WITH_ISSUES,
    CANCELLED,
    FAILED
}

public enum MIDeploymentTargetPhase {
    QUEUED,
    VALIDATING,
    SKIPPED_CONFLICT,
    SKIPPED_INELIGIBLE,
    DELETING,
    VERIFYING_DELETE,
    UPLOADING,
    VERIFYING_DEPLOY,
    SUCCEEDED,
    FAULTY,
    FAILED,
    INDETERMINATE,
    STALE_PREFLIGHT,
    CANCELLED
}

public type MIDeploymentOperation record {| 
    string deploymentId;
    int orgId;
    string orgHandler;
    string artifactId;
    string artifactName;
    string artifactVersion;
    string fileName;
    int fileSize;
    string sha256;
    MIDeploymentStatus status;
    string createdBy;
    string createdAt;
    string updatedAt;
    string? parentDeploymentId = ();
|};

public type MIDeploymentTarget record {| 
    string targetId;
    string deploymentId;
    string projectId;
    string projectName;
    string componentId;
    string componentName;
    string environmentId;
    string environmentName;
    string runtimeId;
    string runtimeName;
    boolean production;
    boolean eligible;
    boolean conflictDetected;
    boolean deleteBeforeUpload;
    MIDeploymentTargetPhase phase;
    int attempt;
    string? reason = ();
    int? httpStatus = ();
    string? message = ();
    string[] evidence = [];
    string updatedAt;
|};

public type MIDeploymentEvent record {| 
    string eventId;
    string deploymentId;
    string? targetId = ();
    string phase;
    string message;
    string createdAt;
|};
