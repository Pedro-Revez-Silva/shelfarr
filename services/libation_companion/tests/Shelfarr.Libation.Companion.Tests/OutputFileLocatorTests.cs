namespace Shelfarr.Libation.Companion.Tests;

public sealed class OutputFileLocatorTests
{
    [Fact]
    public void ReturnsOnlyRelativeRegularFilesInsideBooksRoot()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var folder = Path.Combine(options.BooksDirectory, "Example [B012345678]");
        Directory.CreateDirectory(folder);
        File.WriteAllText(Path.Combine(folder, "Example [B012345678].m4b"), "audio");

        var locator = new Libation.OutputFileLocator(options);
        var paths = locator.FindForAsin("B012345678");

        Assert.Equal(["Example [B012345678]/Example [B012345678].m4b"], paths);
        Assert.True(Libation.OutputFileLocator.ContainsAudio(paths));
    }

    [Fact]
    public void DoesNotTraverseSymlinkedDirectories()
    {
        if (OperatingSystem.IsWindows())
            return;

        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var outside = Path.Combine(temporary.Path, "outside");
        Directory.CreateDirectory(outside);
        File.WriteAllText(Path.Combine(outside, "Stolen [B012345678].m4b"), "audio");
        Directory.CreateSymbolicLink(Path.Combine(options.BooksDirectory, "escape"), outside);

        var paths = new Libation.OutputFileLocator(options).FindForAsin("B012345678");

        Assert.Empty(paths);
    }

    [Fact]
    public void ExactAsinFolderAvoidsWalkingUnrelatedLibraryEntries()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var exactFolder = Path.Combine(options.BooksDirectory, "Example [B012345678]");
        Directory.CreateDirectory(exactFolder);
        File.WriteAllText(Path.Combine(exactFolder, "Example [B012345678].m4b"), "audio");
        var unrelatedFolder = Path.Combine(options.BooksDirectory, "A very large unrelated library");
        Directory.CreateDirectory(unrelatedFolder);
        for (var index = 0; index < 10; index++)
            File.WriteAllText(Path.Combine(unrelatedFolder, $"unrelated-{index}.m4b"), "audio");

        var paths = new Libation.OutputFileLocator(options, maximumTraversalEntries: 2)
            .FindForAsin("B012345678");

        Assert.Equal(["Example [B012345678]/Example [B012345678].m4b"], paths);
    }

    [Fact]
    public void LegacyLayoutFallbackFindsAnAsinBelowAnUnmatchedFolder()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var legacyFolder = Path.Combine(options.BooksDirectory, "Example without identifier");
        Directory.CreateDirectory(legacyFolder);
        File.WriteAllText(Path.Combine(legacyFolder, "B012345678.m4b"), "audio");

        var paths = new Libation.OutputFileLocator(options).FindForAsin("B012345678");

        Assert.Equal(["Example without identifier/B012345678.m4b"], paths);
    }

    [Fact]
    public void LegacyLayoutFallbackStopsAtTheTraversalLimit()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var legacyFolder = Path.Combine(options.BooksDirectory, "Example without identifier");
        Directory.CreateDirectory(legacyFolder);
        for (var index = 0; index < 3; index++)
            File.WriteAllText(Path.Combine(legacyFolder, $"legacy-{index}.m4b"), "audio");

        var error = Assert.Throws<InvalidOperationException>(() =>
            new Libation.OutputFileLocator(options, maximumTraversalEntries: 2)
                .FindForAsin("B012345678"));

        Assert.Contains("traversal exceeded", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void RejectsMoreOutputFilesThanTheJobContractCanSafelyReturn()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        options.EnsureDirectories();
        var folder = Path.Combine(options.BooksDirectory, "Example [B012345678]");
        Directory.CreateDirectory(folder);
        for (var index = 0; index <= Libation.OutputFileLocator.MaximumOutputPaths; index++)
            File.WriteAllText(Path.Combine(folder, $"chapter-{index:D3}.mp3"), "audio");

        var error = Assert.Throws<InvalidOperationException>(() =>
            new Libation.OutputFileLocator(options).FindForAsin("B012345678"));

        Assert.Contains("output files", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Mp4IsNotAcceptedAsAShelfarrAudiobookArtifact()
    {
        Assert.False(Libation.OutputFileLocator.ContainsAudio(["Example [B012345678].mp4"]));
    }
}
