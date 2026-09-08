using System.Text.Json;
using System.Text.Json.Nodes;

namespace Shelfarr.Libation.Companion.Libation;

internal static class AccountRegistrationReset
{
    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true
    };

    public static int ResetMatchingRegistration(string accountsFile, string account, string locale)
    {
        if (!Path.Exists(accountsFile))
            return 0;
        if (File.ResolveLinkTarget(accountsFile, returnFinalTarget: false) is not null)
            throw new InvalidOperationException("The Libation accounts file must be a regular file.");

        var json = File.ReadAllText(accountsFile);
        if (string.IsNullOrWhiteSpace(json))
            return 0;

        var root = JsonNode.Parse(json) as JsonObject
            ?? throw new InvalidDataException("Libation accounts file is not a JSON object.");
        if (root["Accounts"] is not JsonArray accounts)
            return 0;

        var reset = 0;
        foreach (var node in accounts)
        {
            if (node is not JsonObject row || !AccountIdEquals(row, account)
                || row["IdentityTokens"] is not JsonObject identity
                || identity["LocaleName"] is not JsonValue localeValue
                || localeValue.GetValueKind() != JsonValueKind.String
                || !string.Equals(localeValue.GetValue<string>(), locale, StringComparison.OrdinalIgnoreCase))
                continue;

            // AudibleApi 14.1's empty identity is invalid but retains the locale
            // needed for Libation to upsert this row and start a fresh registration.
            // Preserve account names, scan preferences, and other marketplaces.
            row["IdentityTokens"] = new JsonObject
            {
                ["LocaleName"] = localeValue.GetValue<string>(),
                ["ExistingAccessToken"] = new JsonObject
                {
                    ["TokenValue"] = "Atna|",
                    ["Expires"] = "0001-01-01T00:00:00"
                }
            };
            reset++;
        }

        if (reset == 0)
            return 0;

        WriteAtomically(accountsFile, root);
        return reset;
    }

    private static bool AccountIdEquals(JsonNode? node, string account)
    {
        if (node is not JsonObject row)
            return false;
        if (row["AccountId"] is not JsonValue value || value.GetValueKind() != JsonValueKind.String)
            return false;

        return string.Equals(value.GetValue<string>(), account, StringComparison.OrdinalIgnoreCase);
    }

    private static void WriteAtomically(string accountsFile, JsonObject root)
    {
        var temporary = $"{accountsFile}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(temporary, root.ToJsonString(WriteOptions));
            File.Move(temporary, accountsFile, overwrite: true);
        }
        finally
        {
            File.Delete(temporary);
        }
    }
}
