using System.Text.Json;
using Shelfarr.Libation.Companion.Libation;

namespace Shelfarr.Libation.Companion.Tests;

public sealed class AccountRegistrationResetTests
{
    [Fact]
    public void RemovesMatchingAccountRowsAndPreservesTheRest()
    {
        using var temporary = new TemporaryDirectory();
        var path = Path.Combine(temporary.Path, "AccountsSettings.json");
        File.WriteAllText(path, """
            {
              "Accounts": [
                { "AccountId": "reader@example.com", "AccountName": "Reader", "LibraryScan": true },
                { "AccountId": "other@example.com", "AccountName": "Other", "LibraryScan": true }
              ],
              "Cdm": "keep-me"
            }
            """);

        var removed = AccountRegistrationReset.RemoveMatchingAccounts(path, "Reader@example.com");

        Assert.Equal(1, removed);
        using var json = JsonDocument.Parse(File.ReadAllText(path));
        var accounts = json.RootElement.GetProperty("Accounts");
        Assert.Equal(1, accounts.GetArrayLength());
        Assert.Equal("other@example.com", accounts[0].GetProperty("AccountId").GetString());
        Assert.Equal("keep-me", json.RootElement.GetProperty("Cdm").GetString());
    }

    [Fact]
    public void LeavesFileUnchangedWhenNoAccountMatches()
    {
        using var temporary = new TemporaryDirectory();
        var path = Path.Combine(temporary.Path, "AccountsSettings.json");
        const string original = """{"Accounts":[{"AccountId":"keep@example.com"}]}""";
        File.WriteAllText(path, original);

        Assert.Equal(0, AccountRegistrationReset.RemoveMatchingAccounts(path, "missing@example.com"));
        Assert.Equal(original, File.ReadAllText(path));
    }

    [Fact]
    public void ReturnsZeroWhenTheSeededEmptyObjectHasNoAccounts()
    {
        using var temporary = new TemporaryDirectory();
        var path = Path.Combine(temporary.Path, "AccountsSettings.json");
        File.WriteAllText(path, "{}");

        Assert.Equal(0, AccountRegistrationReset.RemoveMatchingAccounts(path, "reader@example.com"));
        Assert.Equal("{}", File.ReadAllText(path));
    }
}
