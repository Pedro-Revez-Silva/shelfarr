using System.Collections.ObjectModel;

namespace Shelfarr.Libation.Companion.Tests;

public sealed class CliCoordinatorTests
{
    [Fact]
    public async Task TryAcquireFailsFastWhileAnotherOperationOwnsTheGate()
    {
        using var temporary = new TemporaryDirectory();
        var coordinator = new Libation.CliCoordinator(TestOptions.Create(temporary.Path));
        await using var held = await coordinator.AcquireAsync(CancellationToken.None);

        var concurrent = await coordinator.TryAcquireAsync(CancellationToken.None);

        Assert.Null(concurrent);
    }

    [Fact]
    public void ForcesAStableSingleLosslessBookArtifactPolicy()
    {
        using var temporary = new TemporaryDirectory();
        var options = TestOptions.Create(temporary.Path);
        var coordinator = new Libation.CliCoordinator(options);
        var arguments = new Collection<string>();

        coordinator.AddCommonOverrides(arguments);

        AssertOverride(arguments, "SplitFilesByChapter=false");
        AssertOverride(arguments, "DecryptToLossy=false");
        AssertOverride(arguments, "ImportEpisodes=false");
        AssertOverride(arguments, "DownloadEpisodes=false");
        AssertOverride(arguments, "FolderTemplate=<title short> [<id>]");
        AssertOverride(arguments, "FileTemplate=<title> [<id>]");
    }

    private static void AssertOverride(IReadOnlyCollection<string> arguments, string expected)
    {
        var values = arguments.ToArray();
        var index = Array.IndexOf(values, expected);
        Assert.True(index > 0, $"Missing override {expected}");
        Assert.Equal("--override", values[index - 1]);
    }
}
