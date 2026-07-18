using Shelfarr.Libation.Companion.Libation;

namespace Shelfarr.Libation.Companion.Tests;

public sealed class BackupCliDiagnosticsTests
{
    [Theory]
    [InlineData(
        "12 Rules: Audible returned no ADRM license (Sable acr:null). Some rare titles only download with Widevine.",
        "adrm_unavailable")]
    [InlineData(
        "Audible denied a content license (download not allowed for this account/title).",
        "content_license_denied")]
    [InlineData("Cannot find decrypt. Final audio file already exists", "existing_audio_not_found")]
    [InlineData("Decrypt failed", "download_or_decrypt_failed")]
    [InlineData("Validation failed", "validation_failed")]
    [InlineData("Book with ASIN 'B012345678' not found in library. Skipping.", "title_not_found")]
    [InlineData("Error processing book. Skipping.", "processing_error")]
    public void ClassifiesLibationsExitZeroPerTitleFailures(string standardError, string expectedCode)
    {
        var failure = BackupCliDiagnostics.Classify(new CliResult(0, "", standardError));

        Assert.NotNull(failure);
        Assert.Equal(expectedCode, failure.Code);
    }

    [Fact]
    public void DoesNotExposeUnknownUpstreamErrorText()
    {
        const string sensitive = "unexpected error at https://signed.example/?token=secret";

        var failure = BackupCliDiagnostics.Classify(new CliResult(0, "", sensitive));

        Assert.NotNull(failure);
        Assert.Equal("unclassified_cli_error", failure.Code);
        Assert.DoesNotContain("secret", failure.Message, StringComparison.Ordinal);
        Assert.DoesNotContain("https", failure.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void AcceptsOrdinarySuccessfulCliOutput()
    {
        var failure = BackupCliDiagnostics.Classify(new CliResult(
            0,
            "DownloadDecryptBook Completed: Example\nDone. All books have been processed",
            ""));

        Assert.Null(failure);
    }
}
