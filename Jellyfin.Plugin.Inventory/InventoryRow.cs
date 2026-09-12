using System;
using System.Collections.Generic;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// One line of the inventory: an item flattened into the attributes a column can show.
/// </summary>
public class InventoryRow
{
    /// <summary>
    /// Gets or sets the item id.
    /// </summary>
    public Guid Id { get; set; }

    /// <summary>
    /// Gets or sets the id of the item one level up, used to expand a row into its children.
    /// </summary>
    public Guid? ParentId { get; set; }

    /// <summary>
    /// Gets or sets the id of the outermost item of the tab, used to total a series over its
    /// episodes rather than over its seasons, where an already mixed season would hide a difference.
    /// </summary>
    public Guid? AncestorId { get; set; }

    /// <summary>
    /// Gets or sets the keys of the columns whose value differs across the items below this row.
    /// </summary>
    public IReadOnlySet<string>? Mixed { get; set; }

    /// <summary>
    /// Gets or sets a value indicating whether the row can be expanded.
    /// </summary>
    public bool Expandable { get; set; }

    /// <summary>
    /// Gets or sets the display name.
    /// </summary>
    public string Name { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the name of the series an episode belongs to.
    /// </summary>
    public string? SeriesName { get; set; }

    /// <summary>
    /// Gets or sets the season number of an episode.
    /// </summary>
    public int? SeasonNumber { get; set; }

    /// <summary>
    /// Gets or sets the episode number of an episode.
    /// </summary>
    public int? EpisodeNumber { get; set; }

    /// <summary>
    /// Gets or sets the production year.
    /// </summary>
    public int? Year { get; set; }

    /// <summary>
    /// Gets or sets the name of the library the item lives in.
    /// </summary>
    public string? Library { get; set; }

    /// <summary>
    /// Gets or sets the path on disk.
    /// </summary>
    public string? Path { get; set; }

    /// <summary>
    /// Gets or sets the container format.
    /// </summary>
    public string? Container { get; set; }

    /// <summary>
    /// Gets or sets the file size in bytes.
    /// </summary>
    public long? Size { get; set; }

    /// <summary>
    /// Gets or sets the runtime in seconds.
    /// </summary>
    public double? Duration { get; set; }

    /// <summary>
    /// Gets or sets the date the item was added to the library.
    /// </summary>
    public DateTime? DateAdded { get; set; }

    /// <summary>
    /// Gets or sets the combined bitrate in bits per second.
    /// </summary>
    public long? TotalBitrate { get; set; }

    /// <summary>
    /// Gets or sets the video codec.
    /// </summary>
    public string? VideoCodec { get; set; }

    /// <summary>
    /// Gets or sets the video codec profile.
    /// </summary>
    public string? VideoProfile { get; set; }

    /// <summary>
    /// Gets or sets the video bitrate in bits per second.
    /// </summary>
    public int? VideoBitrate { get; set; }

    /// <summary>
    /// Gets or sets the frame width.
    /// </summary>
    public int? Width { get; set; }

    /// <summary>
    /// Gets or sets the frame height.
    /// </summary>
    public int? Height { get; set; }

    /// <summary>
    /// Gets or sets the frame rate.
    /// </summary>
    public float? FrameRate { get; set; }

    /// <summary>
    /// Gets or sets the video bit depth.
    /// </summary>
    public int? BitDepth { get; set; }

    /// <summary>
    /// Gets or sets the pixel format.
    /// </summary>
    public string? PixelFormat { get; set; }

    /// <summary>
    /// Gets or sets a value indicating whether the video is interlaced.
    /// </summary>
    public bool? Interlaced { get; set; }

    /// <summary>
    /// Gets or sets the video range, as Jellyfin derives it from the colour metadata.
    /// </summary>
    public string? VideoRange { get; set; }

    /// <summary>
    /// Gets or sets the Dolby Vision profile description.
    /// </summary>
    public string? DolbyVision { get; set; }

    /// <summary>
    /// Gets or sets the codec of the default audio track.
    /// </summary>
    public string? AudioCodec { get; set; }

    /// <summary>
    /// Gets or sets the channel layout of the default audio track.
    /// </summary>
    public string? AudioLayout { get; set; }

    /// <summary>
    /// Gets or sets the channel count of the default audio track.
    /// </summary>
    public int? AudioChannels { get; set; }

    /// <summary>
    /// Gets or sets the bitrate of the default audio track in bits per second.
    /// </summary>
    public int? AudioBitrate { get; set; }

    /// <summary>
    /// Gets or sets the sample rate of the default audio track in hertz.
    /// </summary>
    public int? AudioSampleRate { get; set; }

    /// <summary>
    /// Gets or sets the spatial audio format of the default audio track.
    /// </summary>
    public string? SpatialAudio { get; set; }

    /// <summary>
    /// Gets or sets the number of audio tracks.
    /// </summary>
    public int? AudioTracks { get; set; }

    /// <summary>
    /// Gets or sets the audio languages, comma separated.
    /// </summary>
    public string? AudioLanguages { get; set; }

    /// <summary>
    /// Gets or sets the number of subtitle tracks.
    /// </summary>
    public int? SubtitleTracks { get; set; }

    /// <summary>
    /// Gets or sets the subtitle languages, comma separated.
    /// </summary>
    public string? SubtitleLanguages { get; set; }

    /// <summary>
    /// Gets or sets the number of items below, which for a series is its episodes and not its seasons.
    /// </summary>
    public int? Children { get; set; }

    /// <summary>
    /// Gets or sets when the item was last played, for the user asking.
    /// </summary>
    public DateTime? LastPlayed { get; set; }

    /// <summary>
    /// Gets or sets how often the item was played, for the user asking.
    /// </summary>
    public int? PlayCount { get; set; }

    /// <summary>
    /// Gets or sets a value indicating whether the user asking has played the item.
    /// </summary>
    public bool? Played { get; set; }

    /// <summary>
    /// Gets or sets when the item was last played by anyone on the server.
    /// </summary>
    public DateTime? EveryoneLastPlayed { get; set; }

    /// <summary>
    /// Gets or sets how often the item was played, counted over every user of the server.
    /// </summary>
    public int? EveryonePlayCount { get; set; }

    /// <summary>
    /// Gets or sets the users who have played the item to the end, by their place in the order the
    /// server lists them, ascending. A folder keeps the users who have played everything below it,
    /// so the sets are intersected rather than added.
    /// </summary>
    public IReadOnlyList<int> PlayedBy { get; set; } = [];

    /// <summary>
    /// Gets how many users have played the item to the end.
    /// </summary>
    public int? PlayedByCount => PlayedBy.Count > 0 ? PlayedBy.Count : null;

    /// <summary>
    /// Gets or sets a value indicating whether the size and the runtime measure the same files, which
    /// several cuts of one film, or a folder with an unmeasured item below it, do not.
    /// </summary>
    public bool Rateable { get; set; } = true;

    /// <summary>
    /// Gets the size per hour of runtime in bytes, the measure of how expensive an item is for its length.
    /// </summary>
    public double? SizePerHour =>
        Rateable && Size is > 0 && Duration is > 0 ? Math.Round(Size.Value / (Duration.Value / 3600d)) : null;

    /// <summary>
    /// Gets or sets the resolution as a display string.
    /// </summary>
    public string? Resolution { get; set; }

    /// <summary>
    /// Returns a copy, so playback data can be attached per user without touching the shared cache.
    /// </summary>
    /// <returns>A shallow copy of this row.</returns>
    public InventoryRow Copy() => (InventoryRow)MemberwiseClone();
}
