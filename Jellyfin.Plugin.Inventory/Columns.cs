using System;
using System.Collections.Generic;
using System.Linq;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// Every column the inventory can show. A new attribute is one entry here plus its field on
/// <see cref="InventoryRow"/>; nothing else knows the list.
/// </summary>
public static class Columns
{
    /// <summary>
    /// The group whose values are read per user rather than from the item.
    /// </summary>
    public const string Playback = "Playback";

    private static readonly ColumnDefinition[] _all =
    [
        new("name", "General", ColumnFormat.Text, r => r.Name),
        new("series", "General", ColumnFormat.Text, r => r.SeriesName),
        new("season", "General", ColumnFormat.Plain, r => r.SeasonNumber),
        new("episode", "General", ColumnFormat.Plain, r => r.EpisodeNumber),
        new("year", "General", ColumnFormat.Plain, r => r.Year),
        new("library", "General", ColumnFormat.Text, r => r.Library),
        new("children", "General", ColumnFormat.Number, r => r.Children),
        new("container", "General", ColumnFormat.Text, r => r.Container),
        new("size", "General", ColumnFormat.Bytes, r => r.Size),
        new("duration", "General", ColumnFormat.Duration, r => r.Duration),
        new("sizePerHour", "General", ColumnFormat.BytesPerHour, r => r.SizePerHour),
        new("totalBitrate", "General", ColumnFormat.Bitrate, r => r.TotalBitrate),
        new("dateAdded", "General", ColumnFormat.Date, r => r.DateAdded),
        new("path", "General", ColumnFormat.Text, r => r.Path),

        new("videoCodec", "Video", ColumnFormat.Text, r => r.VideoCodec),
        new("videoProfile", "Video", ColumnFormat.Text, r => r.VideoProfile),
        // Ordered by area, since "960x540" reads as the larger of the two next to "1920x1080".
        new("resolution", "Video", ColumnFormat.Text, r => r.Resolution, r => (long?)r.Width * r.Height),
        new("height", "Video", ColumnFormat.Number, r => r.Height),
        new("videoBitrate", "Video", ColumnFormat.Bitrate, r => r.VideoBitrate),
        new("frameRate", "Video", ColumnFormat.FrameRate, r => r.FrameRate),
        new("bitDepth", "Video", ColumnFormat.Plain, r => r.BitDepth),
        new("videoRange", "Video", ColumnFormat.Text, r => r.VideoRange),
        new("dolbyVision", "Video", ColumnFormat.Text, r => r.DolbyVision),
        new("pixelFormat", "Video", ColumnFormat.Text, r => r.PixelFormat),
        new("interlaced", "Video", ColumnFormat.Boolean, r => r.Interlaced),

        new("audioCodec", "Audio", ColumnFormat.Text, r => r.AudioCodec),
        new("audioLayout", "Audio", ColumnFormat.Text, r => r.AudioLayout),
        new("audioChannels", "Audio", ColumnFormat.Number, r => r.AudioChannels),
        new("audioBitrate", "Audio", ColumnFormat.Bitrate, r => r.AudioBitrate),
        new("audioSampleRate", "Audio", ColumnFormat.Number, r => r.AudioSampleRate),
        new("spatialAudio", "Audio", ColumnFormat.Text, r => r.SpatialAudio),
        new("audioTracks", "Audio", ColumnFormat.Number, r => r.AudioTracks),
        new("audioLanguages", "Audio", ColumnFormat.Text, r => r.AudioLanguages),

        new("subtitleTracks", "Subtitles", ColumnFormat.Number, r => r.SubtitleTracks),
        new("subtitleLanguages", "Subtitles", ColumnFormat.Text, r => r.SubtitleLanguages),

        new("lastPlayed", Playback, ColumnFormat.Date, r => r.LastPlayed),
        new("playCount", Playback, ColumnFormat.Number, r => r.PlayCount),
        new("played", Playback, ColumnFormat.Boolean, r => r.Played)
    ];

    private static readonly Dictionary<string, ColumnDefinition> _byKey =
        _all.ToDictionary(c => c.Key, StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Gets every known column, in the order the picker offers them.
    /// </summary>
    public static IReadOnlyList<ColumnDefinition> All => _all;

    /// <summary>
    /// Looks a column up by key.
    /// </summary>
    /// <param name="key">The column key.</param>
    /// <returns>The column, or null if the key is not known.</returns>
    public static ColumnDefinition? Find(string? key)
        => key is not null && _byKey.TryGetValue(key, out var column) ? column : null;

    /// <summary>
    /// Resolves a list of keys to columns, dropping any that no longer exist.
    /// </summary>
    /// <param name="keys">The keys to resolve, or null where the level has nothing stored.</param>
    /// <param name="level">The level whose defaults stand in for a selection that resolved to nothing.</param>
    /// <returns>The columns that matched.</returns>
    public static IReadOnlyList<ColumnDefinition> Resolve(IEnumerable<string>? keys, string level)
    {
        // A configuration file edited by hand can repeat a key, and the row values are keyed by it.
        var resolved = keys?.Select(Find).OfType<ColumnDefinition>().DistinctBy(c => c.Key).ToArray() ?? [];
        return resolved.Length > 0
            ? resolved
            : ColumnDefaults.For(level).Select(Find).OfType<ColumnDefinition>().ToArray();
    }
}
