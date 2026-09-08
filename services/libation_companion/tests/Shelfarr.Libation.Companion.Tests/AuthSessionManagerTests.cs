using System.Text.Json;
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

    [Fact]
    public async Task ReregisterResetsOnlyTheSelectedMarketplaceBeforeStartingLogin()
    {
        if (OperatingSystem.IsWindows() || !File.Exists("/usr/bin/script"))
            return;

        using var temporary = new TemporaryDirectory();
        var wrapper = Path.Combine(temporary.Path, "fake-login.sh");
        await File.WriteAllTextAsync(wrapper, """
        #!/bin/sh
        set -eu
        echo "Open this URL in your web browser and sign in:"
        echo "https://www.amazon.com/ap/signin?session=reregister"
        IFS= read -r _
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
        Directory.CreateDirectory(options.LibationFilesDirectory);
        await File.WriteAllTextAsync(options.AccountsSettingsFile, """
            {"Accounts":[
              {"AccountId":"reader@example.com","AccountName":"Reader","IdentityTokens":{"LocaleName":"us","DeviceSerialNumber":"old-us-serial"}},
              {"AccountId":"reader@example.com","AccountName":"Reader UK","IdentityTokens":{"LocaleName":"uk","DeviceSerialNumber":"keep-uk-serial"}}
            ]}
            """);

        var coordinator = new CliCoordinator(options);
        await using var sessions = new AuthSessionManager(options, coordinator);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));

        var started = await sessions.StartAsync(
            "reader@example.com",
            "us",
            timeout.Token,
            reregister: true);

        Assert.Equal("waiting_for_browser", started.Status);
        using (var accounts = JsonDocument.Parse(File.ReadAllText(options.AccountsSettingsFile)))
        {
            var rows = accounts.RootElement.GetProperty("Accounts");
            Assert.Equal(2, rows.GetArrayLength());
            Assert.False(rows[0].GetProperty("IdentityTokens").TryGetProperty("DeviceSerialNumber", out _));
            Assert.Equal("keep-uk-serial", rows[1].GetProperty("IdentityTokens").GetProperty("DeviceSerialNumber").GetString());
        }

        var completed = await sessions.CompleteAsync(
            started.SessionId!,
            "https://www.amazon.com/ap/maplanding?ok=1",
            timeout.Token);
        Assert.Equal("authenticated", completed!.Status);
    }
}
