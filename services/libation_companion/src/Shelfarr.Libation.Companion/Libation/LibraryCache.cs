using System.Text.Json;
using System.Text.Json.Serialization;

namespace Shelfarr.Libation.Companion.Libation;

public sealed record LibrarySnapshot(
    int SchemaVersion,
    DateTimeOffset GeneratedAt,
    string LibationVersion,
    int SkippedItems,
    IReadOnlyList<OwnedLibraryItem> Items);

public sealed record LibraryPage(
    int SchemaVersion,
    DateTimeOffset GeneratedAt,
    string LibationVersion,
    int SkippedItems,
    IReadOnlyList<OwnedLibraryItem> Items,
    int Offset,
    int Limit,
    int TotalItems,
    int? NextOffset);

public sealed record OwnedLibraryItem(
    string Asin,
    string Locale,
    string Title,
    string Subtitle,
    IReadOnlyList<string> Authors,
    IReadOnlyList<string> Narrators,
    int DurationSeconds,
    string? Publisher,
    string Series,
    string? Language,
    string ContentType,
    string OwnershipType,
    bool Active,
    bool Downloaded,
    bool HasPdf,
    string BookStatus,
    string? PdfStatus,
    DateTimeOffset? PurchasedAt,
    DateTimeOffset? DatePublished,
    DateTimeOffset? LastDownloaded,
    DateTimeOffset? IncludedUntil,
    string? CoverUrl);

public sealed class LibraryCache
{
    public const int DefaultPageSize = 250;
    public const int MaximumPageSize = 1_000;
    public const int MaximumLibraryItems = 100_000;
    public const long MaximumLibraryFileBytes = 512L * 1024 * 1024;

    private const int MaximumTitleCharacters = 4 * 1024;
    private const int MaximumSubtitleCharacters = 4 * 1024;
    private const int MaximumScalarCharacters = 4 * 1024;
    private const int MaximumCoverUrlCharacters = 8 * 1024;
    private const int MaximumNames = 100;
    private const int MaximumNameCharacters = 1 * 1024;
    private const int MaximumNamesSourceCharacters = 64 * 1024;
    private const int MaximumDurationSeconds = 315_576_000;

