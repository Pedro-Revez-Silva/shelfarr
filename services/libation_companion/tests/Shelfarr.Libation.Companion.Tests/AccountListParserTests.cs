using Shelfarr.Libation.Companion.Libation;

namespace Shelfarr.Libation.Companion.Tests;

public sealed class AccountListParserTests
{
    [Fact]
    public void ParsesFiveColumnLibation1351BareOutput()
    {
        var account = AccountListParser.TryParse("reader@example.com\tReader\tus\tyes\tyes");

        Assert.NotNull(account);
        Assert.Equal("reader@example.com", account.Account);
        Assert.Equal("Reader", account.Name);
        Assert.Equal("us", account.Locale);
        Assert.True(account.ScanEnabled);
        Assert.True(account.Authenticated);
    }

    [Fact]
    public void ParsesSixColumnLibation14BareOutputWithAlsoScans()
    {
        var account = AccountListParser.TryParse(
            "reader@example.com\tReader\tgermany\tyes\tyes\tuk, us");

        Assert.NotNull(account);
        Assert.Equal("reader@example.com", account.Account);
        Assert.Equal("germany", account.Locale);
        Assert.True(account.ScanEnabled);
        Assert.True(account.Authenticated);
    }

    [Theory]
    [InlineData("No accounts configured.")]
    [InlineData("reader@example.com\tReader\tus\tyes")]
    [InlineData("")]
    public void IgnoresNonAccountLines(string line)
    {
        Assert.Null(AccountListParser.TryParse(line));
    }
}
