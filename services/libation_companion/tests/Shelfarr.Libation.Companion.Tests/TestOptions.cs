namespace Shelfarr.Libation.Companion.Tests;

internal static class TestOptions
{
    public static CompanionOptions Create(string root) => new()
    {
        LibationCliPath = "/libation/LibationCli",
        LibationFilesDirectory = Path.Combine(root, "config"),
        BooksDirectory = Path.Combine(root, "books"),
        InProgressDirectory = Path.Combine(root, "in-progress"),
        StateDirectory = Path.Combine(root, "state"),
        TokenFile = Path.Combine(root, "control", "token"),
        ScriptPath = "/usr/bin/script",
        LoginWrapperPath = "/companion/login-wrapper.sh",
        AuthenticationSessionTimeout = TimeSpan.FromMinutes(10),
        ShortCliTimeout = TimeSpan.FromSeconds(60),
        SyncTimeout = TimeSpan.FromMinutes(60),
        BackupTimeout = TimeSpan.FromHours(6),
        MaximumActiveJobs = 500,
        MaximumTerminalJobs = 5_000,
        TerminalJobRetention = TimeSpan.FromDays(30)
    };
}

internal sealed class TemporaryDirectory : IDisposable
{
    public TemporaryDirectory()
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"shelfarr-companion-{Guid.NewGuid():N}");
        Directory.CreateDirectory(Path);
    }

    public string Path { get; }

    public void Dispose() => Directory.Delete(Path, recursive: true);
}
