using System.Diagnostics;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Shelfarr.Libation.Companion.Jobs;
using Shelfarr.Libation.Companion.Libation;

namespace Shelfarr.Libation.Companion.Tests;

public sealed class JobWorkerTests
{
    private const string Asin = "B012345678";

    [Fact]
    public async Task ReusesSafeAudioForAnAlreadyLiberatedPurchasedTitle()
    {
        if (OperatingSystem.IsWindows())
            return;

        using var temporary = new TemporaryDirectory();
        var (options, invocationMarker) = CreateOptionsWithFailingCli(temporary.Path);
        await WriteLibraryAsync(options, "Liberated");
        var expectedPath = CreateAudioArtifact(options);

        var completed = await RunBackupAsync(options);

        Assert.Equal(CompanionJobStatus.Succeeded, completed.Status);
        Assert.Equal([expectedPath], completed.ArtifactPaths);
        Assert.False(File.Exists(invocationMarker));
    }

    [Theory]
    [InlineData("NotLiberated", true)]
    [InlineData("Liberated", false)]
    public async Task InvokesLibationUnlessBothCatalogStatusAndSafeAudioConfirmBackup(
        string bookStatus,
        bool createAudio)
    {
        if (OperatingSystem.IsWindows())
            return;

        using var temporary = new TemporaryDirectory();
        var (options, invocationMarker) = CreateOptionsWithFailingCli(temporary.Path);
        await WriteLibraryAsync(options, bookStatus);
        if (createAudio)
            CreateAudioArtifact(options);

        var completed = await RunBackupAsync(options);

        Assert.Equal(CompanionJobStatus.Failed, completed.Status);
        Assert.True(File.Exists(invocationMarker));
    }

    [Fact]
    public async Task PreservesAnExitZeroPerTitleFailureInsteadOfReplacingItWithPostCheckError()
    {
        if (OperatingSystem.IsWindows())
            return;

        using var temporary = new TemporaryDirectory();
        var options = CreateOptionsWithCli(
            temporary.Path,
            "#!/bin/sh\nprintf 'Decrypt failed\\n' >&2\nexit 0\n");
        await WriteLibraryAsync(options, "NotLiberated");

        var completed = await RunBackupAsync(options);

        Assert.Equal(CompanionJobStatus.Failed, completed.Status);
        Assert.Equal(
            "Libation obtained the title license but could not download or decrypt its audio.",
            completed.Error);
    }

    [Fact]
    public async Task BackupFailureWarningsDoNotLogTheOwnedTitleAsin()
    {
        if (OperatingSystem.IsWindows())
            return;

        using var temporary = new TemporaryDirectory();
        var options = CreateOptionsWithCli(
            temporary.Path,
            "#!/bin/sh\nprintf 'Decrypt failed\\n' >&2\nexit 0\n");
        await WriteLibraryAsync(options, "NotLiberated");
        var logger = new CollectingLogger<JobWorker>();

        var completed = await RunBackupAsync(options, logger);

        Assert.Equal(CompanionJobStatus.Failed, completed.Status);
        Assert.NotEmpty(logger.Messages);
        Assert.DoesNotContain(logger.Messages, message => message.Contains(Asin, StringComparison.Ordinal));
    }

