using System;
using System.Collections.Generic;
using System.Linq;
using Jellyfin.Data.Enums;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// Every column the inventory can show.
/// </summary>
public static class Columns
{
    /// <summary>
    /// The group holding what is read from a playback record rather than from the item.
    /// </summary>
    public const string Playback = "Playback";

    private static readonly BaseItemKind[] _streamed =
        [BaseItemKind.Movie, BaseItemKind.Series, BaseItemKind.MusicAlbum, BaseItemKind.MusicVideo, BaseItemKind.Video, BaseItemKind.AudioBook];

    // Jellyfin takes a picture in an audio file for an embedded image, not for a video stream.
    private static readonly BaseItemKind[] _filmed =
        [BaseItemKind.Movie, BaseItemKind.Series, BaseItemKind.MusicVideo, BaseItemKind.Video];

    private static readonly BaseItemKind[] _pictured = [.. _filmed, BaseItemKind.Photo];

    private static readonly BaseItemKind[] _identified =
        [BaseItemKind.Movie, BaseItemKind.Series, BaseItemKind.MusicAlbum, BaseItemKind.MusicVideo, BaseItemKind.Video];

    private static readonly ColumnDefinition[] _all =
    [
        new("name", "General", ColumnFormat.Text, r => r.Name),
        new("series", "General", ColumnFormat.Text, r => r.SeriesName, MediaTypes: [BaseItemKind.Series]),
        new("season", "General", ColumnFormat.Plain, r => r.SeasonNumber, MediaTypes: [BaseItemKind.Series]),
        new("episode", "General", ColumnFormat.Plain, r => r.EpisodeNumber, MediaTypes: [BaseItemKind.Series]),
        new("year", "General", ColumnFormat.Plain, r => r.Year),
        Listing("genres", "General", r => r.Genres),
        Listing("collections", "General", r => r.Collections),
        Listing("playlists", "General", r => r.Playlists, ColumnSource.User),
        Listing("artists", "General", r => r.Artists, mediaTypes: [BaseItemKind.MusicAlbum, BaseItemKind.MusicVideo]),
        Listing("authors", "General", r => r.Authors, mediaTypes: [BaseItemKind.Book, BaseItemKind.AudioBook]),
        Listing("narrators", "General", r => r.Narrators, mediaTypes: [BaseItemKind.Book, BaseItemKind.AudioBook]),
        new("library", "General", ColumnFormat.Text, r => r.Library),
        new("children", "General", ColumnFormat.Number, r => r.Children, MediaTypes: _streamed),
        new("duplicates", "General", ColumnFormat.Number, r => r.Duplicates, MediaTypes: _identified),
        new("container", "General", ColumnFormat.Text, r => r.Container),
        new("size", "General", ColumnFormat.Bytes, r => r.Size),
        new("duration", "General", ColumnFormat.Duration, r => r.Duration, MediaTypes: _streamed),
        new("sizePerHour", "General", ColumnFormat.BytesPerHour, r => r.SizePerHour, MediaTypes: _streamed),
        new("totalBitrate", "General", ColumnFormat.Bitrate, r => r.TotalBitrate, MediaTypes: _streamed),
        new("dateAdded", "General", ColumnFormat.Date, r => r.DateAdded),
        new("path", "General", ColumnFormat.Text, r => r.Path),

        new("videoCodec", "Video", ColumnFormat.Text, r => r.VideoCodec, MediaTypes: _filmed),
        new("videoProfile", "Video", ColumnFormat.Text, r => r.VideoProfile, MediaTypes: _filmed),
        // Ordered by area, since "960x540" reads as the larger of the two next to "1920x1080".
        new("resolution", "Video", ColumnFormat.Text, r => r.Resolution, r => (long?)r.Width * r.Height, MediaTypes: _pictured),
        new("quality", "Video", ColumnFormat.Quality, r => r.Quality, r => VideoQuality.Rank(r.Quality), MediaTypes: _filmed),
        new("height", "Video", ColumnFormat.Plain, r => r.Height, MediaTypes: _pictured),
        new("videoBitrate", "Video", ColumnFormat.Bitrate, r => r.VideoBitrate, MediaTypes: _filmed),
        new("frameRate", "Video", ColumnFormat.FrameRate, r => r.FrameRate, MediaTypes: _filmed),
        new("bitDepth", "Video", ColumnFormat.Plain, r => r.BitDepth, MediaTypes: _filmed),
        new("videoRange", "Video", ColumnFormat.Text, r => r.VideoRange, MediaTypes: _filmed),
        new("dolbyVision", "Video", ColumnFormat.Text, r => r.DolbyVision, MediaTypes: _filmed),
        new("pixelFormat", "Video", ColumnFormat.Text, r => r.PixelFormat, MediaTypes: _filmed),
        new("interlaced", "Video", ColumnFormat.Boolean, r => r.Interlaced, MediaTypes: _filmed),

        new("audioCodec", "Audio", ColumnFormat.Text, r => r.AudioCodec, MediaTypes: _streamed),
        new("audioLayout", "Audio", ColumnFormat.Text, r => r.AudioLayout, MediaTypes: _streamed),
        new("audioChannels", "Audio", ColumnFormat.Number, r => r.AudioChannels, MediaTypes: _streamed),
        new("audioBitrate", "Audio", ColumnFormat.Bitrate, r => r.AudioBitrate, MediaTypes: _streamed),
        new("audioSampleRate", "Audio", ColumnFormat.Number, r => r.AudioSampleRate, MediaTypes: _streamed),
        new("spatialAudio", "Audio", ColumnFormat.Text, r => r.SpatialAudio, MediaTypes: _streamed),
        new("audioTracks", "Audio", ColumnFormat.Number, r => r.AudioTracks, MediaTypes: _streamed),
        Listing("audioLanguages", "Audio", r => r.AudioLanguages, mediaTypes: _streamed),

        new("subtitleTracks", "Subtitles", ColumnFormat.Number, r => r.SubtitleTracks, MediaTypes: _filmed),
        Listing("subtitleLanguages", "Subtitles", r => r.SubtitleLanguages, mediaTypes: _filmed),

        new("lastPlayed", Playback, ColumnFormat.Date, r => r.LastPlayed, Source: ColumnSource.User),
        new("everyoneLastPlayed", Playback, ColumnFormat.Date, r => r.EveryoneLastPlayed, Source: ColumnSource.Everyone),
        new("playCount", Playback, ColumnFormat.Number, r => r.PlayCount, Source: ColumnSource.User),
        new("everyonePlayCount", Playback, ColumnFormat.Number, r => r.EveryonePlayCount, Source: ColumnSource.Everyone),
        new("played", Playback, ColumnFormat.Boolean, r => r.Played, Source: ColumnSource.User),
        new("everyonePlayed", Playback, ColumnFormat.Number, r => r.PlayedByCount, Source: ColumnSource.Everyone)
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
            : ColumnDefaults.For(level).Select(Find).OfType<ColumnDefinition>().DistinctBy(c => c.Key).ToArray();
    }

    private static ColumnDefinition Listing(
        string key,
        string group,
        Func<InventoryRow, IReadOnlyList<string>?> names,
        ColumnSource source = ColumnSource.Item,
        IReadOnlyList<BaseItemKind>? mediaTypes = null)
        => new(key, group, ColumnFormat.Text, r => names(r) is { } all ? string.Join(", ", all) : null, Source: source, Names: names, MediaTypes: mediaTypes);
}
