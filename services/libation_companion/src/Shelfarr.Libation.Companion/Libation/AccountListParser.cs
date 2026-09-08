namespace Shelfarr.Libation.Companion.Libation;

internal static class AccountListParser
{
    // Libation 13.5.1 emitted five tab-separated columns. 14.0+ appends an
    // "also-scans" marketplace list last and keeps the first five stable, so
    // a client that required exactly five columns would drop every account.
    public static AccountStatus? TryParse(string line)
    {
        var fields = line.Split('\t');
        if (fields.Length < 5 || string.IsNullOrWhiteSpace(fields[0]))
            return null;

        return new AccountStatus(
            fields[0],
            fields[1],
            fields[2],
            fields[3].Equals("yes", StringComparison.OrdinalIgnoreCase),
            fields[4].Equals("yes", StringComparison.OrdinalIgnoreCase));
    }
}
