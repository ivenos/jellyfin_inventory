using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.Json;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// The plugin's own strings. Jellyfin's translateHtml only resolves keys from the web client's
/// dictionary, so anything this plugin words itself is looked up here and sent out translated.
/// </summary>
public static class Translations
{
    /// <summary>
    /// The culture every lookup falls back to, and the only one guaranteed to be complete.
    /// </summary>
    public const string FallbackCulture = "en";

    private const string Prefix = "Jellyfin.Plugin.Inventory.Strings.";

    private static readonly ConcurrentDictionary<string, IReadOnlyDictionary<string, string>> _cache = new();

    private static readonly Lazy<IReadOnlyList<string>> _available = new(() =>
        Assembly.GetExecutingAssembly().GetManifestResourceNames()
            .Where(n => n.StartsWith(Prefix, StringComparison.Ordinal) && n.EndsWith(".json", StringComparison.Ordinal))
            .Select(n => n[Prefix.Length..^5])
            .ToArray());

    /// <summary>
    /// Gets the cultures the plugin ships strings for.
    /// </summary>
    public static IReadOnlyList<string> Available => _available.Value;

    /// <summary>
    /// Looks up a key in a culture, falling back to <see cref="FallbackCulture"/> and finally to the key.
    /// </summary>
    /// <param name="culture">The requested culture, such as "de" or "de-DE".</param>
    /// <param name="key">The string key.</param>
    /// <returns>The translated string.</returns>
    public static string Get(string? culture, string key)
    {
        if (Load(Resolve(culture)).TryGetValue(key, out var value))
        {
            return value;
        }

        return Load(FallbackCulture).TryGetValue(key, out var fallback) ? fallback : key;
    }

    /// <summary>
    /// Gets every string of a culture, with anything it is missing filled in from the fallback.
    /// </summary>
    /// <param name="culture">The requested culture.</param>
    /// <returns>The complete dictionary.</returns>
    public static IReadOnlyDictionary<string, string> All(string? culture)
    {
        var strings = new Dictionary<string, string>(Load(FallbackCulture), StringComparer.Ordinal);
        foreach (var (key, value) in Load(Resolve(culture)))
        {
            strings[key] = value;
        }

        return strings;
    }

    private static string Resolve(string? culture)
    {
        if (string.IsNullOrWhiteSpace(culture))
        {
            return FallbackCulture;
        }

        var exact = Available.FirstOrDefault(c => string.Equals(c, culture, StringComparison.OrdinalIgnoreCase));
        if (exact is not null)
        {
            return exact;
        }

        // "de-DE" and Jellyfin's lowercased "de-de" both fall back to the language on its own.
        var language = culture.Split('-')[0];
        return Available.FirstOrDefault(c => string.Equals(c, language, StringComparison.OrdinalIgnoreCase))
            ?? FallbackCulture;
    }

    private static IReadOnlyDictionary<string, string> Load(string culture)
        => _cache.GetOrAdd(culture, static c =>
        {
            using var stream = Assembly.GetExecutingAssembly()
                .GetManifestResourceStream(string.Format(CultureInfo.InvariantCulture, "{0}{1}.json", Prefix, c));

            if (stream is null)
            {
                return new Dictionary<string, string>(StringComparer.Ordinal);
            }

            using var reader = new StreamReader(stream);
            return JsonSerializer.Deserialize<Dictionary<string, string>>(reader.ReadToEnd())
                ?? new Dictionary<string, string>(StringComparer.Ordinal);
        });
}
