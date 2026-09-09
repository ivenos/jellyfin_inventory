#pragma warning disable CA1819 // Properties should not return arrays

namespace Jellyfin.Plugin.Inventory.Configuration;

/// <summary>
/// The columns chosen for one level, such as the episodes of a series.
/// </summary>
public class ColumnPreset
{
    /// <summary>
    /// Gets or sets the level the preset applies to.
    /// </summary>
    public string Level { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the column keys, in display order.
    /// </summary>
    public string[] Columns { get; set; } = [];
}
