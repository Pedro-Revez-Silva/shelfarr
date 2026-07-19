using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Shelfarr.Libation.Companion.Security;

public sealed class TokenFileAuthenticator
{
    private const int LinuxFileExistsError = 17;
    private static readonly Lock FallbackPublicationGate = new();
    private readonly byte[] _expectedHash;

    public TokenFileAuthenticator(CompanionOptions options)
    {
        var token = LoadOrCreateToken(options.TokenFile);
        _expectedHash = SHA256.HashData(Encoding.UTF8.GetBytes(token));
    }

    public bool IsAuthorized(string? authorizationHeader)
    {
        const string prefix = "Bearer ";
        if (string.IsNullOrWhiteSpace(authorizationHeader)
            || !authorizationHeader.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            return false;

        var presented = authorizationHeader[prefix.Length..].Trim();
        if (presented.Length is < 32 or > 512)
            return false;

        var presentedHash = SHA256.HashData(Encoding.UTF8.GetBytes(presented));
        return CryptographicOperations.FixedTimeEquals(_expectedHash, presentedHash);
    }

    private static string LoadOrCreateToken(string path)
    {
        if (!File.Exists(path))
            PublishGeneratedToken(path);

        HardenPermissions(path);
        var token = File.ReadAllText(path).Trim();
        if (token.Length is < 32 or > 512 || token.Any(char.IsWhiteSpace))
            throw new InvalidOperationException("The companion bearer token file must contain one token of 32-512 non-whitespace characters.");

        return token;
    }

    private static void PublishGeneratedToken(string path)
    {
        var parent = Path.GetDirectoryName(path)
            ?? throw new InvalidOperationException("The companion bearer token file must have a parent directory.");
        var temporary = Path.Combine(parent, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        var generated = GenerateToken();

        try
        {
            var options = new FileStreamOptions
            {
                Mode = FileMode.CreateNew,
                Access = FileAccess.Write,
                Share = FileShare.None
            };
            if (!OperatingSystem.IsWindows())
                options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
            using (var stream = new FileStream(temporary, options))
            {
                using (var writer = new StreamWriter(
                    stream,
                    new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
                    leaveOpen: true))
                {
                    writer.WriteLine(generated);
                    writer.Flush();
                }

                // The final pathname must never identify a partial credential.
                // Flush the complete private temporary before the same-directory
                // no-replace publication makes it visible to Shelfarr.
                stream.Flush(flushToDisk: true);
            }

            _ = PublishNoReplace(temporary, path);
        }
        finally
        {
            File.Delete(temporary);
        }
    }

    private static string GenerateToken()
    {
        var bytes = RandomNumberGenerator.GetBytes(48);
        return Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

    private static bool PublishNoReplace(string temporary, string destination)
    {
        if (OperatingSystem.IsLinux())
        {
            // link(2) is an atomic no-replace publication primitive. Both
            // names are in the same directory, so a successful call exposes
            // the already-flushed inode and EEXIST identifies a concurrent
            // winner without a check-then-rename race.
            if (CreateHardLink(temporary, destination) == 0)
                return true;

            var error = Marshal.GetLastPInvokeError();
            if (error == LinuxFileExistsError)
                return false;

            throw new IOException(
                "Could not publish the companion bearer token atomically.",
                new Win32Exception(error));
        }

        // The distributed companion image is Linux-only. Keep development
        // builds on other platforms race-safe within their single process.
        lock (FallbackPublicationGate)
        {
            if (File.Exists(destination))
                return false;

            File.Move(temporary, destination, overwrite: false);
            return true;
        }
    }

#pragma warning disable SYSLIB1054 // This tiny libc boundary avoids enabling unsafe source-generated interop.
    [DllImport("libc", EntryPoint = "link", ExactSpelling = true, SetLastError = true)]
    private static extern int CreateHardLink(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string existingPath,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string newPath);
#pragma warning restore SYSLIB1054

    private static void HardenPermissions(string path)
    {
        if (OperatingSystem.IsWindows())
            return;

        File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
    }
}
