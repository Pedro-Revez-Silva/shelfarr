using System.Text.Json;
using Shelfarr.Libation.Companion.Libation;

namespace Shelfarr.Libation.Companion.Tests;

public sealed class AccountRegistrationResetTests
{
    [Fact]
    public void ResetsOnlySelectedMarketplaceAndPreservesAccountPreferences()
    {
        using var temporary = new TemporaryDirectory();
        var path = Path.Combine(temporary.Path, "AccountsSettings.json");
        File.WriteAllText(path, """
            {
              "Accounts": [
                { "AccountId": "reader@example.com", "AccountName": "Reader", "LibraryScan": false,
                  "AdditionalLocaleNames": ["canada"], "DecryptKey": "keep-key",
                  "IdentityTokens": {"LocaleName":"us", "DeviceSerialNumber":"old-us-serial", "RefreshToken":"old-token"} },
                { "AccountId": "reader@example.com", "AccountName": "Reader UK", "LibraryScan": true,
                  "IdentityTokens": {"LocaleName":"uk", "DeviceSerialNumber":"keep-uk-serial"} },
                { "AccountId": "other@example.com", "AccountName": "Other", "LibraryScan": true,
                  "IdentityTokens": {"LocaleName":"us", "DeviceSerialNumber":"keep-other-serial"} }
              ],
              "Cdm": "keep-me"
            }
            """);
        using var original = JsonDocument.Parse(File.ReadAllText(path));

        var reset = AccountRegistrationReset.ResetMatchingRegistration(path, "Reader@example.com", "us");

        Assert.Equal(1, reset);
        using var json = JsonDocument.Parse(File.ReadAllText(path));
        var accounts = json.RootElement.GetProperty("Accounts");
        Assert.Equal(3, accounts.GetArrayLength());
        Assert.Equal("Reader", accounts[0].GetProperty("AccountName").GetString());
        Assert.False(accounts[0].GetProperty("LibraryScan").GetBoolean());
        Assert.Equal("canada", accounts[0].GetProperty("AdditionalLocaleNames")[0].GetString());
        Assert.Equal("keep-key", accounts[0].GetProperty("DecryptKey").GetString());
        var identity = accounts[0].GetProperty("IdentityTokens");
        Assert.Equal("us", identity.GetProperty("LocaleName").GetString());
        Assert.Equal("Atna|", identity.GetProperty("ExistingAccessToken").GetProperty("TokenValue").GetString());
        Assert.False(identity.TryGetProperty("DeviceSerialNumber", out _));
        Assert.False(identity.TryGetProperty("RefreshToken", out _));
        for (var index = 1; index < 3; index++)
            Assert.True(JsonElement.DeepEquals(original.RootElement.GetProperty("Accounts")[index], accounts[index]));
        Assert.Equal("keep-me", json.RootElement.GetProperty("Cdm").GetString());
    }

    [Theory]
    [InlineData("missing@example.com", "us")]
    [InlineData("keep@example.com", "uk")]
    public void LeavesFileUnchangedWhenNoAccountAndMarketplaceMatch(string account, string locale)
    {
        using var temporary = new TemporaryDirectory();
        var path = Path.Combine(temporary.Path, "AccountsSettings.json");
        const string original = """{"Accounts":[{"AccountId":"keep@example.com","IdentityTokens":{"LocaleName":"us"}}]}""";
        File.WriteAllText(path, original);

        Assert.Equal(0, AccountRegistrationReset.ResetMatchingRegistration(path, account, locale));
        Assert.Equal(original, File.ReadAllText(path));
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"Accounts\":[null,{\"AccountId\":\"reader@example.com\"}]}")]
    public void LeavesUnregisteredAccountsUnchanged(string original)
    {
        using var temporary = new TemporaryDirectory();
        var path = Path.Combine(temporary.Path, "AccountsSettings.json");
        File.WriteAllText(path, original);

        Assert.Equal(0, AccountRegistrationReset.ResetMatchingRegistration(path, "reader@example.com", "us"));
        Assert.Equal(original, File.ReadAllText(path));
    }
}
