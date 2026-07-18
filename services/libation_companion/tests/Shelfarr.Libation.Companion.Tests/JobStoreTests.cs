using System.Text.Json;
using Microsoft.Extensions.Logging.Abstractions;
using Shelfarr.Libation.Companion.Jobs;

namespace Shelfarr.Libation.Companion.Tests;

public sealed class JobStoreTests
{
    [Fact]
    public async Task PersistsLowercaseContractAndDeduplicatesActiveBackups()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var store = new JobStore(options, NullLogger<JobStore>.Instance);

        var first = await store.CreateUniqueAsync(
            CompanionJobKind.Backup,
            "B012345678",
            CancellationToken.None);
        var duplicate = await store.CreateUniqueAsync(
            CompanionJobKind.Backup,
            "B012345678",
            CancellationToken.None);

        Assert.True(first.Created);
        Assert.False(duplicate.Created);
        Assert.Equal(first.Job.Id, duplicate.Job.Id);

        await store.MarkRunningAsync(first.Job.Id, CancellationToken.None);
        await store.MarkSucceededAsync(
            first.Job.Id,
            ["Example [B012345678]/Example [B012345678].m4b"],
            CancellationToken.None);

        var reloaded = new JobStore(options, NullLogger<JobStore>.Instance).Get(first.Job.Id);
        Assert.NotNull(reloaded);
        Assert.Equal(CompanionJobStatus.Succeeded, reloaded.Status);
        Assert.Equal(["Example [B012345678]/Example [B012345678].m4b"], reloaded.ArtifactPaths);

