using System.Text.Json;
using System.Text.Json.Nodes;

namespace Shelfarr.Libation.Companion.Libation;

internal static class AccountRegistrationReset
{
    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true
    };

    public static int RemoveMatchingAccounts(string accountsFile, string account)
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

        var removed = 0;
        for (var index = accounts.Count - 1; index >= 0; index--)
        {
            if (!AccountIdEquals(accounts[index], account))
                continue;

            accounts.RemoveAt(index);
            removed++;
        }

        if (removed == 0)
            return 0;

        WriteAtomically(accountsFile, root);
        return removed;
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
