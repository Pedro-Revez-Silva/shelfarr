using System.Text.Json;
using Shelfarr.Libation.Companion.Libation;

namespace Shelfarr.Libation.Companion.Tests;

public sealed class LibraryCacheTests
{
    private static readonly JsonSerializerOptions WebJson = new(JsonSerializerDefaults.Web);

    [Fact]
    public async Task NormalizesTheRailsContractAndSkipsMalformedProductIds()
    {
        using var temporary = new TemporaryDirectory();
        var raw = Path.Combine(temporary.Path, "library.json");
        await File.WriteAllTextAsync(raw, """
        [
          {
            "Account": "reader@example.com",
            "DateAdded": "2024-02-03T12:00:00Z",
            "IsAudiblePlus": false,
            "AbsentFromLastScan": false,
            "AudibleProductId": "B012345678",
            "Locale": "us",
            "Title": "Example",
            "Subtitle": "A test",
            "AuthorNames": "One Author, Two Author",
            "NarratorNames": "One Narrator",
            "LengthInMinutes": 61,
            "Description": "This full description must not enter the bounded Shelfarr contract.",
            "HasPdf": true,
            "BookStatus": "Liberated",
            "ContentType": "Product",
            "PictureLarge": "https://m.media-amazon.com/images/I/example-cover.jpg"
          },
          {
            "AudibleProductId": "not-an-asin",
            "Title": "Malformed upstream item"
          },
          {
            "AudibleProductId": "B087654321",
            "Title": "An existing podcast episode",
            "ContentType": "Episode"
          }
        ]
        """);

        var snapshot = await Libation.LibraryCache.NormalizeAsync(raw, CancellationToken.None);

        Assert.Equal(2, snapshot.SkippedItems);
        var item = Assert.Single(snapshot.Items);
        Assert.Equal("B012345678", item.Asin);
        Assert.Equal(["One Author", "Two Author"], item.Authors);
        Assert.Equal(["One Narrator"], item.Narrators);
        Assert.Equal(3660, item.DurationSeconds);
        Assert.Equal("purchased", item.OwnershipType);
        Assert.True(item.Active);
        Assert.True(item.Downloaded);
        Assert.Equal(DateTimeOffset.Parse("2024-02-03T12:00:00Z"), item.PurchasedAt);
        Assert.Equal("https://m.media-amazon.com/images/I/example-cover.jpg", item.CoverUrl);

        var serialized = JsonSerializer.Serialize(snapshot, new JsonSerializerOptions(JsonSerializerDefaults.Web));
        using var json = JsonDocument.Parse(serialized);
        var serializedItem = json.RootElement.GetProperty("items")[0];
        Assert.True(serializedItem.TryGetProperty("durationSeconds", out _));
        Assert.True(serializedItem.TryGetProperty("ownershipType", out _));
        Assert.True(serializedItem.TryGetProperty("purchasedAt", out _));
        Assert.False(serializedItem.TryGetProperty("lengthMinutes", out _));
        Assert.False(serializedItem.TryGetProperty("account", out _));
        Assert.False(serializedItem.TryGetProperty("description", out _));
    }

    [Fact]
    public async Task ExpandsAnAmazonPictureIdentifierIntoACoverUrl()
    {
        using var temporary = new TemporaryDirectory();
        var raw = Path.Combine(temporary.Path, "library.json");
        await File.WriteAllTextAsync(raw, """
        [
          {
            "AudibleProductId": "B012345678",
            "Title": "Example",
            "ContentType": "Product",
            "PictureId": "71YfEidUvAL"
          }
        ]
        """);

        var snapshot = await Libation.LibraryCache.NormalizeAsync(raw, CancellationToken.None);

        var item = Assert.Single(snapshot.Items);
        Assert.Equal(
            "https://m.media-amazon.com/images/I/71YfEidUvAL._SL500_.jpg",
            item.CoverUrl);
    }