    private static readonly HashSet<string> AllowedCoverHosts = new(StringComparer.OrdinalIgnoreCase)
    {
        "m.media-amazon.com",
        "images-na.ssl-images-amazon.com",
        "images-eu.ssl-images-amazon.com",
        "images-fe.ssl-images-amazon.com"
    };

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        MaxDepth = 32
    };

    private readonly CompanionOptions _options;
    private readonly SemaphoreSlim _loadGate = new(1, 1);
    private readonly object _stateGate = new();
    private CachedLibrary? _cachedLibrary;
    private readonly Dictionary<string, OwnedLibraryItem> _itemOverrides = new(StringComparer.OrdinalIgnoreCase);
    private long _fullSnapshotReadCount;
    private long _indexedLookupCount;

    public LibraryCache(CompanionOptions options) => _options = options;

    public bool Exists => Volatile.Read(ref _cachedLibrary) is not null || File.Exists(_options.LibraryFile);

    internal long FullSnapshotReadCount => Interlocked.Read(ref _fullSnapshotReadCount);
    internal long IndexedLookupCount => Interlocked.Read(ref _indexedLookupCount);

    public async Task<LibrarySnapshot> RefreshAsync(
        CliCoordinator.CliLease lease,
        CancellationToken cancellationToken)
    {
        var rawPath = Path.Combine(_options.StateDirectory, $"library-{Guid.NewGuid():N}.libation.json");
        try
        {
            var result = await lease.RunAsync(
                ["export", "--path", rawPath, "--json"],
                _options.ShortCliTimeout,
                cancellationToken);
            if (result.ExitCode != 0)
                throw new InvalidOperationException($"Libation library export failed with exit code {result.ExitCode}.");
            if (!File.Exists(rawPath))
                throw new InvalidOperationException("Libation completed without creating a library export.");

            var snapshot = await NormalizeAsync(rawPath, cancellationToken);
            await WriteAtomicallyAsync(snapshot, cancellationToken);
            await PublishAsync(snapshot, cancellationToken);
            return snapshot;
        }
        finally
        {
            File.Delete(rawPath);
        }
    }

    public FileStream OpenRead()
    {
        if (!Exists)
            throw new FileNotFoundException("The Audible library has not been synced yet.", _options.LibraryFile);

        return new FileStream(_options.LibraryFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
    }

    public async Task<LibrarySnapshot?> ReadAsync(CancellationToken cancellationToken)
    {
        var cached = await GetCachedLibraryAsync(cancellationToken);
        if (cached is null)
            return null;

        lock (_stateGate)
        {
            if (_itemOverrides.Count == 0)
                return cached.Snapshot;

            return cached.Snapshot with
            {
                Items = cached.Snapshot.Items
                    .Select(item => _itemOverrides.GetValueOrDefault(item.Asin, item))
                    .ToArray()
            };
        }
    }

    public async Task<OwnedLibraryItem> RequirePurchasedActiveTitleAsync(
        string asin,
        CancellationToken cancellationToken)
    {
        var cached = await GetCachedLibraryAsync(cancellationToken);
        if (cached is null)
            throw new BackupNotEligibleException("The Audible library must be synced before starting a backup.");

        Interlocked.Increment(ref _indexedLookupCount);
        lock (_stateGate)
        {
            var item = _itemOverrides.GetValueOrDefault(asin)
                ?? cached.ItemsByAsin.GetValueOrDefault(asin);
            return BackupEligibility.RequirePurchasedActiveTitle(item, asin, libraryExists: true);
        }
    }

    public async Task<LibraryPage?> ReadPageAsync(
        int offset,
        int limit,
        CancellationToken cancellationToken)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(offset);
        if (limit is < 1 or > MaximumPageSize)
            throw new ArgumentOutOfRangeException(nameof(limit));

        var cached = await GetCachedLibraryAsync(cancellationToken);
        if (cached is null)
            return null;

        var total = cached.Snapshot.Items.Count;
        var count = Math.Min(limit, Math.Max(0, total - offset));
        var pageItems = new OwnedLibraryItem[count];
        lock (_stateGate)
        {
            for (var index = 0; index < count; index++)
            {
                var item = cached.Snapshot.Items[offset + index];
                pageItems[index] = _itemOverrides.GetValueOrDefault(item.Asin, item);
            }
        }

        var nextOffset = offset + count < total ? offset + count : (int?)null;
        return new LibraryPage(
            cached.Snapshot.SchemaVersion,
            cached.Snapshot.GeneratedAt,
            cached.Snapshot.LibationVersion,
            cached.Snapshot.SkippedItems,
            pageItems,
            offset,
            limit,
            total,
            nextOffset);
    }

    public async Task<OwnedLibraryItem> RefreshItemAsync(
        CliCoordinator.CliLease lease,
        string asin,
        CancellationToken cancellationToken)
    {
        var rawPath = Path.Combine(_options.StateDirectory, $"library-item-{Guid.NewGuid():N}.libation.json");
        try
        {
            var result = await lease.RunAsync(
                ["export", "--path", rawPath, "--json", asin],
                _options.ShortCliTimeout,
                cancellationToken);
            if (result.ExitCode != 0)
                throw new InvalidOperationException($"Libation title export failed with exit code {result.ExitCode}.");
            if (!File.Exists(rawPath))
                throw new InvalidOperationException("Libation completed without creating the requested title export.");

            var snapshot = await NormalizeAsync(rawPath, cancellationToken);
            var item = BackupEligibility.RequirePurchasedActiveTitle(snapshot, asin);
            lock (_stateGate)
                _itemOverrides[asin] = item;
            return item;
        }
        finally
        {
            File.Delete(rawPath);
        }
    }

    private async Task<CachedLibrary?> GetCachedLibraryAsync(CancellationToken cancellationToken)
    {
        var cached = Volatile.Read(ref _cachedLibrary);
        if (cached is not null)
            return cached;

        await _loadGate.WaitAsync(cancellationToken);
        try
        {
            cached = Volatile.Read(ref _cachedLibrary);
            if (cached is not null || !File.Exists(_options.LibraryFile))
                return cached;

            EnsureFileWithinBudget(_options.LibraryFile);
            await using var stream = OpenRead();
            var snapshot = await JsonSerializer.DeserializeAsync<LibrarySnapshot>(stream, JsonOptions, cancellationToken)
                ?? throw new InvalidDataException("The cached Audible library is empty.");
            Interlocked.Increment(ref _fullSnapshotReadCount);
            Validate(snapshot);
            cached = CreateCachedLibrary(snapshot);
            Volatile.Write(ref _cachedLibrary, cached);
            return cached;
        }
        finally
        {
            _loadGate.Release();
        }
    }

    private async Task PublishAsync(LibrarySnapshot snapshot, CancellationToken cancellationToken)
    {
        var cached = CreateCachedLibrary(snapshot);
        await _loadGate.WaitAsync(cancellationToken);
        try
        {
            lock (_stateGate)
            {
                _itemOverrides.Clear();
                Volatile.Write(ref _cachedLibrary, cached);
            }
        }
        finally
        {
            _loadGate.Release();
        }
    }

    private static CachedLibrary CreateCachedLibrary(LibrarySnapshot snapshot)
    {
        Validate(snapshot);
        var index = new Dictionary<string, OwnedLibraryItem>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in snapshot.Items)
            index.TryAdd(item.Asin, item);
        return new CachedLibrary(snapshot, index);
    }

    private static void Validate(LibrarySnapshot snapshot)
    {
        if (snapshot.SchemaVersion != 1
            || snapshot.Items is null
            || snapshot.SkippedItems < 0
            || string.IsNullOrWhiteSpace(snapshot.LibationVersion)
            || snapshot.LibationVersion.Length > 200)
            throw new InvalidDataException("The cached Audible library has an unsupported schema.");
        if (snapshot.Items.Count > MaximumLibraryItems)
            throw new InvalidDataException($"The cached Audible library exceeds the {MaximumLibraryItems} title limit.");

        var seenAsins = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in snapshot.Items)
        {
            ValidateNormalizedItem(item);
            if (!seenAsins.Add(item.Asin))
                throw new InvalidDataException("The cached Audible library contains a duplicate ASIN.");
        }
    }

    public static async Task<LibrarySnapshot> NormalizeAsync(string rawPath, CancellationToken cancellationToken)
    {
        EnsureFileWithinBudget(rawPath);
        await using var stream = File.OpenRead(rawPath);
        using var document = await JsonDocument.ParseAsync(
            stream,
            new JsonDocumentOptions { MaxDepth = 32 },
            cancellationToken);
        if (document.RootElement.ValueKind != JsonValueKind.Array)
            throw new InvalidDataException("Libation's JSON export must be an array.");

        var itemsByAsin = new Dictionary<string, OwnedLibraryItem>(StringComparer.OrdinalIgnoreCase);
        var skippedItems = 0;
        var sourceItems = 0;
        foreach (var source in document.RootElement.EnumerateArray())
        {
            sourceItems++;
            if (sourceItems > MaximumLibraryItems)
                throw new InvalidDataException($"Libation's JSON export exceeds the {MaximumLibraryItems} title limit.");
            if (source.ValueKind != JsonValueKind.Object)
                throw new InvalidDataException("Libation's JSON export contains a non-object item.");

            var asin = String(source, "AudibleProductId", 32).ToUpperInvariant();
            if (!InputValidation.TryAsin(asin, out asin))
            {
                skippedItems++;
                continue;
            }

            var contentType = String(source, "ContentType", 100);
            if (!contentType.Equals("Product", StringComparison.OrdinalIgnoreCase))
            {
                skippedItems++;
                continue;
            }

            var isAudiblePlus = Boolean(source, "IsAudiblePlus");
            var absentFromLastScan = Boolean(source, "AbsentFromLastScan");
            var bookStatus = String(source, "BookStatus", 100);
            var durationSeconds = DurationSeconds(source);

            var item = new OwnedLibraryItem(
                asin,
                String(source, "Locale", 32),
                RequiredString(source, "Title", MaximumTitleCharacters),
                String(source, "Subtitle", MaximumSubtitleCharacters),
                Names(source, "AuthorNames"),
                Names(source, "NarratorNames"),
                durationSeconds,
                NullableString(source, "Publisher", MaximumScalarCharacters),
                String(source, "SeriesNames", MaximumScalarCharacters),
                NullableString(source, "Language", 100),
                contentType,
                isAudiblePlus ? "subscription" : "purchased",
                !absentFromLastScan,
                bookStatus.Equals("Liberated", StringComparison.OrdinalIgnoreCase),
                Boolean(source, "HasPdf"),
                bookStatus,
                NullableString(source, "PdfStatus"),
                Date(source, "DateAdded"),
                Date(source, "DatePublished"),
                Date(source, "LastDownloaded"),
                Date(source, "IncludedUntil"),
                CoverUrl(source));
            ValidateNormalizedItem(item);

            if (itemsByAsin.TryGetValue(asin, out var existing))
                itemsByAsin[asin] = MergeDuplicate(existing, item);
            else
                itemsByAsin.Add(asin, item);
        }

        return new LibrarySnapshot(
            1,
            DateTimeOffset.UtcNow,
            CompanionOptions.PinnedLibationVersion,
            skippedItems,
            itemsByAsin.Values.ToArray());
    }

    private async Task WriteAtomicallyAsync(LibrarySnapshot snapshot, CancellationToken cancellationToken)
    {
        var temporary = $"{_options.LibraryFile}.{Guid.NewGuid():N}.tmp";
        try
        {
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                await JsonSerializer.SerializeAsync(stream, snapshot, JsonOptions, cancellationToken);
                await stream.FlushAsync(cancellationToken);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, _options.LibraryFile, overwrite: true);
        }
        finally
        {
            File.Delete(temporary);
        }
    }

    private static string String(JsonElement source, string name, int maximumCharacters = MaximumScalarCharacters)
        => NullableString(source, name, maximumCharacters) ?? string.Empty;

    private static string RequiredString(JsonElement source, string name, int maximumCharacters)
    {
        var value = NullableString(source, name, maximumCharacters);
        if (string.IsNullOrWhiteSpace(value))
            throw new InvalidDataException($"Libation's JSON export contains an invalid {name} value.");

        return value;
    }

    private static string? NullableString(
        JsonElement source,
        string name,
        int maximumCharacters = MaximumScalarCharacters)
    {
        if (!source.TryGetProperty(name, out var value) || value.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)
            return null;
        if (value.ValueKind != JsonValueKind.String)
            throw new InvalidDataException($"Libation's JSON export contains a non-string {name} value.");

        var parsed = value.GetString();
        if (parsed is not null && parsed.Length > maximumCharacters)
            throw new InvalidDataException($"Libation's JSON export contains an oversized {name} value.");
        return parsed;
    }

    private static string? CoverUrl(JsonElement source)
    {
        var value = NullableString(source, "PictureLarge", MaximumCoverUrlCharacters)
            ?? NullableString(source, "PictureId", 128);
        value = value?.Trim();
        if (string.IsNullOrWhiteSpace(value))
            return null;

        if (Uri.TryCreate(value, UriKind.Absolute, out var uri) && IsSafeCoverUri(uri))
            return uri.AbsoluteUri;

        // Some Libation exports expose Amazon's image identifier instead of a
        // complete URL. Keep this conversion at the companion boundary so the
        // Shelfarr catalog always receives a browser-loadable cover URL.
        if (value.Length is >= 6 and <= 128
            && value.All(character => char.IsAsciiLetterOrDigit(character) || character is '-' or '_' or '+'))
            return $"https://m.media-amazon.com/images/I/{value}._SL500_.jpg";

        return null;
    }

    private static bool Boolean(JsonElement source, string name)
    {
        if (!source.TryGetProperty(name, out var value)
            || value.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)
            return false;
        if (value.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            throw new InvalidDataException($"Libation's JSON export contains a non-boolean {name} value.");

        return value.GetBoolean();
    }

    private static int Integer(JsonElement source, string name)
    {
        if (!source.TryGetProperty(name, out var value)
            || value.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)
            return 0;
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var parsed))
            throw new InvalidDataException($"Libation's JSON export contains an invalid {name} value.");

        return parsed;
    }

    private static int DurationSeconds(JsonElement source)
    {
        var minutes = Integer(source, "LengthInMinutes");
        if (minutes < 0 || minutes > MaximumDurationSeconds / 60)
            throw new InvalidDataException("Libation's JSON export contains an invalid audiobook duration.");

        return checked(minutes * 60);
    }

    private static IReadOnlyList<string> Names(JsonElement source, string name)
    {
        var values = String(source, name, MaximumNamesSourceCharacters)
            .Split([", ", ";"], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .ToArray();
        if (values.Length > MaximumNames || values.Any(value => value.Length > MaximumNameCharacters))
            throw new InvalidDataException($"Libation's JSON export contains invalid {name} values.");

        return values;
    }

    private static DateTimeOffset? Date(JsonElement source, string name)
    {
        if (!source.TryGetProperty(name, out var value)
            || value.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)
            return null;
        if (value.ValueKind != JsonValueKind.String || !value.TryGetDateTimeOffset(out var parsed))
            throw new InvalidDataException($"Libation's JSON export contains an invalid {name} value.");

        return parsed;
    }

    private static OwnedLibraryItem MergeDuplicate(OwnedLibraryItem existing, OwnedLibraryItem candidate)
    {
        var downloaded = existing.Downloaded || candidate.Downloaded;
        var candidateIsPurchased = candidate.OwnershipType.Equals("purchased", StringComparison.OrdinalIgnoreCase);
        return existing with
        {
            Locale = Preferred(existing.Locale, candidate.Locale),
            Title = Preferred(existing.Title, candidate.Title),
            Subtitle = Preferred(existing.Subtitle, candidate.Subtitle),
            Authors = existing.Authors.Count > 0 ? existing.Authors : candidate.Authors,
            Narrators = existing.Narrators.Count > 0 ? existing.Narrators : candidate.Narrators,
            DurationSeconds = Math.Max(existing.DurationSeconds, candidate.DurationSeconds),
            Publisher = existing.Publisher ?? candidate.Publisher,
            Series = Preferred(existing.Series, candidate.Series),
            Language = existing.Language ?? candidate.Language,
            OwnershipType = candidateIsPurchased ? "purchased" : existing.OwnershipType,
            Active = existing.Active || candidate.Active,
            Downloaded = downloaded,
            HasPdf = existing.HasPdf || candidate.HasPdf,
            BookStatus = candidate.Downloaded ? candidate.BookStatus : existing.BookStatus,
            PdfStatus = existing.PdfStatus ?? candidate.PdfStatus,
            PurchasedAt = Minimum(existing.PurchasedAt, candidate.PurchasedAt),
            DatePublished = Minimum(existing.DatePublished, candidate.DatePublished),
            LastDownloaded = Maximum(existing.LastDownloaded, candidate.LastDownloaded),
            IncludedUntil = Maximum(existing.IncludedUntil, candidate.IncludedUntil),
            CoverUrl = existing.CoverUrl ?? candidate.CoverUrl
        };
    }

    private static string Preferred(string existing, string candidate)
        => !string.IsNullOrWhiteSpace(existing) ? existing : candidate;

    private static DateTimeOffset? Minimum(DateTimeOffset? left, DateTimeOffset? right)
        => left is null ? right : right is null ? left : (left <= right ? left : right);

    private static DateTimeOffset? Maximum(DateTimeOffset? left, DateTimeOffset? right)
        => left is null ? right : right is null ? left : (left >= right ? left : right);

    private static void ValidateNormalizedItem(OwnedLibraryItem? item)
    {
        if (item is null
            || !InputValidation.TryAsin(item.Asin, out _)
            || string.IsNullOrWhiteSpace(item.Title)
            || item.Title.Length > MaximumTitleCharacters
            || item.Locale is null
            || item.Locale.Length > 32
            || item.Subtitle is null
            || item.Subtitle.Length > MaximumSubtitleCharacters
            || item.Authors is null
            || item.Narrators is null
            || item.Authors.Count > MaximumNames
            || item.Narrators.Count > MaximumNames
            || item.Authors.Any(value => string.IsNullOrWhiteSpace(value) || value.Length > MaximumNameCharacters)
            || item.Narrators.Any(value => string.IsNullOrWhiteSpace(value) || value.Length > MaximumNameCharacters)
            || item.DurationSeconds is < 0 or > MaximumDurationSeconds
            || (item.Publisher?.Length ?? 0) > MaximumScalarCharacters
            || item.Series is null
            || item.Series.Length > MaximumScalarCharacters
            || (item.Language?.Length ?? 0) > 100
            || !string.Equals(item.ContentType, "Product", StringComparison.OrdinalIgnoreCase)
            || item.OwnershipType is not ("purchased" or "subscription")
            || item.BookStatus is null
            || item.BookStatus.Length > 100
            || (item.PdfStatus?.Length ?? 0) > MaximumScalarCharacters
            || !ValidCoverUrl(item.CoverUrl))
            throw new InvalidDataException("The cached Audible library contains an invalid normalized title.");
    }

    private static bool ValidCoverUrl(string? value)
    {
        if (value is null)
            return true;
        if (value.Length > MaximumCoverUrlCharacters
            || !Uri.TryCreate(value, UriKind.Absolute, out var uri))
            return false;

        return IsSafeCoverUri(uri);
    }

    private static bool IsSafeCoverUri(Uri uri)
    {
        return uri.Scheme == Uri.UriSchemeHttps
            && uri.IsDefaultPort
            && string.IsNullOrEmpty(uri.UserInfo)
            && AllowedCoverHosts.Contains(uri.IdnHost)
            && uri.AbsolutePath.StartsWith("/images/", StringComparison.Ordinal);
    }

    private static void EnsureFileWithinBudget(string path)
    {
        var length = new FileInfo(path).Length;
        if (length > MaximumLibraryFileBytes)
            throw new InvalidDataException(
                $"The Audible library file exceeds the {MaximumLibraryFileBytes / (1024 * 1024)} MB limit.");
    }

    private sealed record CachedLibrary(
        LibrarySnapshot Snapshot,
        IReadOnlyDictionary<string, OwnedLibraryItem> ItemsByAsin);
}
