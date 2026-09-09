using System;
using System.Collections.Generic;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// The columns a media type starts with before the user picks their own.
/// </summary>
public static class ColumnDefaults
{
    private static readonly string[] _movie =
        ["name", "year", "size", "duration", "sizePerHour", "totalBitrate", "videoCodec", "resolution", "videoRange", "audioCodec", "audioLayout"];

    private static readonly string[] _series =
        ["name", "year", "children", "size", "duration", "sizePerHour", "videoCodec", "resolution", "videoRange"];

    // A season is named after its number alone, so the level has to carry the series as well.
    private static readonly string[] _season =
        ["series", "name", "children", "size", "duration", "sizePerHour", "videoCodec", "resolution", "videoRange"];

    private static readonly string[] _episode =
        ["series", "season", "episode", "name", "size", "duration", "sizePerHour", "totalBitrate", "videoCodec", "resolution", "videoRange", "audioCodec"];

    private static readonly string[] _album =
        ["name", "year", "children", "size", "duration", "totalBitrate", "audioCodec", "audioChannels"];

    private static readonly string[] _track =
        ["name", "year", "size", "duration", "totalBitrate", "audioCodec", "audioChannels", "audioSampleRate"];

    private static readonly string[] _generic =
        ["name", "year", "library", "size", "duration", "sizePerHour", "container"];

    // Books and photos have no runtime, so a size per hour of it would be noise.
    private static readonly string[] _static =
        ["name", "year", "library", "size", "container", "dateAdded"];

    /// <summary>
    /// Gets the default columns for a media type.
    /// </summary>
    /// <param name="mediaType">The media type key.</param>
    /// <returns>The column keys to start with.</returns>
    public static IReadOnlyList<string> For(string mediaType) => mediaType switch
    {
        var t when string.Equals(t, "Movie", StringComparison.OrdinalIgnoreCase) => _movie,
        var t when string.Equals(t, "Series", StringComparison.OrdinalIgnoreCase) => _series,
        var t when string.Equals(t, "Season", StringComparison.OrdinalIgnoreCase) => _season,
        var t when string.Equals(t, "Episode", StringComparison.OrdinalIgnoreCase) => _episode,
        var t when string.Equals(t, "Audio", StringComparison.OrdinalIgnoreCase) => _track,
        var t when string.Equals(t, "MusicAlbum", StringComparison.OrdinalIgnoreCase) => _album,
        var t when string.Equals(t, "Book", StringComparison.OrdinalIgnoreCase) => _static,
        var t when string.Equals(t, "Photo", StringComparison.OrdinalIgnoreCase) => _static,
        _ => _generic
    };
}
