using System;
using System.Collections.Generic;
using Jellyfin.Data.Enums;

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
/// <param name="MediaTypes">The tabs the column can have a value in, or null for every tab.</param>
public sealed record ColumnDefinition(
    string Key,
    string Group,
    ColumnFormat Format,
    Func<InventoryRow, object?> Value,
    Func<InventoryRow, object?>? Sort = null,
    ColumnSource Source = ColumnSource.Item,
    Func<InventoryRow, IReadOnlyList<string>?>? Names = null,
    IReadOnlyList<BaseItemKind>? MediaTypes = null)
{
    /// <summary>
    /// Gets a value indicating whether the value lists several, comma separated.
    /// </summary>
    public bool List => Names is not null;
}
