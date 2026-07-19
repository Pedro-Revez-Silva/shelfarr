using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Threading.Channels;
using Shelfarr.Libation.Companion.Libation;

namespace Shelfarr.Libation.Companion.Jobs;

public sealed class JobQueue
{
    private readonly JobStore _store;
    private readonly ConcurrentDictionary<string, byte> _scheduled = new(StringComparer.Ordinal);
    private readonly Channel<string> _ids;

    public JobQueue(JobStore store, CompanionOptions options)
    {
        _store = store;
        _ids = Channel.CreateBounded<string>(new BoundedChannelOptions(options.MaximumActiveJobs)
        {
            SingleReader = true,
            SingleWriter = false,
            AllowSynchronousContinuations = false,
            FullMode = BoundedChannelFullMode.Wait
        });
    }

    public async Task<EnqueueResult> EnqueueAsync(
        CompanionJobKind kind,
        string? asin,
        CancellationToken cancellationToken)
    {
        var result = await _store.CreateUniqueAsync(kind, asin, cancellationToken);
        if (result.Job.Status == CompanionJobStatus.Queued)
            Schedule(result.Job.Id);
        return result;
    }

    public Task<EnqueueResult> EnqueueBackupAsync(
        string asin,
        LibrarySnapshot? library,
        CancellationToken cancellationToken)
    {
        _ = BackupEligibility.RequirePurchasedActiveTitle(library, asin);
        return EnqueueAsync(CompanionJobKind.Backup, asin, cancellationToken);
    }

    public async IAsyncEnumerable<string> ReadAllAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await foreach (var id in _ids.Reader.ReadAllAsync(cancellationToken))
        {
            try
            {
                yield return id;
            }
            finally
            {
                _scheduled.TryRemove(id, out _);
            }
        }
    }

    public void RestoreQueued(IEnumerable<CompanionJob> jobs)
    {
        foreach (var job in jobs)
            Schedule(job.Id);
    }

    private void Schedule(string id)
    {
        if (!_scheduled.TryAdd(id, 0))
            return;

        if (_ids.Writer.TryWrite(id))
            return;

        _scheduled.TryRemove(id, out _);
        throw new InvalidOperationException("The companion job queue is not accepting work.");
    }
}
