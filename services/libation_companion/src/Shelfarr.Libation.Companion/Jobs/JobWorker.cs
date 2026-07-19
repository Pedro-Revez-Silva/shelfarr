using Shelfarr.Libation.Companion.Libation;

namespace Shelfarr.Libation.Companion.Jobs;

public sealed class JobWorker : BackgroundService
{
    private readonly CompanionOptions _options;
    private readonly JobStore _store;
    private readonly JobQueue _queue;
    private readonly CliCoordinator _coordinator;
    private readonly LibraryCache _library;
    private readonly OutputFileLocator _outputFiles;
    private readonly ILogger<JobWorker> _logger;

    public JobWorker(
        CompanionOptions options,
        JobStore store,
        JobQueue queue,
        CliCoordinator coordinator,
        LibraryCache library,
        OutputFileLocator outputFiles,
        ILogger<JobWorker> logger)
    {
        _options = options;
        _store = store;
        _queue = queue;
        _coordinator = coordinator;
        _library = library;
        _outputFiles = outputFiles;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await _store.RecoverInterruptedAsync(stoppingToken);
        _queue.RestoreQueued(_store.Queued());

        await foreach (var id in _queue.ReadAllAsync(stoppingToken))
        {
            var job = _store.Get(id);
            if (job is null || job.Status != CompanionJobStatus.Queued)
                continue;

            await _store.MarkRunningAsync(id, stoppingToken);
            try
            {
                var outputPaths = await ExecuteJobAsync(job, stoppingToken);
                await _store.MarkSucceededAsync(id, outputPaths, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception exception)
            {
                _logger.LogWarning("Companion {JobKind} job {JobId} failed", job.Kind, job.Id);
                await _store.MarkFailedAsync(id, SafeError(exception), stoppingToken);
            }
        }
    }

    private async Task<IReadOnlyList<string>?> ExecuteJobAsync(CompanionJob job, CancellationToken cancellationToken)
    {
        await using var lease = await _coordinator.AcquireAsync(cancellationToken);
        return job.Kind switch
        {
            CompanionJobKind.Sync => await SyncAsync(lease, cancellationToken),
            CompanionJobKind.Backup when job.Asin is not null => await BackupAsync(lease, job.Asin, cancellationToken),
            _ => throw new InvalidOperationException("The companion job has an invalid type or missing ASIN.")
        };
    }

    private async Task<IReadOnlyList<string>?> SyncAsync(
        CliCoordinator.CliLease lease,
        CancellationToken cancellationToken)
    {
        var scan = await lease.RunAsync(["scan"], _options.SyncTimeout, cancellationToken);
        if (scan.ExitCode != 0)
            throw new InvalidOperationException($"Libation library scan failed with exit code {scan.ExitCode}.");

        await _library.RefreshAsync(lease, cancellationToken);
        return null;
    }

    private async Task<IReadOnlyList<string>> BackupAsync(
        CliCoordinator.CliLease lease,
        string asin,
        CancellationToken cancellationToken)
    {
        var existingItem = await _library.RequirePurchasedActiveTitleAsync(asin, cancellationToken);
        var existingPaths = _outputFiles.FindForAsin(asin);
        if (OutputFileLocator.ContainsAudio(existingPaths))
        {
            if (existingItem.BookStatus.Equals("Liberated", StringComparison.OrdinalIgnoreCase))
                return existingPaths;

            var currentItem = await _library.RefreshItemAsync(lease, asin, cancellationToken);
            if (currentItem.BookStatus.Equals("Liberated", StringComparison.OrdinalIgnoreCase))
                return existingPaths;
        }

        var backup = await lease.RunAsync(["liberate", "--id", asin], _options.BackupTimeout, cancellationToken);
        if (BackupCliDiagnostics.Classify(backup) is { } failure)
        {
            _logger.LogWarning(
                "Libation backup CLI reported {FailureCode}",
                failure.Code);
            throw new InvalidOperationException(failure.Message);
        }

        var item = await _library.RefreshItemAsync(lease, asin, cancellationToken);
        if (!item.BookStatus.Equals("Liberated", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Libation did not mark the requested title as backed up.");

        var paths = _outputFiles.FindForAsin(asin);
        if (!OutputFileLocator.ContainsAudio(paths))
            throw new InvalidOperationException("Libation reported success, but no safe audiobook output was found.");
        return paths;
    }

    private static string SafeError(Exception exception) => exception switch
    {
        TimeoutException => exception.Message,
        InvalidOperationException => exception.Message,
        _ => "The companion could not complete this job."
    };
}
