using System.Text.Json.Serialization;

namespace Shelfarr.Libation.Companion.Jobs;

[JsonConverter(typeof(JsonStringEnumConverter<CompanionJobKind>))]
public enum CompanionJobKind
{
    [JsonStringEnumMemberName("sync")] Sync,
    [JsonStringEnumMemberName("backup")] Backup
}

[JsonConverter(typeof(JsonStringEnumConverter<CompanionJobStatus>))]
public enum CompanionJobStatus
{
    [JsonStringEnumMemberName("queued")] Queued,
    [JsonStringEnumMemberName("running")] Running,
    [JsonStringEnumMemberName("succeeded")] Succeeded,
    [JsonStringEnumMemberName("failed")] Failed
}

public sealed record CompanionJob(
    string Id,
    CompanionJobKind Kind,
    CompanionJobStatus Status,
    DateTimeOffset CreatedAt,
    DateTimeOffset? StartedAt = null,
    DateTimeOffset? CompletedAt = null,
    string? Asin = null,
    string? Error = null,
    IReadOnlyList<string>? ArtifactPaths = null);

public sealed record EnqueueResult(CompanionJob Job, bool Created);

public sealed class JobCapacityExceededException(int maximumActiveJobs) : InvalidOperationException(
    $"The companion already has the configured maximum of {maximumActiveJobs} active jobs. Try again after queued work finishes.")
{
    public int MaximumActiveJobs { get; } = maximumActiveJobs;
}
