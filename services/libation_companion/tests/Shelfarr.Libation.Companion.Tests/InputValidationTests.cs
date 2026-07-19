namespace Shelfarr.Libation.Companion.Tests;

public sealed class InputValidationTests
{
    [Theory]
    [InlineData("us")]
    [InlineData("UK")]
    [InlineData("australia")]
    [InlineData("canada")]
    [InlineData("france")]
    [InlineData("germany")]
    [InlineData("india")]
    [InlineData("italy")]
    [InlineData("japan")]
    [InlineData("spain")]
    public void AcceptsLocalesSupportedByPinnedLibation(string value)
    {
        Assert.True(InputValidation.TryLocale(value, out _));
    }

    [Theory]
    [InlineData("au")]
    [InlineData("br")]
    [InlineData("germany;rm -rf /")]
    [InlineData("")]
    public void RejectsUnsupportedOrUnsafeLocales(string value)
    {
        Assert.False(InputValidation.TryLocale(value, out _));
    }

    [Fact]
    public void ResponseUrlMustMatchMarketplaceAndUseHttps()
    {
        Assert.True(InputValidation.TryResponseUrl(
            "https://www.amazon.co.uk/ap/maplanding?openid=redacted",
            "uk",
            out _));
        Assert.False(InputValidation.TryResponseUrl(
            "https://www.amazon.com/ap/maplanding?openid=redacted",
            "uk",
            out _));
        Assert.False(InputValidation.TryResponseUrl(
            "http://www.amazon.co.uk/ap/maplanding?openid=redacted",
            "uk",
            out _));
    }

    [Theory]
    [InlineData("B012345678")]
    [InlineData("b012345678")]
    public void AcceptsAndNormalizesAsins(string value)
    {
        Assert.True(InputValidation.TryAsin(value, out var asin));
        Assert.Equal("B012345678", asin);
    }
}
