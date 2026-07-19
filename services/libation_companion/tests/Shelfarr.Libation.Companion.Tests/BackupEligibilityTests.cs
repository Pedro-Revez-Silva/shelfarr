using Shelfarr.Libation.Companion.Libation;

namespace Shelfarr.Libation.Companion.Tests;

public sealed class BackupEligibilityTests
{
    [Fact]
    public void AllowsAnActivePurchasedTitle()
    {
        var expected = Item("purchased", active: true);
        var snapshot = Snapshot(expected);

        var actual = BackupEligibility.RequirePurchasedActiveTitle(snapshot, expected.Asin);

        Assert.Same(expected, actual);
    }

    [Theory]
    [InlineData("subscription")]
    [InlineData("unknown")]
    [InlineData("")]
    public void RejectsAnyOwnershipTypeOtherThanPurchasedBeforeDownload(string ownershipType)
    {
        var item = Item(ownershipType, active: true);

        var error = Assert.Throws<BackupNotEligibleException>(() =>
            BackupEligibility.RequirePurchasedActiveTitle(Snapshot(item), item.Asin));

        Assert.Contains("purchased ownership type", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void RejectsInactiveTitlesBeforeDownload()
    {
        var item = Item("purchased", active: false);

        var error = Assert.Throws<BackupNotEligibleException>(() =>
            BackupEligibility.RequirePurchasedActiveTitle(Snapshot(item), item.Asin));

        Assert.Contains("no longer active", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void RequiresASyncedMatchingEntitlement()
    {
        Assert.Throws<BackupNotEligibleException>(() =>
            BackupEligibility.RequirePurchasedActiveTitle(null, "B012345678"));
        Assert.Throws<BackupNotEligibleException>(() =>
            BackupEligibility.RequirePurchasedActiveTitle(Snapshot(), "B012345678"));
    }

    private static LibrarySnapshot Snapshot(params OwnedLibraryItem[] items)
        => new(1, DateTimeOffset.UtcNow, CompanionOptions.PinnedLibationVersion, 0, items);

    private static OwnedLibraryItem Item(string ownershipType, bool active) => new(
        "B012345678",
        "us",
        "Example",
        "",
        ["An Author"],
        ["A Narrator"],
        3600,
        null,
        "",
        "en",
        "Product",
        ownershipType,
        active,
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
