using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace Shelfarr.Libation.Companion.Libation;

public sealed record AuthStartResult(
    string Status,
    string? SessionId,
    string? LoginUrl,
    DateTimeOffset? ExpiresAt);

public sealed record AuthCompleteResult(string Status);

public sealed class CompanionBusyException : Exception
{
    public CompanionBusyException() : base("Libation is already processing another operation.") { }
}

public sealed partial class AuthSessionManager : IAsyncDisposable
{
    private const int MaximumCapturedCharacters = 128 * 1024;
    private readonly CompanionOptions _options;
    private readonly CliCoordinator _coordinator;
    private readonly ConcurrentDictionary<string, AuthSession> _sessions = new(StringComparer.Ordinal);

    public AuthSessionManager(CompanionOptions options, CliCoordinator coordinator)
    {
        _options = options;
        _coordinator = coordinator;
    }

    public async Task<AuthStartResult> StartAsync(string account, string locale, CancellationToken cancellationToken)
    {
        var lease = await _coordinator.TryAcquireAsync(cancellationToken)
            ?? throw new CompanionBusyException();
        Process? process = null;
        CancellationTokenSource? sessionLifetime = new();
        Task standardOutputTask = Task.CompletedTask;
        Task standardErrorTask = Task.CompletedTask;

        try
        {
            process = new Process { StartInfo = CreateStartInfo(account, locale) };
            if (!process.Start())
                throw new InvalidOperationException("Libation login could not be started.");

            var loginUrl = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            var capture = new OutputCapture(loginUrl);
            standardOutputTask = capture.PumpAsync(process.StandardOutput, sessionLifetime.Token);
            standardErrorTask = capture.PumpAsync(process.StandardError, sessionLifetime.Token);
            var exitTask = process.WaitForExitAsync(sessionLifetime.Token);
            var timeoutTask = Task.Delay(_options.AuthenticationSessionTimeout, cancellationToken);
            var completed = await Task.WhenAny(loginUrl.Task, exitTask, timeoutTask);

            if (completed == timeoutTask)
            {
                cancellationToken.ThrowIfCancellationRequested();
                throw new TimeoutException("Libation did not produce a login URL before the authentication session timed out.");
            }

            if (completed == exitTask)
            {
                await Task.WhenAll(standardOutputTask, standardErrorTask);
                if (process.ExitCode == 0 && capture.Text.Contains("already authenticated", StringComparison.OrdinalIgnoreCase))
                    return new AuthStartResult("authenticated", null, null, null);

                throw new InvalidOperationException($"Libation login exited before authentication began (exit code {process.ExitCode}).");
            }

            var id = Guid.NewGuid().ToString("N");
            var expiresAt = DateTimeOffset.UtcNow.Add(_options.AuthenticationSessionTimeout);
            var session = new AuthSession(
                id,
                locale,
                expiresAt,
                process,
                lease,
                sessionLifetime,
                capture,
                standardOutputTask,
                standardErrorTask);
            if (!_sessions.TryAdd(id, session))
                throw new InvalidOperationException("Could not register the Libation authentication session.");

            process = null;
            lease = null!;
            sessionLifetime = null;
            _ = ExpireAsync(session);
            return new AuthStartResult("waiting_for_browser", id, await loginUrl.Task, expiresAt);
        }
        finally
        {
            if (process is not null)
            {
                sessionLifetime?.Cancel();
                CliCoordinator.Kill(process);
                await ObservePumpsAsync(standardOutputTask, standardErrorTask);
                process.Dispose();
            }

            sessionLifetime?.Dispose();
            if (lease is not null)
                await lease.DisposeAsync();
        }
    }

    public async Task<AuthCompleteResult?> CompleteAsync(
        string sessionId,
        string responseUrl,
        CancellationToken cancellationToken)
    {
        if (!_sessions.TryGetValue(sessionId, out var candidate))
            return null;
        if (!InputValidation.TryResponseUrl(responseUrl, candidate.Locale, out _))
            throw new ArgumentException("The response URL is not a valid HTTPS URL for the selected Audible marketplace.");
        if (!_sessions.TryRemove(sessionId, out var session))
            return null;

        session.CancelExpiration();
        try
        {
            // The pseudo-terminal has echo disabled, so the sensitive redirect URL is
            // consumed by Libation without being copied into companion output or logs.
            await session.Process.StandardInput.WriteLineAsync(responseUrl.AsMemory(), cancellationToken);
            await session.Process.StandardInput.FlushAsync(cancellationToken);
            session.Process.StandardInput.Close();

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(_options.ShortCliTimeout);
            try
            {
                await session.Process.WaitForExitAsync(timeout.Token);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                throw new TimeoutException("Libation did not finish validating the Audible login in time.");
            }

            await Task.WhenAll(session.StandardOutputTask, session.StandardErrorTask);
            if (session.Process.ExitCode != 0)
                throw new InvalidOperationException($"Libation rejected the authentication response (exit code {session.Process.ExitCode}).");
            if (!session.Capture.Text.Contains("Successfully authenticated", StringComparison.OrdinalIgnoreCase)
                && !session.Capture.Text.Contains("already authenticated", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Libation exited without confirming authentication.");

            return new AuthCompleteResult("authenticated");
        }
        finally
        {
            await session.DisposeAsync();
        }
    }

    public async ValueTask DisposeAsync()
    {
        foreach (var pair in _sessions.ToArray())
        {
            if (_sessions.TryRemove(pair.Key, out var session))
                await session.DisposeAsync();
        }
    }

    private ProcessStartInfo CreateStartInfo(string account, string locale)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = _options.ScriptPath,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            CreateNoWindow = true
        };
        startInfo.ArgumentList.Add("-q");
        startInfo.ArgumentList.Add("-e");
        startInfo.ArgumentList.Add("-f");
        startInfo.ArgumentList.Add("-c");
        startInfo.ArgumentList.Add(_options.LoginWrapperPath);
        startInfo.ArgumentList.Add("/dev/null");
        startInfo.Environment["SHELFARR_AUDIBLE_ACCOUNT"] = account;
        startInfo.Environment["SHELFARR_AUDIBLE_LOCALE"] = locale;
        startInfo.Environment["LIBATION_CLI_PATH"] = _options.LibationCliPath;
        _coordinator.ApplyEnvironment(startInfo);
        return startInfo;
    }

