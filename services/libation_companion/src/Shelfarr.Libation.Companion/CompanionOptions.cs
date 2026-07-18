namespace Shelfarr.Libation.Companion;

public sealed record CompanionOptions
{
    public const string ApiVersion = "1";
    public const string PinnedLibationVersion = "13.5.1";

    public required string LibationCliPath { get; init; }
    public required string LibationFilesDirectory { get; init; }
    public required string BooksDirectory { get; init; }
    public required string InProgressDirectory { get; init; }
    public required string StateDirectory { get; init; }
    public required string TokenFile { get; init; }
    public required string ScriptPath { get; init; }
    public required string LoginWrapperPath { get; init; }
    public required TimeSpan AuthenticationSessionTimeout { get; init; }
    public required TimeSpan ShortCliTimeout { get; init; }
    public required TimeSpan SyncTimeout { get; init; }
    public required TimeSpan BackupTimeout { get; init; }
    public required int MaximumActiveJobs { get; init; }
    public required int MaximumTerminalJobs { get; init; }
    public required TimeSpan TerminalJobRetention { get; init; }

    public string JobsDirectory => Path.Combine(StateDirectory, "jobs");
    public string LibraryFile => Path.Combine(StateDirectory, "library.json");

    public static CompanionOptions FromEnvironment()
    {
        var libationFiles = AbsolutePath("LIBATION_FILES_DIR", "/config");
        var state = AbsolutePath("COMPANION_STATE_DIR", Path.Combine(libationFiles, "shelfarr-companion"));

        return new CompanionOptions
        {
            LibationCliPath = AbsolutePath("LIBATION_CLI_PATH", "/libation/LibationCli"),
            LibationFilesDirectory = libationFiles,
            BooksDirectory = AbsolutePath("LIBATION_BOOKS_DIR", "/data"),
            InProgressDirectory = AbsolutePath("LIBATION_IN_PROGRESS_DIR", Path.Combine(libationFiles, "in-progress")),
            StateDirectory = state,
            TokenFile = AbsolutePath("COMPANION_TOKEN_FILE", "/control/token"),
            ScriptPath = AbsolutePath("COMPANION_SCRIPT_PATH", "/usr/bin/script"),
            LoginWrapperPath = AbsolutePath("COMPANION_LOGIN_WRAPPER_PATH", "/companion/login-wrapper.sh"),
            AuthenticationSessionTimeout = TimeSpan.FromMinutes(Integer("AUTH_SESSION_TIMEOUT_MINUTES", 10, 2, 30)),
            ShortCliTimeout = TimeSpan.FromSeconds(Integer("CLI_SHORT_TIMEOUT_SECONDS", 60, 5, 300)),
            SyncTimeout = TimeSpan.FromMinutes(Integer("CLI_SYNC_TIMEOUT_MINUTES", 60, 5, 360)),
            BackupTimeout = TimeSpan.FromHours(Integer("CLI_BACKUP_TIMEOUT_HOURS", 6, 1, 48)),
            MaximumActiveJobs = Integer("COMPANION_MAX_ACTIVE_JOBS", 500, 1, 10_000),
            MaximumTerminalJobs = Integer("COMPANION_MAX_TERMINAL_JOBS", 5_000, 100, 100_000),
            TerminalJobRetention = TimeSpan.FromDays(Integer("COMPANION_TERMINAL_JOB_RETENTION_DAYS", 30, 1, 365))
        };
    }

    public void EnsureDirectories()
    {
        Directory.CreateDirectory(LibationFilesDirectory);
        Directory.CreateDirectory(BooksDirectory);
        Directory.CreateDirectory(InProgressDirectory);
        Directory.CreateDirectory(StateDirectory);
        Directory.CreateDirectory(JobsDirectory);
        Directory.CreateDirectory(Path.GetDirectoryName(TokenFile)
            ?? throw new InvalidOperationException("COMPANION_TOKEN_FILE must have a parent directory."));
    }

    private static string AbsolutePath(string name, string fallback)
    {
        var value = Environment.GetEnvironmentVariable(name);
        var path = string.IsNullOrWhiteSpace(value) ? fallback : value.Trim();
        if (!Path.IsPathFullyQualified(path))
            throw new InvalidOperationException($"{name} must be an absolute path.");

        return Path.GetFullPath(path);
    }

    private static int Integer(string name, int fallback, int minimum, int maximum)
    {
        var raw = Environment.GetEnvironmentVariable(name);
        if (string.IsNullOrWhiteSpace(raw))
            return fallback;
        if (!int.TryParse(raw, out var value) || value < minimum || value > maximum)
            throw new InvalidOperationException($"{name} must be an integer between {minimum} and {maximum}.");

        return value;
    }
}
