using Shelfarr.Libation.Companion.Libation;

namespace Shelfarr.Libation.Companion.Tests;

public sealed class AuthSessionManagerTests
{
    [Fact]
    public async Task HoldsOnePseudoTerminalProcessAcrossStartAndComplete()
    {
        if (OperatingSystem.IsWindows() || !File.Exists("/usr/bin/script"))
            return;

        using var temporary = new TemporaryDirectory();
        var wrapper = Path.Combine(temporary.Path, "fake-login.sh");
        await File.WriteAllTextAsync(wrapper, """
        #!/bin/sh
        set -eu
        stty -echo
        echo "Open this URL in your web browser and sign in:"
        echo "https://www.amazon.com/ap/signin?session=upstream-only"
        IFS= read -r response
        case "${response}" in
          https://www.amazon.com/*) ;;
          *) exit 3 ;;
        esac
        echo "Successfully authenticated account."
        """);
        File.SetUnixFileMode(wrapper,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);

        var options = TestOptions.Create(temporary.Path) with
        {
            LoginWrapperPath = wrapper,
            ShortCliTimeout = TimeSpan.FromSeconds(5),
            AuthenticationSessionTimeout = TimeSpan.FromMinutes(2)
        };
        options.EnsureDirectories();
        var coordinator = new CliCoordinator(options);
        await using var sessions = new AuthSessionManager(options, coordinator);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));

        var started = await sessions.StartAsync("reader@example.com", "us", timeout.Token);
        Assert.Equal("waiting_for_browser", started.Status);
        Assert.NotNull(started.SessionId);
        Assert.StartsWith("https://www.amazon.com/", started.LoginUrl, StringComparison.Ordinal);
        Assert.True(coordinator.IsBusy);

        var completed = await sessions.CompleteAsync(
            started.SessionId!,
            "https://www.amazon.com/ap/maplanding?sensitive=never-log-this",
            timeout.Token);

        Assert.NotNull(completed);
        Assert.Equal("authenticated", completed.Status);
        Assert.False(coordinator.IsBusy);
    }
}
