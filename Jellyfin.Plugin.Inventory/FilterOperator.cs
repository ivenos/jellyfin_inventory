namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// How a filter holds a cell against the value it was given.
/// </summary>
public enum FilterOperator
{
    /// <summary>The cell is the value.</summary>
    Equal,

    /// <summary>The cell is anything but the value.</summary>
    NotEqual,

    /// <summary>The cell is the value or more.</summary>
    AtLeast,

    /// <summary>The cell is the value or less.</summary>
    AtMost,

    /// <summary>The cell carries the value somewhere in its text.</summary>
    Contains,

    /// <summary>The cell carries the value nowhere in its text.</summary>
    NotContains,

    /// <summary>The cell holds nothing.</summary>
    Empty,

    /// <summary>The cell holds something.</summary>
    NotEmpty
}
