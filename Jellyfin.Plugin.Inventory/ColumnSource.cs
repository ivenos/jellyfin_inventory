namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// Where a column's value is read from, which decides what has to be built to answer with it.
/// </summary>
public enum ColumnSource
{
    /// <summary>
    /// The item itself, the same for everyone.
    /// </summary>
    Item,

    /// <summary>
    /// The playback record of the user asking.
    /// </summary>
    User,

    /// <summary>
    /// The playback records of every user of the server.
    /// </summary>
    Everyone
}