    [Fact]
    public async Task SuccessfulBackupValidatesWithAnAsinScopedExport()
    {
        if (OperatingSystem.IsWindows())
            return;

        using var temporary = new TemporaryDirectory();
        var marker = Path.Combine(temporary.Path, "commands.txt");
        var options = TestOptions.Create(temporary.Path);
        var folder = Path.Combine(options.BooksDirectory, $"Example [{Asin}]");
        var artifact = Path.Combine(folder, $"Example [{Asin}].m4b");
        var cliPath = Path.Combine(temporary.Path, "libation-cli-test");
        File.WriteAllText(cliPath, $$"""
        #!/bin/sh
        printf '%s\n' "$*" >> {{ShellQuote(marker)}}
        case "$1" in
          liberate)
            mkdir -p {{ShellQuote(folder)}}
            printf 'audio' > {{ShellQuote(artifact)}}
            ;;
          export)
            output=''
            previous=''
            for argument in "$@"; do
              if [ "$previous" = '--path' ]; then output="$argument"; fi
              previous="$argument"
            done
            cat > "$output" <<'JSON'
        [{"AudibleProductId":"B012345678","ContentType":"Product","Title":"Example","BookStatus":"Liberated"}]
        JSON
            ;;
          *) exit 42 ;;
        esac
        """);
        File.SetUnixFileMode(
            cliPath,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        options = options with { LibationCliPath = cliPath };
        options.EnsureDirectories();
        await WriteLibraryAsync(options, "NotLiberated");

        var completed = await RunBackupAsync(options);

        Assert.Equal(CompanionJobStatus.Succeeded, completed.Status);
        var commands = await File.ReadAllLinesAsync(marker);
        Assert.Equal(2, commands.Length);
        Assert.StartsWith($"liberate --id {Asin} ", commands[0]);
        Assert.Contains($"--json {Asin} ", commands[1]);
    }

    private static (CompanionOptions Options, string InvocationMarker) CreateOptionsWithFailingCli(string root)
    {
        if (OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("The test CLI fixture requires a POSIX shell.");

        var cliPath = Path.Combine(root, "libation-cli-test");
        var invocationMarker = $"{cliPath}.invoked";
        var options = CreateOptionsWithCli(
            root,
            "#!/bin/sh\n: > \"$0.invoked\"\nexit 42\n");
        return (options, invocationMarker);
    }

    private static CompanionOptions CreateOptionsWithCli(string root, string script)
    {
        if (OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("The test CLI fixture requires a POSIX shell.");

        var cliPath = Path.Combine(root, "libation-cli-test");
        File.WriteAllText(cliPath, script);
        File.SetUnixFileMode(
            cliPath,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);

        var options = TestOptions.Create(root) with { LibationCliPath = cliPath };
        options.EnsureDirectories();
        return options;
    }

    private static async Task WriteLibraryAsync(CompanionOptions options, string bookStatus)
    {
        var item = new OwnedLibraryItem(
            Asin,
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
            "purchased",
            true,
            bookStatus.Equals("Liberated", StringComparison.OrdinalIgnoreCase),
            false,
            bookStatus,
            null,
            DateTimeOffset.UtcNow,
            null,
            null,
            null,
            null);
        var snapshot = new LibrarySnapshot(
            1,
            DateTimeOffset.UtcNow,
            CompanionOptions.PinnedLibationVersion,
            0,
            [item]);

        await File.WriteAllTextAsync(
            options.LibraryFile,
            JsonSerializer.Serialize(snapshot, new JsonSerializerOptions(JsonSerializerDefaults.Web)));
    }

    private static string CreateAudioArtifact(CompanionOptions options)
    {
        var folderName = $"Example [{Asin}]";
        var fileName = $"Example [{Asin}].m4b";
        var folder = Path.Combine(options.BooksDirectory, folderName);
        Directory.CreateDirectory(folder);
        File.WriteAllText(Path.Combine(folder, fileName), "audio");
        return $"{folderName}/{fileName}";
    }

    private static async Task<CompanionJob> RunBackupAsync(
        CompanionOptions options,
        ILogger<JobWorker>? logger = null)
    {
        var store = new JobStore(options, NullLogger<JobStore>.Instance);
        var queue = new JobQueue(store, options);
        var queued = await queue.EnqueueAsync(CompanionJobKind.Backup, Asin, CancellationToken.None);
        using var worker = new JobWorker(
            options,
            store,
            queue,
            new CliCoordinator(options),
            new LibraryCache(options),
            new OutputFileLocator(options),
            logger ?? NullLogger<JobWorker>.Instance);

        await worker.StartAsync(CancellationToken.None);
        try
        {
            var timeout = Stopwatch.StartNew();
            while (timeout.Elapsed < TimeSpan.FromSeconds(5))
            {
                var current = store.Get(queued.Job.Id)
                    ?? throw new InvalidOperationException("The queued test job disappeared.");
                if (current.Status is CompanionJobStatus.Succeeded or CompanionJobStatus.Failed)
                    return current;

                await Task.Delay(10);
            }

            throw new TimeoutException("The companion test job did not finish.");
        }
        finally
        {
            await worker.StopAsync(CancellationToken.None);
        }
    }

    private static string ShellQuote(string value)
        => $"'{value.Replace("'", "'\\''", StringComparison.Ordinal)}'";

    private sealed class CollectingLogger<T> : ILogger<T>
    {
        public List<string> Messages { get; } = [];

        public IDisposable? BeginScope<TState>(TState state) where TState : notnull
            => NullScope.Instance;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
            => Messages.Add(formatter(state, exception));
    }

    private sealed class NullScope : IDisposable
    {
        public static NullScope Instance { get; } = new();

        public void Dispose() { }
    }
}
