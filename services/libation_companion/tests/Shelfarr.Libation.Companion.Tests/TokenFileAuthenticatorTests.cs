using Shelfarr.Libation.Companion.Security;

namespace Shelfarr.Libation.Companion.Tests;

public sealed class TokenFileAuthenticatorTests
{
    [Fact]
    public void GeneratesAndAuthenticatesAFileBackedToken()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();

        var authenticator = new TokenFileAuthenticator(options);
        var token = File.ReadAllText(options.TokenFile).Trim();

        Assert.True(token.Length >= 32);
        Assert.True(authenticator.IsAuthorized($"Bearer {token}"));
        Assert.False(authenticator.IsAuthorized("Bearer incorrect-token-that-is-long-enough-123"));
        Assert.False(authenticator.IsAuthorized(token));
    }

    [Fact]
    public void PreservesAPreProvisionedToken()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var provisioned = $"operator-{new string('x', 40)}";
        File.WriteAllText(options.TokenFile, $"{provisioned}\n");

        var authenticator = new TokenFileAuthenticator(options);

        Assert.Equal(provisioned, File.ReadAllText(options.TokenFile).Trim());
        Assert.True(authenticator.IsAuthorized($"Bearer {provisioned}"));
    }

    [Fact]
    public void IgnoresAnIncompleteTemporaryFromAnInterruptedCreator()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var interruptedTemporary = Path.Combine(
            Path.GetDirectoryName(options.TokenFile)!,
            $".{Path.GetFileName(options.TokenFile)}.{Guid.NewGuid():N}.tmp");
        File.WriteAllText(interruptedTemporary, "partial");

        var authenticator = new TokenFileAuthenticator(options);
        var token = File.ReadAllText(options.TokenFile).Trim();

        Assert.True(token.Length >= 32);
        Assert.NotEqual("partial", token);
        Assert.True(authenticator.IsAuthorized($"Bearer {token}"));
    }

    [Fact]
    public async Task ConcurrentCreatorsPublishOneCompleteTokenWithoutReplacement()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        using var start = new ManualResetEventSlim(initialState: false);

        var creators = Enumerable.Range(0, 24)
            .Select(_ => Task.Run(() =>
            {
                start.Wait();
                return new TokenFileAuthenticator(options);
            }))
            .ToArray();
        start.Set();
        var authenticators = await Task.WhenAll(creators);
        var token = File.ReadAllText(options.TokenFile).Trim();

        Assert.True(token.Length >= 32);
        Assert.All(authenticators, authenticator =>
            Assert.True(authenticator.IsAuthorized($"Bearer {token}")));
        Assert.DoesNotContain('\n', token);
        Assert.DoesNotContain('\r', token);
    }
}
