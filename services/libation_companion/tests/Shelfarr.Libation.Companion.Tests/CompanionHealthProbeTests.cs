using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Shelfarr.Libation.Companion.Tests;

public sealed class CompanionHealthProbeTests
{
    [Fact]
    public void TreatsHealthcheckAsRequestedEvenWhenAdditionalArgumentsArePresent()
    {
        Assert.True(CompanionHealthProbe.IsRequested(["--healthcheck"]));
        Assert.True(CompanionHealthProbe.IsRequested(["--urls", "http://0.0.0.0:8282", "--healthcheck"]));
        Assert.True(CompanionHealthProbe.IsRequested(["--healthcheck", "extra"]));
        Assert.False(CompanionHealthProbe.IsRequested([]));
        Assert.False(CompanionHealthProbe.IsRequested(["--HEALTHCHECK"]));
        Assert.False(CompanionHealthProbe.IsRequested(["--urls", "http://0.0.0.0:8080"]));
    }

    [Fact]
    public void ResolvesTheConfiguredListenPortToLoopbackHealth()
    {
        Assert.Equal(
            CompanionHealthProbe.DefaultHealthUri,
            CompanionHealthProbe.ResolveHealthUri(environment: new Dictionary<string, string?>()));
        Assert.Equal(
            new Uri("http://127.0.0.1:8282/health"),
            CompanionHealthProbe.ResolveHealthUri(
                environment: new Dictionary<string, string?>
                {
                    ["ASPNETCORE_URLS"] = "http://0.0.0.0:8282"
                }));
        Assert.Equal(
            new Uri("http://127.0.0.1:8282/health"),
            CompanionHealthProbe.ResolveHealthUri(
                arguments: ["--urls", "http://+:8282", "--healthcheck"],
                environment: new Dictionary<string, string?>
                {
                    ["ASPNETCORE_URLS"] = "http://0.0.0.0:8080"
                }));
        Assert.Equal(
            new Uri("http://[::1]:9090/health"),
            CompanionHealthProbe.ResolveHealthUri(
                environment: new Dictionary<string, string?>
                {
                    ["ASPNETCORE_URLS"] = "http://[::]:9090"
                }));
        Assert.Equal(
            new Uri("http://127.0.0.1:8181/health"),
            CompanionHealthProbe.ResolveHealthUri(
                environment: new Dictionary<string, string?>
                {
                    ["ASPNETCORE_HTTP_PORTS"] = "8181"
                }));
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
    public async Task ProbesTheConfiguredListenerAndIgnoresLibraryReadiness()
    {
        Uri? requested = null;
        var handler = new StubHandler(request =>
        {
            requested = request.RequestUri;
            return JsonResponse(HttpStatusCode.OK, """{"status":"ok","libraryReady":false,"busy":false}""");
        });

        var exit = await CompanionHealthProbe.RunAsync(
            handler,
            environment: new Dictionary<string, string?>
            {
                ["ASPNETCORE_URLS"] = "http://0.0.0.0:8282"
            });

        Assert.Equal(0, exit);
        Assert.Equal(new Uri("http://127.0.0.1:8282/health"), requested);
    }

    [Fact]
    public async Task DoesNotBindTheListenPortWhenTheCompanionIsAlreadyServingHealth()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            var port = ((IPEndPoint)listener.LocalEndpoint).Port;
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var serve = ServeJsonHealthAsync(
                listener,
                """{"status":"ok","apiVersion":"1","libraryReady":false,"busy":false}""",
                timeout.Token);

            var exit = await CompanionHealthProbe.RunAsync(
                environment: new Dictionary<string, string?>
                {
                    ["ASPNETCORE_URLS"] = $"http://0.0.0.0:{port}"
                },
                cancellationToken: timeout.Token);

            Assert.Equal(0, exit);
            Assert.True(listener.Server.IsBound);
            await serve.WaitAsync(timeout.Token);
        }
        finally
        {
            listener.Stop();
        }
    }

    [Fact]
    public async Task FailsClosedWhenTheListenerIsUnavailable()
    {
        var handler = new StubHandler(_ => throw new HttpRequestException("offline"));

        Assert.Equal(1, await CompanionHealthProbe.RunAsync(handler));
    }

    [Fact]
    public void LibraryReadinessDoesNotControlCompanionLiveness()
    {
        Assert.True(CompanionHealthProbe.IsLive(
            HttpStatusCode.OK,
            """{"status":"ok","libraryReady":false}"""));
        Assert.True(CompanionHealthProbe.IsLive(
            HttpStatusCode.OK,
            """{"status":"ok","libraryReady":true}"""));
        Assert.False(CompanionHealthProbe.IsLive(
            HttpStatusCode.OK,
            """{"status":"unhealthy","libraryReady":true}"""));
        Assert.False(CompanionHealthProbe.IsLive(HttpStatusCode.ServiceUnavailable, """{"status":"ok"}"""));
    }

    private static HttpResponseMessage JsonResponse(HttpStatusCode status, string json) =>
        new(status)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json")
        };

    private static async Task ServeJsonHealthAsync(TcpListener listener, string json, CancellationToken cancellationToken)
    {
        using var client = await listener.AcceptTcpClientAsync(cancellationToken);
        await using var stream = client.GetStream();
        var buffer = new byte[4096];
        var received = new MemoryStream();
        while (!HasCompleteHttpHeaders(received.ToArray()))
        {
            var read = await stream.ReadAsync(buffer, cancellationToken);
            if (read == 0)
                return;
            received.Write(buffer, 0, read);
        }

        var payload = Encoding.UTF8.GetBytes(json);
        var header = Encoding.ASCII.GetBytes(
            $"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {payload.Length}\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(header, cancellationToken);
        await stream.WriteAsync(payload, cancellationToken);
        await stream.FlushAsync(cancellationToken);
    }

    private static bool HasCompleteHttpHeaders(byte[] received)
    {
        var text = Encoding.ASCII.GetString(received);
        return text.Contains("\r\n\r\n", StringComparison.Ordinal);
    }

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => Task.FromResult(response(request));
    }
}
