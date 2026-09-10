using System.Net;
using System.Net.Sockets;
using System.Text.Json;

namespace Shelfarr.Libation.Companion;

public static class CompanionHealthProbe
{
    public const string Argument = "--healthcheck";
    public static readonly Uri DefaultHealthUri = new("http://127.0.0.1:8080/health");

    public static bool IsRequested(IReadOnlyList<string> arguments) =>
        arguments.Any(argument => string.Equals(argument, Argument, StringComparison.Ordinal));

    public static Uri ResolveHealthUri(
        IReadOnlyList<string>? arguments = null,
        IReadOnlyDictionary<string, string?>? environment = null)
    {
        if (TryReadUrls(arguments, environment, out var urls)
            && TryFirstHttpHealthUri(urls, out var fromUrls))
            return fromUrls;

        var ports = ReadVariable(environment, "ASPNETCORE_HTTP_PORTS");
        if (TryFirstPort(ports, out var port))
            return LoopbackHealthUri(port, ipv6: false);

        return DefaultHealthUri;
    }

    public static bool IsLive(HttpStatusCode statusCode, string? body)
    {
        if ((int)statusCode is < 200 or > 299)
            return false;
        if (string.IsNullOrWhiteSpace(body))
            return true;

        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
                return true;
            if (!document.RootElement.TryGetProperty("status", out var status)
                || status.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)
                return true;

            // libraryReady reports whether a cached library exists. An idle or
            // unconfigured Libation install is still a live companion process.
            return string.Equals(status.GetString(), "ok", StringComparison.OrdinalIgnoreCase);
        }
        catch (JsonException)
        {
            return true;
        }
    }

    public static async Task<int> RunAsync(
        HttpMessageHandler? handler = null,
        IReadOnlyList<string>? arguments = null,
        IReadOnlyDictionary<string, string?>? environment = null,
        CancellationToken cancellationToken = default)
    {
        using var client = handler is null ? new HttpClient() : new HttpClient(handler);
        client.Timeout = TimeSpan.FromSeconds(5);
        var healthUri = ResolveHealthUri(arguments, environment);

        try
        {
            using var response = await client.GetAsync(healthUri, cancellationToken);
            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            if (IsLive(response.StatusCode, body))
                return 0;

            Console.Error.WriteLine($"Companion health probe received HTTP {(int)response.StatusCode} from {healthUri}.");
            return 1;
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or OperationCanceledException)
        {
            Console.Error.WriteLine($"Companion health probe could not reach {healthUri}.");
            return 1;
        }
    }

    private static bool TryReadUrls(
        IReadOnlyList<string>? arguments,
        IReadOnlyDictionary<string, string?>? environment,
        out string urls)
    {
        if (TryUrlsFromArguments(arguments, out var fromArguments))
        {
            urls = fromArguments;
            return true;
        }

        // WebApplication.CreateBuilder treats DOTNET_URLS as the urls host
        // setting and lets it override the image's ASPNETCORE_URLS=8080.
        var fromEnvironment = ReadVariable(environment, "DOTNET_URLS")
            ?? ReadVariable(environment, "ASPNETCORE_URLS");
        if (!string.IsNullOrWhiteSpace(fromEnvironment))
        {
            urls = fromEnvironment;
            return true;
        }

        urls = string.Empty;
        return false;
    }

    private static bool TryUrlsFromArguments(IReadOnlyList<string>? arguments, out string urls)
    {
        urls = string.Empty;
        if (arguments is null)
            return false;

        for (var index = 0; index < arguments.Count; index++)
        {
            var argument = arguments[index];
            if (argument.StartsWith("--urls=", StringComparison.Ordinal))
            {
                urls = argument["--urls=".Length..].Trim();
                return urls.Length > 0;
            }

            if (!string.Equals(argument, "--urls", StringComparison.Ordinal) || index + 1 >= arguments.Count)
                continue;

            urls = arguments[index + 1].Trim();
            return urls.Length > 0;
        }

        return false;
    }

    private static bool TryFirstHttpHealthUri(string urls, out Uri healthUri)
    {
        foreach (var candidate in urls.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (TryCreateHealthUri(candidate, out healthUri))
                return true;
        }

        healthUri = DefaultHealthUri;
        return false;
    }

    private static bool TryCreateHealthUri(string binding, out Uri healthUri)
    {
        healthUri = DefaultHealthUri;
        var normalized = NormalizeKestrelBinding(binding);
        if (!Uri.TryCreate(normalized, UriKind.Absolute, out var parsed)
            || !string.Equals(parsed.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase))
            return false;

        var port = parsed.IsDefaultPort ? 80 : parsed.Port;
        if (port is < 1 or > 65535)
            return false;

        healthUri = CreateHealthUri(parsed.IdnHost, port);
        return true;
    }

    private static Uri CreateHealthUri(string host, int port)
    {
        if (IPAddress.TryParse(host, out var address))
        {
            if (address.Equals(IPAddress.Any))
                return LoopbackHealthUri(port, ipv6: false);
            if (address.Equals(IPAddress.IPv6Any))
                return LoopbackHealthUri(port, ipv6: true);

            var formatted = address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6
                ? $"[{address}]"
                : address.ToString();
            return new Uri($"http://{formatted}:{port}/health");
        }

        return LoopbackHealthUri(port, ipv6: false);
    }

    private static string NormalizeKestrelBinding(string binding)
    {
        var value = binding.Trim();
        value = ReplaceHost(value, "+", "0.0.0.0");
        value = ReplaceHost(value, "*", "0.0.0.0");
        return value;
    }

    private static string ReplaceHost(string binding, string wildcard, string replacement)
    {
        var marker = $"://{wildcard}";
        var index = binding.IndexOf(marker, StringComparison.Ordinal);
        if (index < 0)
            return binding;

        var hostEnd = index + marker.Length;
        if (hostEnd < binding.Length && binding[hostEnd] is not (':' or '/'))
            return binding;

        return string.Concat(binding.AsSpan(0, index + 3), replacement, binding.AsSpan(hostEnd));
    }

    private static Uri LoopbackHealthUri(int port, bool ipv6) =>
        new(ipv6 ? $"http://[::1]:{port}/health" : $"http://127.0.0.1:{port}/health");

    private static bool TryFirstPort(string? ports, out int port)
    {
        port = 0;
        if (string.IsNullOrWhiteSpace(ports))
            return false;

        foreach (var candidate in ports.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (int.TryParse(candidate, out port) && port is >= 1 and <= 65535)
                return true;
        }

        return false;
    }

    private static string? ReadVariable(IReadOnlyDictionary<string, string?>? environment, string name)
    {
        if (environment is not null)
        {
            return environment.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
                ? value.Trim()
                : null;
        }

        var processValue = Environment.GetEnvironmentVariable(name);
        return string.IsNullOrWhiteSpace(processValue) ? null : processValue.Trim();
    }
}
