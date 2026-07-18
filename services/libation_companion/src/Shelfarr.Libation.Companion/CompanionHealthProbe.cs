namespace Shelfarr.Libation.Companion;

public static class CompanionHealthProbe
{
    public const string Argument = "--healthcheck";
    private static readonly Uri HealthUri = new("http://127.0.0.1:8080/health");

    public static bool IsRequested(IReadOnlyList<string> arguments) =>
        arguments.Count == 1 && string.Equals(arguments[0], Argument, StringComparison.Ordinal);

    public static async Task<int> RunAsync(
        HttpMessageHandler? handler = null,
        CancellationToken cancellationToken = default)
    {
        using var client = handler is null ? new HttpClient() : new HttpClient(handler);
        client.Timeout = TimeSpan.FromSeconds(5);

        try
        {
            using var response = await client.GetAsync(HealthUri, cancellationToken);
            return response.IsSuccessStatusCode ? 0 : 1;
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException)
        {
            return 1;
        }
    }
}
