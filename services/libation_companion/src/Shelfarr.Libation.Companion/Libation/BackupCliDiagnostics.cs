namespace Shelfarr.Libation.Companion.Libation;

internal sealed record BackupCliFailure(string Code, string Message);

internal static class BackupCliDiagnostics
{
    public static BackupCliFailure? Classify(CliResult result)
    {
        if (result.ExitCode != 0)
        {
            return new BackupCliFailure(
                "nonzero_exit",
                $"Libation backup failed with exit code {result.ExitCode}.");
        }

        var output = $"{result.StandardOutput}\n{result.StandardError}";
        if (Contains(output, "no ADRM license")
            || Contains(output, "acr:null")
            || Contains(output, "only download with Widevine"))
        {
            return new BackupCliFailure(
                "adrm_unavailable",
                "Audible did not offer an ADRM download for this title. Libation recommends Widevine for this title.");
        }

        if (Contains(output, "Audible denied a content license")
            || Contains(output, "content license denied")
            || Contains(output, "download not allowed for this account/title"))
        {
            return new BackupCliFailure(
                "content_license_denied",
                "Audible denied the download license for this account and title. Confirm that it is still downloadable in the connected marketplace.");
        }

        if (Contains(output, "Cannot find decrypt. Final audio file already exists"))
        {
            return new BackupCliFailure(
                "existing_audio_not_found",
                "Libation believes this title already has audio, but Shelfarr could not find a safe ASIN-tagged artifact in the configured Books directory.");
        }

        if (Contains(output, "Decrypt failed"))
        {
            return new BackupCliFailure(
                "download_or_decrypt_failed",
                "Libation obtained the title license but could not download or decrypt its audio.");
        }

        if (Contains(output, "Validation failed"))
        {
            return new BackupCliFailure(
                "validation_failed",
                "Libation rejected this title before its audio backup could start.");
        }

        if (Contains(output, "not found in library"))
        {
            return new BackupCliFailure(
                "title_not_found",
                "Libation could not find this title in its synced library.");
        }

        if (Contains(output, "Error processing book"))
        {
            return new BackupCliFailure(
                "processing_error",
                "Libation encountered an internal error while processing this title.");
        }

        if (Contains(output, "Books directory is not set"))
        {
            return new BackupCliFailure(
                "books_directory_missing",
                "Libation's Books directory is not configured.");
        }

        if (Contains(output, "Cancelled"))
        {
            return new BackupCliFailure(
                "cancelled",
                "Libation cancelled the title backup before it completed.");
        }

        // Libation 13.5.1 returns exit code 0 for per-title failures. Its
        // actionable failures are written to stderr instead. Never expose that
        // arbitrary text because upstream exception output may include URLs or
        // account details, but do retain that the CLI itself reported a failure.
        if (!string.IsNullOrWhiteSpace(result.StandardError))
        {
            return new BackupCliFailure(
                "unclassified_cli_error",
                "Libation reported an error while processing this title.");
        }

        return null;
    }

    private static bool Contains(string output, string value)
        => output.Contains(value, StringComparison.OrdinalIgnoreCase);
}