    [Theory]
    [InlineData("http://m.media-amazon.com/images/I/cover.jpg")]
    [InlineData("https://reader@m.media-amazon.com/images/I/cover.jpg")]
    [InlineData("https://m.media-amazon.com:444/images/I/cover.jpg")]
    [InlineData("https://m.media-amazon.com.attacker.test/images/I/cover.jpg")]
    [InlineData("https://127.0.0.1/images/I/cover.jpg")]
    [InlineData("https://m.media-amazon.com/private-service")]
    public async Task DropsAnUnsafePictureUrl(string pictureUrl)
    {
        using var temporary = new TemporaryDirectory();
        var raw = Path.Combine(temporary.Path, "library.json");
        await File.WriteAllTextAsync(raw, $$"""
        [{
          "AudibleProductId":"B012345678",
          "Title":"Example",
          "ContentType":"Product",
          "PictureLarge":{{JsonSerializer.Serialize(pictureUrl)}}
        }]
        """);

        var snapshot = await Libation.LibraryCache.NormalizeAsync(raw, CancellationToken.None);

        Assert.Null(Assert.Single(snapshot.Items).CoverUrl);
    }

    [Fact]
    public async Task RejectsOversizedOrMalformedUpstreamMetadata()
    {
        using var temporary = new TemporaryDirectory();
        var raw = Path.Combine(temporary.Path, "library.json");
        await File.WriteAllTextAsync(raw, $$"""
        [{
          "AudibleProductId":"B012345678",
          "ContentType":"Product",
          "Title":"{{new string('x', 4 * 1024 + 1)}}",
          "IsAudiblePlus":false
        }]
        """);

        await Assert.ThrowsAsync<InvalidDataException>(() =>
            Libation.LibraryCache.NormalizeAsync(raw, CancellationToken.None));

        await File.WriteAllTextAsync(raw, """
        [{
          "AudibleProductId":"B012345678",
          "ContentType":"Product",
          "Title":"Example",
          "IsAudiblePlus":"false"
        }]
        """);
        await Assert.ThrowsAsync<InvalidDataException>(() =>
            Libation.LibraryCache.NormalizeAsync(raw, CancellationToken.None));
    }

