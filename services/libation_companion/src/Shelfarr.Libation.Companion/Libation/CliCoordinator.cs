using System.Diagnostics;
using System.Text;

namespace Shelfarr.Libation.Companion.Libation;

public sealed record CliResult(int ExitCode, string StandardOutput, string StandardError);

public sealed class CliCoordinator
{
    private const int MaximumCapturedCharacters = 256 * 1024;
    private readonly CompanionOptions _options;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public CliCoordinator(CompanionOptions options) => _options = options;

    public bool IsBusy => _gate.CurrentCount == 0;

    public async ValueTask<CliLease> AcquireAsync(CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        return new CliLease(this);
    }

    public async ValueTask<CliLease?> TryAcquireAsync(CancellationToken cancellationToken)
    {
        return await _gate.WaitAsync(TimeSpan.Zero, cancellationToken)
            ? new CliLease(this)
            : null;
    }

    public async Task<CliResult> RunAsync(
        IReadOnlyCollection<string> arguments,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        await using var lease = await AcquireAsync(cancellationToken);
        return await lease.RunAsync(arguments, timeout, cancellationToken);
    }

    private async Task<CliResult> RunCoreAsync(
        IReadOnlyCollection<string> arguments,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        using var process = new Process { StartInfo = CreateStartInfo(arguments) };
        if (!process.Start())
            throw new InvalidOperationException("Libation CLI could not be started.");

        var stdoutTask = CaptureAsync(process.StandardOutput, cancellationToken);
        var stderrTask = CaptureAsync(process.StandardError, cancellationToken);
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);

        try
        {
            await process.WaitForExitAsync(timeoutSource.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            Kill(process);
            await ObserveAsync(stdoutTask, stderrTask);
            throw new TimeoutException($"Libation CLI exceeded its {timeout.TotalMinutes:0.#}-minute timeout.");
        }
        catch
        {
            Kill(process);
            await ObserveAsync(stdoutTask, stderrTask);
            throw;
        }

        return new CliResult(
            process.ExitCode,
            await stdoutTask,
            await stderrTask);
    }

    private ProcessStartInfo CreateStartInfo(IReadOnlyCollection<string> arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = _options.LibationCliPath,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = false,
            CreateNoWindow = true
        };

        foreach (var argument in arguments)
            startInfo.ArgumentList.Add(argument);
        AddCommonOverrides(startInfo.ArgumentList);
        ApplyEnvironment(startInfo);
        return startInfo;
    }

    internal void ApplyEnvironment(ProcessStartInfo startInfo)
    {
        startInfo.Environment["LIBATION_FILES_DIR"] = _options.LibationFilesDirectory;
        startInfo.Environment["LIBATION_BOOKS_DIR"] = _options.BooksDirectory;
        startInfo.Environment["LIBATION_IN_PROGRESS_DIR"] = _options.InProgressDirectory;
    }

    internal void AddCommonOverrides(ICollection<string> arguments)
    {
        arguments.Add("--override");
        arguments.Add($"Books={_options.BooksDirectory}");
        arguments.Add("--override");
        arguments.Add($"InProgress={_options.InProgressDirectory}");
        arguments.Add("--override");
        arguments.Add("FolderTemplate=<title short> [<id>]");
        arguments.Add("--override");
        arguments.Add("FileTemplate=<title> [<id>]");
        arguments.Add("--override");
        arguments.Add("ChapterFileTemplate=<title> [<id>] - <ch# 0> - <ch title>");
        arguments.Add("--override");
        arguments.Add("SplitFilesByChapter=false");
        arguments.Add("--override");
        arguments.Add("DecryptToLossy=false");
        arguments.Add("--override");
        arguments.Add("ImportEpisodes=false");
        arguments.Add("--override");
        arguments.Add("DownloadEpisodes=false");
    }

    internal void Release() => _gate.Release();

    private static async Task<string> CaptureAsync(StreamReader reader, CancellationToken cancellationToken)
    {
        var buffer = new char[4096];
        var captured = new StringBuilder(Math.Min(MaximumCapturedCharacters, 16 * 1024));
        while (true)
        {
            var read = await reader.ReadAsync(buffer.AsMemory(), cancellationToken);
            if (read == 0)
                break;

            var remaining = MaximumCapturedCharacters - captured.Length;
            if (remaining > 0)
                captured.Append(buffer, 0, Math.Min(read, remaining));
        }

        return captured.ToString();
    }

    internal static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited)
                process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException)
        {
            // The process exited between the check and the kill.
        }
    }

    private static async Task ObserveAsync(params Task<string>[] tasks)
    {
        try
        {
            await Task.WhenAll(tasks);
        }
        catch (OperationCanceledException)
        {
            // The caller's cancellation token also owns the output readers.
        }
        catch (IOException)
        {
            // Killing a process may close its redirected pipes mid-read.
        }
    }

    public sealed class CliLease : IAsyncDisposable
    {
        private CliCoordinator? _owner;

        internal CliLease(CliCoordinator owner) => _owner = owner;

        public Task<CliResult> RunAsync(
            IReadOnlyCollection<string> arguments,
            TimeSpan timeout,
            CancellationToken cancellationToken)
        {
            var owner = _owner ?? throw new ObjectDisposedException(nameof(CliLease));
            return owner.RunCoreAsync(arguments, timeout, cancellationToken);
        }

        public ValueTask DisposeAsync()
        {
            Interlocked.Exchange(ref _owner, null)?.Release();
            return ValueTask.CompletedTask;
        }
    }
}