    private async Task ExpireAsync(AuthSession session)
    {
        try
        {
            await Task.Delay(session.ExpiresAt - DateTimeOffset.UtcNow, session.ExpirationToken);
            if (_sessions.TryRemove(session.Id, out var expired))
                await expired.DisposeAsync();
        }
        catch (OperationCanceledException)
        {
            // Completion or shutdown owns cleanup.
        }
    }

    private static async Task ObservePumpsAsync(params Task[] tasks)
    {
        try
        {
            await Task.WhenAll(tasks);
        }
        catch (OperationCanceledException)
        {
            // Expected when startup is abandoned or a session expires.
        }
        catch (IOException)
        {
            // Killing the pseudo-terminal may close redirected pipes mid-read.
        }
    }

    private sealed class AuthSession : IAsyncDisposable
    {
        private int _disposed;
        private readonly CancellationTokenSource _expiration = new();
        private readonly CancellationTokenSource _lifetime;
        private readonly CliCoordinator.CliLease _lease;

        public AuthSession(
            string id,
            string locale,
            DateTimeOffset expiresAt,
            Process process,
            CliCoordinator.CliLease lease,
            CancellationTokenSource lifetime,
            OutputCapture capture,
            Task standardOutputTask,
            Task standardErrorTask)
        {
            Id = id;
            Locale = locale;
            ExpiresAt = expiresAt;
            Process = process;
            _lease = lease;
            _lifetime = lifetime;
            Capture = capture;
            StandardOutputTask = standardOutputTask;
            StandardErrorTask = standardErrorTask;
        }

        public string Id { get; }
        public string Locale { get; }
        public DateTimeOffset ExpiresAt { get; }
        public Process Process { get; }
        public OutputCapture Capture { get; }
        public Task StandardOutputTask { get; }
        public Task StandardErrorTask { get; }
        public CancellationToken ExpirationToken => _expiration.Token;

        public void CancelExpiration() => _expiration.Cancel();

        public async ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
                return;

            _expiration.Cancel();
            _lifetime.Cancel();
            CliCoordinator.Kill(Process);
            try
            {
                await Task.WhenAll(StandardOutputTask, StandardErrorTask);
            }
            catch (OperationCanceledException)
            {
                // Expected when an authentication session expires or the service stops.
            }
            catch (IOException)
            {
                // Killing the pseudo-terminal may close redirected pipes mid-read.
            }
            Process.Dispose();
            _expiration.Dispose();
            _lifetime.Dispose();
            await _lease.DisposeAsync();
        }
    }

    private sealed partial class OutputCapture
    {
        private readonly Lock _lock = new();
        private readonly StringBuilder _text = new();
        private readonly TaskCompletionSource<string> _loginUrl;
        private bool _waitingForLoginUrl;

        public OutputCapture(TaskCompletionSource<string> loginUrl) => _loginUrl = loginUrl;

        public string Text
        {
            get
            {
                lock (_lock)
                    return _text.ToString();
            }
        }

        public async Task PumpAsync(StreamReader reader, CancellationToken cancellationToken)
        {
            while (await reader.ReadLineAsync(cancellationToken) is { } rawLine)
            {
                var line = AnsiEscapeRegex().Replace(rawLine.TrimEnd('\r'), string.Empty);
                lock (_lock)
                {
                    if (_text.Length < MaximumCapturedCharacters)
                    {
                        _text.Append(line.AsSpan(0, Math.Min(line.Length, MaximumCapturedCharacters - _text.Length)));
                        _text.AppendLine();
                    }

                    if (line.Contains("Open this URL in your web browser", StringComparison.OrdinalIgnoreCase))
                        _waitingForLoginUrl = true;
                    if (_waitingForLoginUrl && HttpsUrlRegex().Match(line) is { Success: true } match)
                        _loginUrl.TrySetResult(match.Value);
                }
            }
        }

        [GeneratedRegex(@"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")]
        private static partial Regex AnsiEscapeRegex();

        [GeneratedRegex(@"https://[^\s]+", RegexOptions.IgnoreCase)]
        private static partial Regex HttpsUrlRegex();
    }
}