        using var json = JsonDocument.Parse(await File.ReadAllTextAsync(
            Path.Combine(options.JobsDirectory, $"{first.Job.Id}.json")));
        Assert.Equal("backup", json.RootElement.GetProperty("kind").GetString());
        Assert.Equal("succeeded", json.RootElement.GetProperty("status").GetString());
    }

    [Fact]
    public async Task BoundsActiveJobsButStillReturnsAnExistingDuplicate()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path) with { MaximumActiveJobs = 2 };
        options.EnsureDirectories();
        var store = new JobStore(options, NullLogger<JobStore>.Instance);

        var sync = await store.CreateUniqueAsync(CompanionJobKind.Sync, null, CancellationToken.None);
        var backup = await store.CreateUniqueAsync(
            CompanionJobKind.Backup,
            "B012345678",
            CancellationToken.None);
        var duplicate = await store.CreateUniqueAsync(
            CompanionJobKind.Backup,
            "B012345678",
            CancellationToken.None);

        Assert.False(duplicate.Created);
        Assert.Equal(backup.Job.Id, duplicate.Job.Id);
        var exception = await Assert.ThrowsAsync<JobCapacityExceededException>(() =>
            store.CreateUniqueAsync(CompanionJobKind.Backup, "B087654321", CancellationToken.None));
        Assert.Equal(2, exception.MaximumActiveJobs);
        Assert.Equal(2, Directory.EnumerateFiles(options.JobsDirectory, "*.json").Count());

        await store.MarkSucceededAsync(sync.Job.Id, null, CancellationToken.None);
        var replacement = await store.CreateUniqueAsync(
            CompanionJobKind.Backup,
            "B087654321",
            CancellationToken.None);
        Assert.True(replacement.Created);
    }

    [Fact]
    public async Task PrunesOldestTerminalJobsByCountAndKeepsActiveJobs()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path) with { MaximumTerminalJobs = 2 };
        options.EnsureDirectories();
        var store = new JobStore(options, NullLogger<JobStore>.Instance);
        var terminalIds = new List<string>();

        foreach (var asin in new[] { "B012345678", "B012345679", "B012345680" })
        {
            var queued = await store.CreateUniqueAsync(
                CompanionJobKind.Backup,
                asin,
                CancellationToken.None);
            terminalIds.Add(queued.Job.Id);
            await store.MarkSucceededAsync(queued.Job.Id, null, CancellationToken.None);
        }
        var active = await store.CreateUniqueAsync(
            CompanionJobKind.Backup,
            "B012345681",
            CancellationToken.None);

        Assert.Null(store.Get(terminalIds[0]));
        Assert.False(File.Exists(Path.Combine(options.JobsDirectory, $"{terminalIds[0]}.json")));
        Assert.NotNull(store.Get(terminalIds[1]));
        Assert.NotNull(store.Get(terminalIds[2]));
        Assert.NotNull(store.Get(active.Job.Id));

        var reloaded = new JobStore(options, NullLogger<JobStore>.Instance);
        Assert.Null(reloaded.Get(terminalIds[0]));
        Assert.NotNull(reloaded.Get(active.Job.Id));
    }

    [Fact]
    public async Task PrunesExpiredTerminalJobsOnStartupWithoutDeletingQueuedWork()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var store = new JobStore(options, NullLogger<JobStore>.Instance);
        var completed = await store.CreateUniqueAsync(
            CompanionJobKind.Backup,
            "B012345678",
            CancellationToken.None);
        await store.MarkFailedAsync(completed.Job.Id, "Expected test failure.", CancellationToken.None);
        var queued = await store.CreateUniqueAsync(
            CompanionJobKind.Backup,
            "B087654321",
            CancellationToken.None);

        var reloaded = new JobStore(
            options with { TerminalJobRetention = TimeSpan.Zero },
            NullLogger<JobStore>.Instance);

        Assert.Null(reloaded.Get(completed.Job.Id));
        Assert.False(File.Exists(Path.Combine(options.JobsDirectory, $"{completed.Job.Id}.json")));
        Assert.Equal(CompanionJobStatus.Queued, reloaded.Get(queued.Job.Id)?.Status);
    }

    [Fact]
    public async Task RestartRetainsOldestQueuedWorkWithinANewLowerLimit()
    {
        using var temporary = new TemporaryDirectory();
        var originalOptions = TestOptions.Create(temporary.Path) with { MaximumActiveJobs = 3 };
        originalOptions.EnsureDirectories();
        var original = new JobStore(originalOptions, NullLogger<JobStore>.Instance);
        var jobs = new List<CompanionJob>();
        foreach (var asin in new[] { "B012345678", "B012345679", "B012345680" })
        {
            var created = await original.CreateUniqueAsync(
                CompanionJobKind.Backup,
                asin,
                CancellationToken.None);
            jobs.Add(created.Job);
            await Task.Delay(2);
        }

        var reducedOptions = originalOptions with { MaximumActiveJobs = 2 };
        var reloaded = new JobStore(reducedOptions, NullLogger<JobStore>.Instance);
        await reloaded.RecoverInterruptedAsync(CancellationToken.None);

        Assert.Equal(CompanionJobStatus.Queued, reloaded.Get(jobs[0].Id)?.Status);
        Assert.Equal(CompanionJobStatus.Queued, reloaded.Get(jobs[1].Id)?.Status);
        var excess = reloaded.Get(jobs[2].Id);
        Assert.Equal(CompanionJobStatus.Failed, excess?.Status);
        Assert.Contains("active-job limit was reduced", excess?.Error, StringComparison.OrdinalIgnoreCase);

        var queue = new JobQueue(reloaded, reducedOptions);
        queue.RestoreQueued(reloaded.Queued());
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(1));
        await using var reader = queue.ReadAllAsync(cancellation.Token).GetAsyncEnumerator();
        Assert.True(await reader.MoveNextAsync());
        Assert.Equal(jobs[0].Id, reader.Current);
        Assert.True(await reader.MoveNextAsync());
        Assert.Equal(jobs[1].Id, reader.Current);
    }

    [Fact]
    public void StartupIgnoresAJobRecordThatExceedsTheFileBudget()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var id = Guid.NewGuid().ToString("N");
        var path = Path.Combine(options.JobsDirectory, $"{id}.json");
        using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            stream.SetLength(1024 * 1024 + 1);

        var store = new JobStore(options, NullLogger<JobStore>.Instance);

        Assert.Null(store.Get(id));
    }

    [Fact]
    public async Task StartupIgnoresAJobRecordWithTooManyArtifactPaths()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var original = new JobStore(options, NullLogger<JobStore>.Instance);
        var created = await original.CreateUniqueAsync(
            CompanionJobKind.Backup,
            "B012345678",
            CancellationToken.None);
        var corrupted = created.Job with
        {
            Status = CompanionJobStatus.Succeeded,
            ArtifactPaths = Enumerable.Range(0, Libation.OutputFileLocator.MaximumOutputPaths + 1)
                .Select(index => $"chapter-{index:D3}.mp3")
                .ToArray()
        };
        await File.WriteAllTextAsync(
            Path.Combine(options.JobsDirectory, $"{created.Job.Id}.json"),
            JsonSerializer.Serialize(corrupted));

        var reloaded = new JobStore(options, NullLogger<JobStore>.Instance);

        Assert.Null(reloaded.Get(created.Job.Id));
    }

    [Fact]
    public async Task FailureDetailIsBoundedBeforeItIsPersisted()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var store = new JobStore(options, NullLogger<JobStore>.Instance);
        var created = await store.CreateUniqueAsync(
            CompanionJobKind.Backup,
            "B012345678",
            CancellationToken.None);

        var failed = await store.MarkFailedAsync(
            created.Job.Id,
            new string('x', 10_000),
            CancellationToken.None);

        Assert.NotNull(failed.Error);
        Assert.Equal(2 * 1024, failed.Error.Length);
        Assert.Equal(2 * 1024, new JobStore(options, NullLogger<JobStore>.Instance)
            .Get(created.Job.Id)?.Error?.Length);
    }
}
