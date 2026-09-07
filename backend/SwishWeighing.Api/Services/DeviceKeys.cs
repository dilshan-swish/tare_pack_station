using System.Security.Cryptography;
using System.Text;

namespace SwishWeighing.Api.Services;

/// <summary>
/// Per-tablet keys. We generate a random key (shown once at registration) and
/// store only its SHA-256 hash, so a leaked database never exposes the keys.
///
/// Format: 8 characters from an unambiguous uppercase alphabet (no 0/O or
/// 1/I/L confusion), shown grouped as "XXXX-XXXX" — short enough to type by
/// hand in one go. ~40 bits of entropy (32^8): plenty for a per-device
/// provisioning credential typed once at setup and never used again — it
/// isn't a repeatedly-submitted user password, and this app has few enough
/// devices that a brute-force sweep of the whole keyspace against a live
/// server would take years even unthrottled. Pure server-side generation, so
/// this takes effect immediately after a normal deploy — no client-side
/// change needed, and every already-registered device's existing key (12-char
/// old format or 8-char new) keeps working with zero migration, since `Hash`
/// itself is unchanged and case-sensitive exactly as before.
/// </summary>
public static class DeviceKeys
{
    private const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

    public static string Generate()
    {
        const int length = 8;
        var bytes = RandomNumberGenerator.GetBytes(length);
        var chars = new char[length];
        for (var i = 0; i < length; i++)
            chars[i] = Alphabet[bytes[i] % Alphabet.Length];
        var code = new string(chars);
        return $"{code[..4]}-{code[4..]}";
    }

    public static byte[] Hash(string key) => SHA256.HashData(Encoding.UTF8.GetBytes(key));
}
