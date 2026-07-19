using System.Text.Json;
using Shelfarr.Libation.Companion.Jobs;
using Shelfarr.Libation.Companion.Libation;

namespace Shelfarr.Libation.Companion.Tests;

public sealed class ApiContractTests
{
    private static readonly JsonSerializerOptions WebJson = new(JsonSerializerDefaults.Web);

    [Fact]
    public void BackupJobUsesArtifactPathsAndStringEnums()
    {
        var job = new CompanionJob(
            "e7ef88d7f1bb4f7ca797dc885b3b9210",
            CompanionJobKind.Backup,
            CompanionJobStatus.Succeeded,
            DateTimeOffset.UtcNow,
            Asin: "B012345678",
            ArtifactPaths: ["Example [B012345678]/Example [B012345678].m4b"]);

        using var json = JsonDocument.Parse(JsonSerializer.Serialize(job, WebJson));

        Assert.Equal("backup", json.RootElement.GetProperty("kind").GetString());
        Assert.Equal("succeeded", json.RootElement.GetProperty("status").GetString());
        Assert.True(json.RootElement.TryGetProperty("artifactPaths", out var artifacts));
        Assert.Equal(JsonValueKind.Array, artifacts.ValueKind);
        Assert.False(json.RootElement.TryGetProperty("outputPaths", out _));
    }

    [Fact]
    public void AccountStatusUsesScanEnabled()
    {
        var status = new AccountStatus("reader@example.com", "Reader", "us", true, true);

        using var json = JsonDocument.Parse(JsonSerializer.Serialize(status, WebJson));

        Assert.True(json.RootElement.GetProperty("scanEnabled").GetBoolean());
        Assert.False(json.RootElement.TryGetProperty("scanLibrary", out _));
    }

    [Fact]
    public void PagedLibraryContractKeepsSnapshotFieldsAndExposesContinuation()
    {
        var page = new LibraryPage(
            1,
            DateTimeOffset.UtcNow,
            CompanionOptions.PinnedLibationVersion,
            0,
            [],
            250,
            250,
            10_000,
            500);

        using var json = JsonDocument.Parse(JsonSerializer.Serialize(page, WebJson));

        Assert.Equal(1, json.RootElement.GetProperty("schemaVersion").GetInt32());
        Assert.Equal(JsonValueKind.Array, json.RootElement.GetProperty("items").ValueKind);
        Assert.Equal(250, json.RootElement.GetProperty("offset").GetInt32());
        Assert.Equal(250, json.RootElement.GetProperty("limit").GetInt32());
        Assert.Equal(10_000, json.RootElement.GetProperty("totalItems").GetInt32());
        Assert.Equal(500, json.RootElement.GetProperty("nextOffset").GetInt32());
    }
}
