using System;
using System.Collections.Generic;
using System.Linq;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// A column: its key, how it is labeled and rendered, and where its value comes from.
/// </summary>
/// <param name="Key">The stable key used in the configuration and in API responses. The header is
/// looked up as "column.&lt;key&gt;" in the plugin's strings.</param>
/// <param name="Group">The section it is offered under in the column picker.</param>
/// <param name="Format">How the browser renders the value.</param>
/// <param name="Value">Reads the value out of a row.</param>
/// <param name="Sort">Reads what the column is ordered by, where that is not the value shown.</param>
/// <param name="Source">Where the value comes from.</param>
/// <param name="Names">Reads the values one by one, where the value lists several.</param>
/// <param name="MediaTypes">The media types that can show the column, or null for every type.</param>
public sealed record ColumnDefinition(
    string Key,
    string Group,
    ColumnFormat Format,
    Func<InventoryRow, object?> Value,
    Func<InventoryRow, object?>? Sort = null,
    ColumnSource Source = ColumnSource.Item,
    Func<InventoryRow, IReadOnlyList<string>?>? Names = null,
    IReadOnlyList<string>? MediaTypes = null)
{
    /// <summary>
    /// Gets a value indicating whether the value lists several, comma separated.
    /// </summary>
    public bool List => Names is not null;

    /// <summary>
    /// Gets whether this column is available for a media type.
    /// </summary>
    /// <param name="mediaType">The media type key.</param>
    /// <returns>Whether the column applies to the media type.</returns>
    public bool IsAvailableFor(string mediaType)
        => MediaTypes is null || MediaTypes.Contains(mediaType, StringComparer.OrdinalIgnoreCase);
}