    [Fact]
    public async Task RejectsAnExportBeforeParsingWhenItsFileExceedsTheBudget()
    {
        using var temporary = new TemporaryDirectory();
        var raw = Path.Combine(temporary.Path, "library.json");
        await using (var stream = new FileStream(raw, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            stream.SetLength(Libation.LibraryCache.MaximumLibraryFileBytes + 1);

        await Assert.ThrowsAsync<InvalidDataException>(() =>
            Libation.LibraryCache.NormalizeAsync(raw, CancellationToken.None));
    }

    [Fact]
    public async Task MergesDuplicateAsinsToOneConservativePurchasedActiveTitle()
    {
        using var temporary = new TemporaryDirectory();
        var raw = Path.Combine(temporary.Path, "library.json");
        await File.WriteAllTextAsync(raw, """
        [
          {
            "AudibleProductId":"B012345678",
            "ContentType":"Product",
            "Title":"Example",
            "IsAudiblePlus":true,
            "AbsentFromLastScan":true,
            "BookStatus":"NotLiberated"
          },
          {
            "AudibleProductId":"B012345678",
            "ContentType":"Product",
            "Title":"Example purchased copy",
            "IsAudiblePlus":false,
            "AbsentFromLastScan":false,
            "BookStatus":"Liberated"
          }
        ]
        """);

        var snapshot = await Libation.LibraryCache.NormalizeAsync(raw, CancellationToken.None);

        var item = Assert.Single(snapshot.Items);
        Assert.Equal("purchased", item.OwnershipType);
        Assert.True(item.Active);
        Assert.True(item.Downloaded);
        Assert.Equal("Liberated", item.BookStatus);
    }

    [Fact]
    public async Task RejectsCorruptedNormalizedCacheFieldsBeforeServingThem()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var invalidItems = new[]
        {
            Item("B012345678") with { Series = new string('x', 4 * 1024 + 1) },
            Item("B012345678") with { CoverUrl = "https://127.0.0.1/images/I/private.jpg" }
        };

        foreach (var invalid in invalidItems)
        {
            await File.WriteAllTextAsync(
                options.LibraryFile,
                JsonSerializer.Serialize(Snapshot(invalid), WebJson));

            await Assert.ThrowsAsync<InvalidDataException>(() =>
                new Libation.LibraryCache(options).ReadAsync(CancellationToken.None));
        }
    }

    [Fact]
    public async Task BuildsOneIndexAndKeepsHighVolumeBackupAdmissionToOneProbePerRequest()
    {
        const int itemCount = 25_000;
        const int lookupCount = 5_000;
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var items = Enumerable.Range(0, itemCount)
            .Select(index => Item($"B{index:D9}"))
            .ToArray();
        await File.WriteAllTextAsync(
            options.LibraryFile,
            JsonSerializer.Serialize(Snapshot(items), WebJson));
        var cache = new Libation.LibraryCache(options);

        for (var index = 0; index < lookupCount; index++)
        {
            var expected = (index * 7_919) % itemCount;
            var item = await cache.RequirePurchasedActiveTitleAsync(
                $"B{expected:D9}",
                CancellationToken.None);
            Assert.Equal($"B{expected:D9}", item.Asin);
        }

        Assert.Equal(1, cache.FullSnapshotReadCount);
        Assert.Equal(lookupCount, cache.IndexedLookupCount);
    }

    [Fact]
    public async Task ReturnsBoundedPagesFromALargeCachedLibrary()
    {
        const int itemCount = 25_000;
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var items = Enumerable.Range(0, itemCount)
            .Select(index => Item($"B{index:D9}"))
            .ToArray();
        await File.WriteAllTextAsync(
            options.LibraryFile,
            JsonSerializer.Serialize(Snapshot(items), WebJson));
        var cache = new Libation.LibraryCache(options);

        var page = await cache.ReadPageAsync(12_345, 250, CancellationToken.None);

        Assert.NotNull(page);
        Assert.Equal(250, page.Items.Count);
        Assert.Equal("B000012345", page.Items[0].Asin);
        Assert.Equal("B000012594", page.Items[^1].Asin);
        Assert.Equal(itemCount, page.TotalItems);
        Assert.Equal(12_595, page.NextOffset);
        Assert.Equal(1, cache.FullSnapshotReadCount);
    }

    [Fact]
    public async Task RefreshesOnlyTheRequestedTitleAfterABackup()
    {
        if (OperatingSystem.IsWindows())
            return;

        using var temporary = new TemporaryDirectory();
        var marker = Path.Combine(temporary.Path, "arguments.txt");
        var cliPath = Path.Combine(temporary.Path, "libation-cli-test");
        File.WriteAllText(cliPath, $$"""
        #!/bin/sh
        printf '%s\n' "$@" > '{{marker}}'
        output=''
        previous=''
        for argument in "$@"; do
          if [ "$previous" = '--path' ]; then output="$argument"; fi
          previous="$argument"
        done
        cat > "$output" <<'JSON'
        [{"AudibleProductId":"B012345678","ContentType":"Product","Title":"Example","BookStatus":"Liberated"}]
        JSON
        """);
        File.SetUnixFileMode(
            cliPath,
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var options = TestOptions.Create(temporary.Path) with { LibationCliPath = cliPath };
        options.EnsureDirectories();
        var coordinator = new Libation.CliCoordinator(options);
        var cache = new Libation.LibraryCache(options);
        await using var lease = await coordinator.AcquireAsync(CancellationToken.None);

        var item = await cache.RefreshItemAsync(lease, "B012345678", CancellationToken.None);

        Assert.Equal("Liberated", item.BookStatus);
        var arguments = await File.ReadAllLinesAsync(marker);
        Assert.Equal("export", arguments[0]);
        var jsonFlag = Array.IndexOf(arguments, "--json");
        Assert.True(jsonFlag >= 0);
        Assert.Equal("B012345678", arguments[jsonFlag + 1]);
    }

    private static LibrarySnapshot Snapshot(params OwnedLibraryItem[] items)
        => new(1, DateTimeOffset.UtcNow, CompanionOptions.PinnedLibationVersion, 0, items);

    private static OwnedLibraryItem Item(string asin) => new(
        asin,
        "us",
        $"Title {asin}",
        "",
        ["An Author"],
        ["A Narrator"],
        3600,
        null,
        "",
        "en",
        "Product",
        "purchased",
        true,
        false,
        false,
        "NotLiberated",
        null,
        DateTimeOffset.UtcNow,
        null,
        null,
        null,
        null);
}
