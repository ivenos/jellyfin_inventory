using System;
using System.Collections.Generic;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// Every row a listing matches, as <c>Items</c> lists it, less the rows left out.
/// </summary>
public class TargetSelection
{
    /// <summary>
    /// Gets or sets the media type listed.
    /// </summary>
    public string? MediaType { get; set; }

    /// <summary>
    /// Gets or sets the level listed, or null for the one the tab is named after.
    /// </summary>
    public string? Level { get; set; }

    /// <summary>
    /// Gets or sets the search the listing was narrowed by.
    /// </summary>
    public string? Search { get; set; }

    /// <summary>
    /// Gets or sets the conditions the listing was filtered by, as <c>Items</c> takes them.
    /// </summary>
    public string? Filters { get; set; }

    /// <summary>
    /// Gets or sets the ids of the rows left out.
    /// </summary>
    public IReadOnlyList<Guid>? Except { get; set; }
}
