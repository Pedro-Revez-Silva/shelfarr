using System.Text.RegularExpressions;

namespace Shelfarr.Libation.Companion;

public sealed record AuthStartRequest(string? Account, string? Locale);
public sealed record AuthCompleteRequest(string? SessionId, string? ResponseUrl);
public sealed record AccountStatus(string Account, string Name, string Locale, bool ScanEnabled, bool Authenticated);

public static partial class InputValidation
{
    private static readonly HashSet<string> SupportedLocales = new(StringComparer.Ordinal)
    {
        "us", "uk", "australia", "canada", "france", "germany", "india", "italy", "japan", "spain"
    };

    public static bool TryAccount(string? value, out string account)
    {
        account = value?.Trim() ?? string.Empty;
        return account.Length is > 3 and <= 320 && AccountRegex().IsMatch(account);
    }

    public static bool TryLocale(string? value, out string locale)
    {
        locale = value?.Trim().ToLowerInvariant() ?? string.Empty;
        return SupportedLocales.Contains(locale);
    }

    public static bool TryAsin(string? value, out string asin)
    {
        asin = value?.Trim().ToUpperInvariant() ?? string.Empty;
        return AsinRegex().IsMatch(asin);
    }

    public static bool TryResponseUrl(string? value, string locale, out Uri? responseUrl)
    {
        responseUrl = null;
        if (string.IsNullOrWhiteSpace(value) || value.Length > 16_384)
            return false;
        if (!Uri.TryCreate(value.Trim(), UriKind.Absolute, out var parsed)
            || !parsed.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            || !string.IsNullOrEmpty(parsed.UserInfo)
            || string.IsNullOrWhiteSpace(parsed.Host))
            return false;

        if (!AllowedMarketplaceHosts(locale).Any(root =>
                parsed.Host.Equals(root, StringComparison.OrdinalIgnoreCase)
                || parsed.Host.EndsWith($".{root}", StringComparison.OrdinalIgnoreCase)))
            return false;

        responseUrl = parsed;
        return true;
    }

    private static IEnumerable<string> AllowedMarketplaceHosts(string locale) => locale switch
    {
        "uk" => ["amazon.co.uk", "audible.co.uk"],
        "canada" => ["amazon.ca", "audible.ca"],
        "germany" => ["amazon.de", "audible.de"],
        "france" => ["amazon.fr", "audible.fr"],
        "australia" => ["amazon.com.au", "audible.com.au"],
        "japan" => ["amazon.co.jp", "audible.co.jp"],
        "india" => ["amazon.in", "audible.in"],
        "spain" => ["amazon.es", "audible.es"],
        "italy" => ["amazon.it", "audible.it"],
        _ => ["amazon.com", "audible.com"]
    };

    [GeneratedRegex(@"^[^\s@]+@[^\s@]+$")]
    private static partial Regex AccountRegex();

    [GeneratedRegex("^[A-Z0-9]{10}$")]
    private static partial Regex AsinRegex();
}
