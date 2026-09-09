using System;
using System.Collections.Generic;
using System.Linq;
using Jellyfin.Data.Enums;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// Which levels a tab can be broken down into. A tab is its outermost level, so the seasons and
/// episodes of a series are reached through the series rather than listed on their own.
/// </summary>
public static class Hierarchy
{
    private static readonly BaseItemKind[][] _all =
    [
        [BaseItemKind.Movie],
        [BaseItemKind.Series, BaseItemKind.Season, BaseItemKind.Episode],
        [BaseItemKind.MusicAlbum, BaseItemKind.Audio],
        [BaseItemKind.MusicVideo],
        [BaseItemKind.Video],
        [BaseItemKind.Book],
        [BaseItemKind.AudioBook],
        [BaseItemKind.Photo]
    ];

    /// <summary>
    /// Gets every tab, as the levels it contains.
    /// </summary>
    public static IReadOnlyList<IReadOnlyList<BaseItemKind>> All => _all;

    /// <summary>
    /// Gets the levels of the tab a media type names.
    /// </summary>
    /// <param name="mediaType">The media type key.</param>
    /// <returns>The levels, or null if no tab is named that.</returns>
    public static IReadOnlyList<BaseItemKind>? Levels(string mediaType)
        => _all.FirstOrDefault(h => string.Equals(h[0].ToString(), mediaType, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// Gets the levels of the tab an item kind belongs to.
    /// </summary>
    /// <param name="kind">The item kind.</param>
    /// <returns>The levels, or null if no tab contains it.</returns>
    public static IReadOnlyList<BaseItemKind>? Of(BaseItemKind kind)
        => _all.FirstOrDefault(h => Array.IndexOf(h, kind) >= 0);

    /// <summary>
    /// Resolves a level key, whichever tab it belongs to.
    /// </summary>
    /// <param name="level">The level key.</param>
    /// <returns>The item kind, or null if no tab has that level.</returns>
    public static BaseItemKind? Level(string? level)
    {
        foreach (var kinds in _all)
        {
            foreach (var kind in kinds)
            {
                if (string.Equals(kind.ToString(), level, StringComparison.OrdinalIgnoreCase))
                {
                    return kind;
                }
            }
        }

        return null;
    }

    /// <summary>
    /// Resolves a level within a tab.
    /// </summary>
    /// <param name="mediaType">The media type key.</param>
    /// <param name="level">The level key, or null for the outermost.</param>
    /// <returns>The item kind, or null if the level does not belong to the tab.</returns>
    public static BaseItemKind? Resolve(string mediaType, string? level)
    {
        var levels = Levels(mediaType);
        if (levels is null)
        {
            return null;
        }

        if (string.IsNullOrEmpty(level))
        {
            return levels[0];
        }

        foreach (var kind in levels)
        {
            if (string.Equals(kind.ToString(), level, StringComparison.OrdinalIgnoreCase))
            {
                return kind;
            }
        }

        return null;
    }
}
