// Session state as written by hooks/ccglance-hook.js — see docs/session-schema.md.
// Mirrors SessionState and friends in Sources/main.swift.
using System.Text.Json.Serialization;

namespace CcGlance;

public sealed class AgentTask
{
    [JsonPropertyName("id")] public string? Id { get; set; }
    [JsonPropertyName("description")] public string? Description { get; set; }
    [JsonPropertyName("type")] public string? Type { get; set; }
    [JsonPropertyName("startedAt")] public double? StartedAt { get; set; }
}

public sealed class BackgroundTask
{
    [JsonPropertyName("id")] public string? Id { get; set; }
    [JsonPropertyName("taskId")] public string? TaskId { get; set; }
    [JsonPropertyName("description")] public string? Description { get; set; }
    [JsonPropertyName("startedAt")] public double? StartedAt { get; set; }
    [JsonPropertyName("kind")] public string? Kind { get; set; }
}

public sealed class PRInfo
{
    [JsonPropertyName("number")] public int? Number { get; set; }
    [JsonPropertyName("state")] public string? State { get; set; }
    [JsonPropertyName("isDraft")] public bool? IsDraft { get; set; }
    [JsonPropertyName("mergeable")] public string? Mergeable { get; set; }
    [JsonPropertyName("url")] public string? Url { get; set; }
    [JsonPropertyName("checkedAt")] public double? CheckedAt { get; set; }
}

public sealed class HostInfo
{
    [JsonPropertyName("bundleId")] public string? BundleId { get; set; }
    [JsonPropertyName("termProgram")] public string? TermProgram { get; set; }
    [JsonPropertyName("itermSessionId")] public string? ItermSessionId { get; set; }
    [JsonPropertyName("tty")] public string? Tty { get; set; }
    [JsonPropertyName("wtSessionId")] public string? WtSessionId { get; set; }
    [JsonPropertyName("wtProfileId")] public string? WtProfileId { get; set; }
    [JsonPropertyName("winSessionName")] public string? WinSessionName { get; set; }
}

public sealed class SessionState
{
    [JsonPropertyName("sessionId"), JsonRequired] public string SessionId { get; set; } = "";
    [JsonPropertyName("project")] public string? Project { get; set; }
    [JsonPropertyName("title")] public string? Title { get; set; }
    [JsonPropertyName("cwd")] public string? Cwd { get; set; }
    [JsonPropertyName("status"), JsonRequired] public string Status { get; set; } = "idle";
    [JsonPropertyName("tool")] public string? Tool { get; set; }
    [JsonPropertyName("message")] public string? Message { get; set; }
    [JsonPropertyName("turnStartedAt")] public double? TurnStartedAt { get; set; }
    [JsonPropertyName("waitStartedAt")] public double? WaitStartedAt { get; set; }
    [JsonPropertyName("createdAt")] public double? CreatedAt { get; set; }
    // Required so a half-written or foreign file is skipped, never pruned as stale
    [JsonPropertyName("updatedAt"), JsonRequired] public double UpdatedAt { get; set; }
    [JsonPropertyName("agents")] public List<AgentTask>? Agents { get; set; }
    [JsonPropertyName("tasks")] public List<BackgroundTask>? Tasks { get; set; }
    [JsonPropertyName("pr")] public PRInfo? Pr { get; set; }
    [JsonPropertyName("prDismissed")] public List<string>? PrDismissed { get; set; }
    [JsonPropertyName("host")] public HostInfo? Host { get; set; }
    [JsonPropertyName("env")] public string? Env { get; set; }
    [JsonPropertyName("permissionMode")] public string? PermissionMode { get; set; }
    [JsonPropertyName("planApprovedAt")] public double? PlanApprovedAt { get; set; }

    public bool IsActive => Status != "idle";
    public bool IsWaiting => Status == "permission";
    public bool IsWorking => Status == "thinking" || Status == "tool";
}

[JsonSourceGenerationOptions(WriteIndented = false)]
[JsonSerializable(typeof(SessionState))]
[JsonSerializable(typeof(Settings))]
internal partial class JsonContext : JsonSerializerContext
{
}
