namespace Shelfarr.Libation.Companion.Libation;

public sealed class BackupNotEligibleException(string message) : InvalidOperationException(message);

public static class BackupEligibility
{
    public static OwnedLibraryItem RequirePurchasedActiveTitle(LibrarySnapshot? library, string asin)
    {
        if (library is null)
            return RequirePurchasedActiveTitle(null, asin, libraryExists: false);

        var item = library.Items.FirstOrDefault(candidate =>
            candidate.Asin.Equals(asin, StringComparison.OrdinalIgnoreCase));
        return RequirePurchasedActiveTitle(item, asin, libraryExists: true);
    }

    public static OwnedLibraryItem RequirePurchasedActiveTitle(
        OwnedLibraryItem? item,
        string asin,
        bool libraryExists)
    {
        if (!libraryExists)
            throw new BackupNotEligibleException("The Audible library must be synced before starting a backup.");
        if (item is null || !item.Asin.Equals(asin, StringComparison.OrdinalIgnoreCase))
            throw new BackupNotEligibleException("The requested ASIN is not present in the synced Audible library.");
        if (!item.Active)
            throw new BackupNotEligibleException("The requested title is no longer active in the Audible library.");
        if (!string.Equals(item.OwnershipType, "purchased", StringComparison.OrdinalIgnoreCase))
            throw new BackupNotEligibleException("Only titles with a verified purchased ownership type are eligible for backup.");

        return item;
    }
}
