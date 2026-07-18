using Microsoft.Extensions.Logging.Abstractions;
using Shelfarr.Libation.Companion.Jobs;
using Shelfarr.Libation.Companion.Libation;

namespace Shelfarr.Libation.Companion.Tests;

public sealed class JobQueueTests
{
    [Fact]
    public async Task RequeuesAnExistingPersistedQueuedJob()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var store = new JobStore(options, NullLogger<JobStore>.Instance);
        var persisted = await store.CreateUniqueAsync(
            CompanionJobKind.Backup,
            "B012345678",
            CancellationToken.None);
        var queue = new JobQueue(store, options);

        var retried = await queue.EnqueueAsync(
            CompanionJobKind.Backup,
            "B012345678",
            CancellationToken.None);

        Assert.False(retried.Created);
        Assert.Equal(persisted.Job.Id, retried.Job.Id);
        await AssertNextJobAsync(queue, persisted.Job.Id);
    }

    [Fact]
    public async Task DoesNotScheduleDuplicatePendingWorkForTheSameQueuedJob()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var store = new JobStore(options, NullLogger<JobStore>.Instance);
        var queue = new JobQueue(store, options);

        var first = await queue.EnqueueAsync(
            CompanionJobKind.Backup,
            "B012345678",
            CancellationToken.None);
        var duplicate = await queue.EnqueueAsync(
            CompanionJobKind.Backup,
            "B012345678",
            CancellationToken.None);

        Assert.True(first.Created);
        Assert.False(duplicate.Created);
        Assert.Equal(first.Job.Id, duplicate.Job.Id);

        using var cancellation = new CancellationTokenSource();
        await using var reader = queue.ReadAllAsync(cancellation.Token).GetAsyncEnumerator();
        Assert.True(await reader.MoveNextAsync());
        Assert.Equal(first.Job.Id, reader.Current);

        var secondRead = reader.MoveNextAsync().AsTask();
        Assert.False(secondRead.IsCompleted);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => secondRead);
    }

    [Fact]
    public async Task RestoreQueuedDeduplicatesPendingJobIds()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var store = new JobStore(options, NullLogger<JobStore>.Instance);
        var persisted = await store.CreateUniqueAsync(
            CompanionJobKind.Sync,
            null,
            CancellationToken.None);
        var queue = new JobQueue(store, options);

        queue.RestoreQueued([persisted.Job, persisted.Job]);

        using var cancellation = new CancellationTokenSource();
        await using var reader = queue.ReadAllAsync(cancellation.Token).GetAsyncEnumerator();
        Assert.True(await reader.MoveNextAsync());
        Assert.Equal(persisted.Job.Id, reader.Current);

        var secondRead = reader.MoveNextAsync().AsTask();
        Assert.False(secondRead.IsCompleted);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => secondRead);
    }

    [Fact]
    public async Task BackupAdmissionRequiresACurrentPurchasedActiveCachedTitle()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var store = new JobStore(options, NullLogger<JobStore>.Instance);
        var queue = new JobQueue(store, options);

        await Assert.ThrowsAsync<BackupNotEligibleException>(() =>
            queue.EnqueueBackupAsync("B012345678", null, CancellationToken.None));
        await Assert.ThrowsAsync<BackupNotEligibleException>(() =>
            queue.EnqueueBackupAsync(
                "B012345678",
                Snapshot(Item("B012345678", "subscription", active: true)),
                CancellationToken.None));
        await Assert.ThrowsAsync<BackupNotEligibleException>(() =>
            queue.EnqueueBackupAsync(
                "B012345678",
                Snapshot(Item("B012345678", "purchased", active: false)),
                CancellationToken.None));
        await Assert.ThrowsAsync<BackupNotEligibleException>(() =>
            queue.EnqueueBackupAsync(
                "B012345678",
                Snapshot(Item("B087654321", "purchased", active: true)),
                CancellationToken.None));

        Assert.Empty(Directory.EnumerateFiles(options.JobsDirectory, "*.json"));

        var accepted = await queue.EnqueueBackupAsync(
            "B012345678",
            Snapshot(Item("B012345678", "purchased", active: true)),
            CancellationToken.None);
        Assert.True(accepted.Created);
    }

    private static async Task AssertNextJobAsync(JobQueue queue, string expectedId)
    {
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(1));
        await using var reader = queue.ReadAllAsync(cancellation.Token).GetAsyncEnumerator();

        Assert.True(await reader.MoveNextAsync());
        Assert.Equal(expectedId, reader.Current);
    }

    private static LibrarySnapshot Snapshot(params OwnedLibraryItem[] items)
        => new(1, DateTimeOffset.UtcNow, CompanionOptions.PinnedLibationVersion, 0, items);

    private static OwnedLibraryItem Item(string asin, string ownershipType, bool active) => new(
        asin,
        "us",
        "Example",
        "",
        ["An Author"],
        ["A Narrator"],
        3600,
        null,
        "",
        "en",
        "Product",
        ownershipType,
        active,
        false,
        false,
        "NotLiberated",
        null,
        DateTimeOffset.UtcNow,
        null,
        null,
        null,
        null);
}
