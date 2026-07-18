namespace Shelfarr.Libation.Companion.Libation;

public sealed class OutputFileLocator
{
    private const int DefaultMaximumTraversalEntries = 100_000;
    public const int MaximumOutputPaths = 100;
    public const int MaximumRelativePathCharacters = 4 * 1024;
    private static readonly HashSet<string> AudioExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".m4b", ".m4a", ".mp3"
    };

    private readonly string _root;
    private readonly string _rootPrefix;
    private readonly int _maximumTraversalEntries;
    private readonly StringComparer _pathComparer;

    public OutputFileLocator(CompanionOptions options)
        : this(options, DefaultMaximumTraversalEntries)
    {
    }

    internal OutputFileLocator(CompanionOptions options, int maximumTraversalEntries)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maximumTraversalEntries);

        _root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(options.BooksDirectory));
        _rootPrefix = _root + Path.DirectorySeparatorChar;
        _maximumTraversalEntries = maximumTraversalEntries;
        _pathComparer = OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;
    }

    public IReadOnlyList<string> FindForAsin(string asin)
    {
        if (!InputValidation.TryAsin(asin, out asin))
            throw new ArgumentException("A valid Audible ASIN is required.", nameof(asin));
        if (!Directory.Exists(_root))
            return [];

        var budget = new TraversalBudget(_maximumTraversalEntries);
        var matches = new HashSet<string>(_pathComparer);
        var scannedDirectories = new HashSet<string>(_pathComparer);
        var asinToken = $"[{asin}]";

        // Shelfarr forces Libation's folder and file templates to include [ASIN].
        // Ask the filesystem for those top-level candidates before considering a
        // legacy full-tree layout, so an ordinary backup does not walk the library.
        foreach (var candidate in SafeEntries(new DirectoryInfo(_root), $"*{asinToken}*", budget))
        {
            if (IsLink(candidate) || !IsInsideRoot(candidate.FullName))
                continue;

            if (candidate is DirectoryInfo directory)
                CollectAllFiles(directory, budget, matches, scannedDirectories);
            else if (candidate is FileInfo file && TryGetRelativePath(file, out var relative))
                AddMatch(matches, relative);
        }

        if (ContainsAudio(matches))
            return Sorted(matches);

        // Existing installations may have used older templates without the exact
        // [ASIN] top-level name. Retain compatibility, but fail safely instead of
        // permitting an unbounded traversal of a very large library.
        var directories = new Stack<DirectoryInfo>();
        directories.Push(new DirectoryInfo(_root));

        while (directories.TryPop(out var directory))
        {
            if (IsLink(directory) || !scannedDirectories.Add(directory.FullName))
                continue;

            foreach (var child in SafeEntries(directory, "*", budget))
            {
                if (IsLink(child) || !IsInsideRoot(child.FullName))
                    continue;

                if (child is DirectoryInfo childDirectory)
                {
                    directories.Push(childDirectory);
                    continue;
                }

                if (child is FileInfo file
                    && TryGetRelativePath(file, out var relative)
                    && relative.Contains(asin, StringComparison.OrdinalIgnoreCase))
                    AddMatch(matches, relative);
            }
        }

        return Sorted(matches);
    }

    public static bool ContainsAudio(IReadOnlyCollection<string> paths)
        => paths.Any(path => AudioExtensions.Contains(Path.GetExtension(path)));

    private void CollectAllFiles(
        DirectoryInfo root,
        TraversalBudget budget,
        HashSet<string> matches,
        HashSet<string> scannedDirectories)
    {
        var directories = new Stack<DirectoryInfo>();
        directories.Push(root);

        while (directories.TryPop(out var directory))
        {
            if (IsLink(directory) || !scannedDirectories.Add(directory.FullName))
                continue;

            foreach (var child in SafeEntries(directory, "*", budget))
            {
                if (IsLink(child) || !IsInsideRoot(child.FullName))
                    continue;

                if (child is DirectoryInfo childDirectory)
                    directories.Push(childDirectory);
                else if (child is FileInfo file && TryGetRelativePath(file, out var relative))
                    AddMatch(matches, relative);
            }
        }
    }

    private bool TryGetRelativePath(FileInfo file, out string relative)
    {
        relative = string.Empty;
        if (IsLink(file) || !file.Exists || !IsInsideRoot(file.FullName))
            return false;

        var candidate = Path.GetRelativePath(_root, file.FullName);
        if (Path.IsPathFullyQualified(candidate)
            || candidate.Equals("..", StringComparison.Ordinal)
            || candidate.StartsWith($"..{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
            return false;

        relative = candidate.Replace(Path.DirectorySeparatorChar, '/');
        return true;
    }

    private bool IsInsideRoot(string path)
    {
        var full = Path.GetFullPath(path);
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        return full.StartsWith(_rootPrefix, comparison);
    }

    private static void AddMatch(HashSet<string> matches, string relative)
    {
        if (relative.Length > MaximumRelativePathCharacters)
            throw new InvalidOperationException("A Libation output path exceeded the safe length limit.");
        if (matches.Add(relative) && matches.Count > MaximumOutputPaths)
            throw new InvalidOperationException(
                $"Libation produced more than the safe limit of {MaximumOutputPaths} output files for one title.");
    }

    private static bool IsLink(FileSystemInfo entry)
    {
        try
        {
            return entry.LinkTarget is not null || entry.Attributes.HasFlag(FileAttributes.ReparsePoint);
        }
        catch (IOException)
        {
            return true;
        }
        catch (UnauthorizedAccessException)
        {
            return true;
        }
    }

    private static IReadOnlyList<FileSystemInfo> SafeEntries(
        DirectoryInfo directory,
        string searchPattern,
        TraversalBudget budget)
    {
        var entries = new List<FileSystemInfo>();
        var enumerationOptions = new EnumerationOptions
        {
            AttributesToSkip = 0,
            IgnoreInaccessible = true,
            MatchCasing = MatchCasing.CaseInsensitive,
            RecurseSubdirectories = false,
            ReturnSpecialDirectories = false
        };

        try
        {
            foreach (var path in Directory.EnumerateFileSystemEntries(
                         directory.FullName,
                         searchPattern,
                         enumerationOptions))
            {
                budget.RecordEntry();

                try
                {
                    var attributes = File.GetAttributes(path);
                    entries.Add(attributes.HasFlag(FileAttributes.Directory)
                        ? new DirectoryInfo(path)
                        : new FileInfo(path));
                }
                catch (IOException)
                {
                    // The entry disappeared between enumeration and inspection.
                }
                catch (UnauthorizedAccessException)
                {
                    // Ignore entries which cannot safely be inspected.
                }
            }
        }
        catch (IOException)
        {
            // A concurrently removed or inaccessible directory has no usable output.
        }
        catch (UnauthorizedAccessException)
        {
            // A concurrently removed or inaccessible directory has no usable output.
        }

        return entries;
    }

    private static string[] Sorted(HashSet<string> paths)
        => paths.Order(StringComparer.Ordinal).ToArray();

    private sealed class TraversalBudget(int maximumEntries)
    {
        private int _visitedEntries;

        public void RecordEntry()
        {
            _visitedEntries++;
            if (_visitedEntries > maximumEntries)
                throw new InvalidOperationException(
                    $"Libation output traversal exceeded the safe limit of {maximumEntries} entries.");
        }
    }
}
