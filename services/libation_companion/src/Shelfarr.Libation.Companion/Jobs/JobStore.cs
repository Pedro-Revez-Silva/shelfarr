using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Serialization;
using Shelfarr.Libation.Companion.Libation;

namespace Shelfarr.Libation.Companion.Jobs;

public sealed class JobStore
{
    private const long MaximumJobRecordBytes = 1024 * 1024;
    private const int MaximumErrorCharacters = 2 * 1024;

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    private readonly CompanionOptions _options;
    private readonly ILogger<JobStore> _logger;
    private readonly ConcurrentDictionary<string, CompanionJob> _jobs = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim _writeGate = new(1, 1);

    public JobStore(CompanionOptions options, ILogger<JobStore> logger)
    {
        _options = options;
        _logger = logger;
        LoadExisting();
        PruneTerminalJobsWithoutLock();
    }

    public CompanionJob? Get(string id)
        => _jobs.TryGetValue(id, out var job) ? job : null;

    public IReadOnlyList<CompanionJob> Queued()
        => _jobs.Values
            .Where(job => job.Status == CompanionJobStatus.Queued)
            .OrderBy(job => job.CreatedAt)
            .ThenBy(job => job.Id, StringComparer.Ordinal)
            .ToArray();

    public async Task<EnqueueResult> CreateUniqueAsync(
        CompanionJobKind kind,
        string? asin,
        CancellationToken cancellationToken)
    {
        await _writeGate.WaitAsync(cancellationToken);
        try
        {
            var existing = _jobs.Values.FirstOrDefault(job =>
                job.Kind == kind
                && string.Equals(job.Asin, asin, StringComparison.Ordinal)
                && job.Status is CompanionJobStatus.Queued or CompanionJobStatus.Running);
            if (existing is not null)
                return new EnqueueResult(existing, false);

            if (_jobs.Values.Count(IsActive) >= _options.MaximumActiveJobs)
                throw new JobCapacityExceededException(_options.MaximumActiveJobs);

            var job = new CompanionJob(
                Guid.NewGuid().ToString("N"),
                kind,
                CompanionJobStatus.Queued,
                DateTimeOffset.UtcNow,
                Asin: asin);
            await PersistWithoutLockAsync(job, cancellationToken);
            _jobs[job.Id] = job;
            return new EnqueueResult(job, true);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    public Task<CompanionJob> MarkRunningAsync(string id, CancellationToken cancellationToken)
        => UpdateAsync(id, job => job with
        {
            Status = CompanionJobStatus.Running,
            StartedAt = DateTimeOffset.UtcNow,
            CompletedAt = null,
            Error = null,
            ArtifactPaths = null
        }, cancellationToken);

    public Task<CompanionJob> MarkSucceededAsync(
        string id,
        IReadOnlyList<string>? outputPaths,
        CancellationToken cancellationToken)
        => UpdateAsync(id, job => job with
        {
            Status = CompanionJobStatus.Succeeded,
            CompletedAt = DateTimeOffset.UtcNow,
            Error = null,
            ArtifactPaths = outputPaths
        }, cancellationToken, pruneTerminalJobs: true);

    public Task<CompanionJob> MarkFailedAsync(string id, string error, CancellationToken cancellationToken)
        => UpdateAsync(id, job => job with
        {
            Status = CompanionJobStatus.Failed,
            CompletedAt = DateTimeOffset.UtcNow,
            Error = BoundedError(error),
            ArtifactPaths = null
        }, cancellationToken, pruneTerminalJobs: true);

    public async Task RecoverInterruptedAsync(CancellationToken cancellationToken)
    {
        foreach (var running in _jobs.Values.Where(job => job.Status == CompanionJobStatus.Running).ToArray())
            await MarkFailedAsync(running.Id, "The companion restarted while this job was running.", cancellationToken);

        var excessQueued = _jobs.Values
            .Where(job => job.Status == CompanionJobStatus.Queued)
            .OrderBy(job => job.CreatedAt)
            .ThenBy(job => job.Id, StringComparer.Ordinal)
            .Skip(_options.MaximumActiveJobs)
            .ToArray();
        foreach (var queued in excessQueued)
        {
            await MarkFailedAsync(
                queued.Id,
                "The queued job was not resumed because the companion active-job limit was reduced.",
                cancellationToken);
        }
    }

    private async Task<CompanionJob> UpdateAsync(
        string id,
        Func<CompanionJob, CompanionJob> update,
        CancellationToken cancellationToken,
        bool pruneTerminalJobs = false)
    {
        await _writeGate.WaitAsync(cancellationToken);
        try
        {
            if (!_jobs.TryGetValue(id, out var current))
                throw new KeyNotFoundException($"Unknown companion job '{id}'.");

            var changed = update(current);
            await PersistWithoutLockAsync(changed, cancellationToken);
            _jobs[id] = changed;
            if (pruneTerminalJobs)
                PruneTerminalJobsWithoutLock();
            return changed;
        }
        finally
        {
            _writeGate.Release();
        }
    }

    private async Task PersistWithoutLockAsync(CompanionJob job, CancellationToken cancellationToken)
    {
        ValidateJobRecord(job);
        var destination = Path.Combine(_options.JobsDirectory, $"{job.Id}.json");
        var temporary = $"{destination}.{Guid.NewGuid():N}.tmp";
        try
        {
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                await JsonSerializer.SerializeAsync(stream, job, JsonOptions, cancellationToken);
                await stream.FlushAsync(cancellationToken);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, destination, overwrite: true);
        }
        finally
        {
            File.Delete(temporary);
        }
    }

    private void LoadExisting()
    {
        foreach (var file in Directory.EnumerateFiles(_options.JobsDirectory, "*.json", SearchOption.TopDirectoryOnly))
        {
            try
            {
                if (new FileInfo(file).Length > MaximumJobRecordBytes)
                    throw new InvalidDataException("Job record exceeded the safe size limit.");

                using var stream = File.OpenRead(file);
                var job = JsonSerializer.Deserialize<CompanionJob>(stream, JsonOptions)
                    ?? throw new InvalidDataException("Job record was empty.");
                ValidateJobRecord(job);
                if (!Path.GetFileNameWithoutExtension(file).Equals(job.Id, StringComparison.Ordinal))
                    throw new InvalidDataException("Job record identifier did not match its filename.");

                _jobs[job.Id] = job;
            }
            catch (Exception exception) when (
                exception is IOException or InvalidDataException or JsonException or UnauthorizedAccessException)
            {
                _logger.LogWarning(
                    "Ignored an unreadable companion job record {JobRecord}",
                    Path.GetFileName(file));
            }
        }
    }

    private static void ValidateJobRecord(CompanionJob job)
    {
        var validIdentity = !string.IsNullOrWhiteSpace(job.Id)
            && Guid.TryParseExact(job.Id, "N", out _);
        var validKind = Enum.IsDefined(job.Kind);
        var validStatus = Enum.IsDefined(job.Status);
        var validAsin = job.Kind switch
        {
            CompanionJobKind.Sync => job.Asin is null,
            CompanionJobKind.Backup => InputValidation.TryAsin(job.Asin, out _),
            _ => false
        };
        var validError = job.Error is null || job.Error.Length <= MaximumErrorCharacters;
        var validPaths = job.ArtifactPaths is null ||
            (job.ArtifactPaths.Count <= OutputFileLocator.MaximumOutputPaths &&
             job.ArtifactPaths.All(IsValidRelativeArtifactPath));
        if (!validIdentity || !validKind || !validStatus || !validAsin || !validError || !validPaths)
            throw new InvalidDataException("Companion job record failed validation.");
    }

    private static bool IsValidRelativeArtifactPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path)
            || path.Length > OutputFileLocator.MaximumRelativePathCharacters
            || Path.IsPathFullyQualified(path))
            return false;

        var normalized = path.Replace('\\', '/');
        return !normalized.Split('/').Any(segment => segment is "" or "." or "..");
    }

    private static string BoundedError(string error)
        => error.Length <= MaximumErrorCharacters ? error : error[..MaximumErrorCharacters];

    private void PruneTerminalJobsWithoutLock()
    {
        var cutoff = DateTimeOffset.UtcNow - _options.TerminalJobRetention;
        var terminalJobs = _jobs.Values
            .Where(job => !IsActive(job))
            .OrderByDescending(TerminalTimestamp)
            .ThenByDescending(job => job.CreatedAt)
            .ThenByDescending(job => job.Id, StringComparer.Ordinal)
            .ToArray();
        var expiredIds = terminalJobs
            .Where(job => TerminalTimestamp(job) < cutoff)
            .Select(job => job.Id);
        var excessIds = terminalJobs
            .Skip(_options.MaximumTerminalJobs)
            .Select(job => job.Id);

        foreach (var id in expiredIds.Concat(excessIds).Distinct(StringComparer.Ordinal))
        {
            try
            {
                File.Delete(Path.Combine(_options.JobsDirectory, $"{id}.json"));
                _jobs.TryRemove(id, out _);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                _logger.LogWarning("Could not prune terminal companion job {JobId}", id);
            }
        }
    }

    private static bool IsActive(CompanionJob job)
        => job.Status is CompanionJobStatus.Queued or CompanionJobStatus.Running;

    private static DateTimeOffset TerminalTimestamp(CompanionJob job)
        => job.CompletedAt ?? job.StartedAt ?? job.CreatedAt;
}
