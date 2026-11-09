using System;
using System.Collections.Generic;
using System.Linq;
using Jellyfin.Data.Enums;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// Which levels a tab can be broken down into. The seasons and episodes of a series are reached through
/// the series rather than listed on their own, and the files of an audiobook through the folder that holds them.
/// </summary>
public static class Hierarchy
{
    /// <summary>
    /// The kind of target that is a collection.
    /// </summary>
    public const string Collection = "Collection";

    /// <summary>
    /// The kind of target that is a playlist.
    /// </summary>
    public const string Playlist = "Playlist";

    /// <summary>
    /// The key of the level that lists every file of a tab, an item kept in several versions once per version.
    /// </summary>
    public const string Version = "Version";

    private static readonly BaseItemKind[][] _all =
    [
        [BaseItemKind.Movie],
        [BaseItemKind.Series, BaseItemKind.Season, BaseItemKind.Episode],
        [BaseItemKind.MusicAlbum, BaseItemKind.Audio],
        [BaseItemKind.MusicVideo],
        [BaseItemKind.Video],
        [BaseItemKind.Book],
        [BaseItemKind.Folder, BaseItemKind.AudioBook],
        [BaseItemKind.Photo]
    ];

    private static readonly BaseItemKind[] _versioned =
        [BaseItemKind.Movie, BaseItemKind.Episode, BaseItemKind.MusicVideo, BaseItemKind.Video];

    /// <summary>
    /// Gets every tab, as the levels it contains.
    /// </summary>
    public static IReadOnlyList<IReadOnlyList<BaseItemKind>> All => _all;

    /// <summary>
    /// Gets the media type a tab is named by: its outermost level, or what a folder at the top holds.
    /// </summary>
    /// <param name="levels">The levels of the tab.</param>
    /// <returns>The media type.</returns>
    public static BaseItemKind Tab(IReadOnlyList<BaseItemKind> levels)
    {
        ArgumentNullException.ThrowIfNull(levels);
        return levels[0] == BaseItemKind.Folder ? levels[^1] : levels[0];
    }

    /// <summary>
    /// Gets the levels of the tab a media type names.
    /// </summary>
    /// <param name="mediaType">The media type key.</param>
    /// <returns>The levels, or null if no tab is named that.</returns>
    public static IReadOnlyList<BaseItemKind>? Levels(string mediaType)
        => _all.FirstOrDefault(h => string.Equals(Tab(h).ToString(), mediaType, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// Gets the levels of the tab an item kind belongs to.
    /// </summary>
    /// <param name="kind">The item kind.</param>
    /// <returns>The levels, or null if no tab contains it.</returns>
    public static IReadOnlyList<BaseItemKind>? Of(BaseItemKind kind)
        => _all.FirstOrDefault(h => Array.IndexOf(h, kind) >= 0);

    /// <summary>
    /// Gets whether Jellyfin can keep an item of a kind in several versions.
    /// </summary>
    /// <param name="kind">The item kind.</param>
    /// <returns>Whether its tab can have a level of versions below it.</returns>
    public static bool Versioned(BaseItemKind kind) => Array.IndexOf(_versioned, kind) >= 0;

    /// <summary>
    /// Gets what an item of a level can be added to, by the rules jellyfin-web offers it by: no track
    /// or photo goes into a collection, and nothing that plays nothing into a playlist.
    /// </summary>
    /// <param name="kind">The level.</param>
    /// <returns>The kinds of target, out of <see cref="Collection"/> and <see cref="Playlist"/>.</returns>
    public static IReadOnlyList<string> Targets(BaseItemKind kind) => kind switch
    {
        BaseItemKind.Photo => [],
        BaseItemKind.Audio => [Playlist],
        BaseItemKind.Book => [Collection],
        _ => [Collection, Playlist]
    };

    /// <summary>
    /// Resolves a level key, whichever tab it belongs to.
    /// </summary>
    /// <param name="level">The level key.</param>
    /// <returns>The key as the level goes by, or null if no tab has that level.</returns>
    public static string? Key(string? level)
    {
        if (string.Equals(level, Version, StringComparison.OrdinalIgnoreCase))
        {
            return Version;
        }

        foreach (var kinds in _all)
        {
            foreach (var kind in kinds)
            {
                if (string.Equals(kind.ToString(), level, StringComparison.OrdinalIgnoreCase))
                {
                    return kind.ToString();
                }
            }
        }

        return null;
    }

    /// <summary>
    /// Resolves a level within a tab.
    /// </summary>
    /// <param name="mediaType">The media type key.</param>
    /// <param name="level">The level key, or null for the one the tab is named after.</param>
    /// <returns>The level, or null if it does not belong to the tab.</returns>
    public static Level? Resolve(string mediaType, string? level)
    {
        var levels = Levels(mediaType);
        if (levels is null)
        {
            return null;
        }

        if (string.IsNullOrEmpty(level))
        {
            return new Level(Tab(levels));
        }

        if (string.Equals(level, Version, StringComparison.OrdinalIgnoreCase))
        {
            return Versioned(levels[^1]) ? new Level(levels[^1], true) : null;
        }

        foreach (var kind in levels)
        {
            if (string.Equals(kind.ToString(), level, StringComparison.OrdinalIgnoreCase))
            {
                return new Level(kind);
            }
        }

        return null;
    }
}
