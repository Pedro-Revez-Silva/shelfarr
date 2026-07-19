using System.Net;

namespace Shelfarr.Libation.Companion.Tests;

public sealed class CompanionHealthProbeTests
{
    [Fact]
    public void RequiresTheSingleExactHealthcheckArgument()
    {
        Assert.True(CompanionHealthProbe.IsRequested(["--healthcheck"]));
        Assert.False(CompanionHealthProbe.IsRequested([]));
        Assert.False(CompanionHealthProbe.IsRequested(["--healthcheck", "extra"]));
        Assert.False(CompanionHealthProbe.IsRequested(["--HEALTHCHECK"]));
    }

    [Theory]
    [InlineData(HttpStatusCode.OK, 0)]
    [InlineData(HttpStatusCode.NoContent, 0)]
    [InlineData(HttpStatusCode.ServiceUnavailable, 1)]
    public async Task MapsHttpStatusToProcessExitCode(HttpStatusCode status, int expected)
    {
        var handler = new StubHandler(_ => new HttpResponseMessage(status));

        Assert.Equal(expected, await CompanionHealthProbe.RunAsync(handler));
    }

    [Fact]
    public async Task FailsClosedWhenTheListenerIsUnavailable()
    {
        var handler = new StubHandler(_ => throw new HttpRequestException("offline"));

        Assert.Equal(1, await CompanionHealthProbe.RunAsync(handler));
    }

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => Task.FromResult(response(request));
    }
}
