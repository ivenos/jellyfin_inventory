#pragma warning disable CA1819 // Properties should not return arrays

using System;
using MediaBrowser.Model.Plugins;

namespace Jellyfin.Plugin.Inventory.Configuration;

/// <summary>
/// Plugin configuration.
/// </summary>
public class PluginConfiguration : BasePluginConfiguration
{
    /// <summary>
    /// The largest page the table will ask for and the API will answer with.
    /// </summary>
    public const int MaxPageSize = 10000;

    /// <summary>
    /// Gets or sets the per-level column selections. A level without an entry uses the defaults.
    /// </summary>
    public ColumnPreset[] Presets { get; set; } = [];

    /// <summary>
    /// Gets or sets the number of rows fetched per page.
    /// </summary>
    public int PageSize { get; set; } = 100;

    /// <summary>
    /// Gets or sets how far each media type is expanded when it opens.
    /// </summary>
    public ExpandPreference[] Expanded { get; set; } = [];

    /// <summary>
    /// Returns the columns stored for a level, or null if the user has not chosen any.
    /// </summary>
    /// <param name="level">The level key.</param>
    /// <returns>The stored column keys, or null.</returns>
    public string[]? GetColumns(string level)
    {
        foreach (var preset in Presets)
        {
            if (string.Equals(preset?.Level, level, StringComparison.OrdinalIgnoreCase))
            {
                return preset!.Columns is { Length: > 0 } columns ? columns : null;
            }
        }

        return null;
    }

    /// <summary>
    /// Returns the deepest level a media type expands to, or null.
    /// </summary>
    /// <param name="mediaType">The media type key.</param>
    /// <returns>The stored level, or null.</returns>
    public string? GetExpandLevel(string mediaType)
    {
        foreach (var preference in Expanded)
        {
            if (string.Equals(preference?.MediaType, mediaType, StringComparison.OrdinalIgnoreCase))
            {
                return preference!.Level;
            }
        }

        return null;
    }
}
