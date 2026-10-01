using System;
using System.Collections.Generic;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// The class a video frame falls in, by the bounds Jellyfin names one with, with 1440p split off from 1080p.
/// </summary>
public static class VideoQuality
{
    private static readonly (int Width, int Height, string Name)[] _classes =
    [
        (256, 144, "144p"),
        (426, 240, "240p"),
        (640, 360, "360p"),
        (682, 384, "384p"),
        (720, 404, "404p"),
        (854, 480, "480p"),
        (960, 544, "540p"),
        (1024, 576, "576p"),
        (1280, 962, "720p"),
        (2048, 1200, "1080p"),
        (2560, 1600, "1440p"),
        (4096, 3072, "4K"),
        (8192, 6144, "8K")
    ];

    /// <summary>
    /// Gets every class, from the smallest frame up.
    /// </summary>
    public static IReadOnlyList<string> Names { get; } = Array.ConvertAll(_classes, c => c.Name);

    /// <summary>
    /// Names the class of a frame: the first one both sides fit into, measured on its long side
    /// so a portrait frame counts as the landscape one turned over.
    /// </summary>
    /// <param name="width">The frame width.</param>
    /// <param name="height">The frame height.</param>
    /// <param name="interlaced">Whether the video is interlaced, which names 1080p 1080i.</param>
    /// <returns>The class, or null for a frame larger than any.</returns>
    public static string? Of(int width, int height, bool interlaced)
    {
        var (wide, tall) = width >= height ? (width, height) : (height, width);
        foreach (var (maxWidth, maxHeight, name) in _classes)
        {
            if (wide <= maxWidth && tall <= maxHeight)
            {
                return interlaced && name.EndsWith('p') ? name[..^1] + "i" : name;
            }
        }

        return null;
    }

    /// <summary>
    /// Gets where a class stands among the others, so 720p sorts below 1080p rather than above it,
    /// and 1080i stands where 1080p does.
    /// </summary>
    /// <param name="name">The class, in any case.</param>
    /// <returns>Its place, or null for anything that is not a class.</returns>
    public static int? Rank(string? name)
    {
        var at = Array.FindIndex(_classes, c => string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase)
            || (c.Name.EndsWith('p') && string.Equals(c.Name[..^1] + "i", name, StringComparison.OrdinalIgnoreCase)));
        return at < 0 ? null : at;
    }
}
