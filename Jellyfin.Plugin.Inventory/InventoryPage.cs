using System.Collections.Generic;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// One page of inventory rows, with the totals of everything the filter matched.
/// </summary>
/// <param name="Rows">The rows on this page, built as they are read.</param>
/// <param name="TotalCount">How many rows matched in total.</param>
/// <param name="TotalSize">The combined size in bytes of every matching row.</param>
/// <param name="TotalDuration">The combined runtime in seconds of every matching row.</param>
public sealed record InventoryPage(
    IEnumerable<InventoryRowResult> Rows,
    int TotalCount,
    long TotalSize,
    double TotalDuration);
