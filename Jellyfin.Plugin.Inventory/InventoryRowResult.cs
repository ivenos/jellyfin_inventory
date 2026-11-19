using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// One row as it goes over the wire: its identity, whether it can be expanded, and the values of
/// the requested columns.
/// </summary>
/// <param name="Id">The item id, used to fetch the row's children.</param>
/// <param name="ParentId">The row one level up, so a whole level can be fetched at once and sorted
/// into place by the browser.</param>
/// <param name="Expandable">Whether the row has a level below it.</param>
/// <param name="Values">The column values, keyed by column.</param>
/// <param name="Within">For a row a search found below the top level, the name of the series, album, book or film
/// it belongs to, unless its own name starts with it.</param>
public sealed record InventoryRowResult(
    Guid Id,
    Guid? ParentId,
    bool Expandable,
    IReadOnlyDictionary<string, object?> Values,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Within = null);
