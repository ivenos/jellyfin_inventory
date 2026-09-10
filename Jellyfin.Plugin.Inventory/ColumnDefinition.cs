using System;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// A column: its key, how it is labelled and rendered, and where its value comes from.
/// </summary>
/// <param name="Key">The stable key used in the configuration and in API responses. The header is
/// looked up as "column.&lt;key&gt;" in the plugin's strings.</param>
/// <param name="Group">The section it is offered under in the column picker.</param>
/// <param name="Format">How the browser renders the value.</param>
/// <param name="Value">Reads the value out of a row.</param>
/// <param name="Sort">Reads what the column is ordered by, where that is not the value shown.</param>
/// <param name="Source">Where the value comes from.</param>
public sealed record ColumnDefinition(
    string Key,
    string Group,
    ColumnFormat Format,
    Func<InventoryRow, object?> Value,
    Func<InventoryRow, object?>? Sort = null,
    ColumnSource Source = ColumnSource.Item);
