using Jellyfin.Data.Enums;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// One level of a tab: the items of a kind, or the files of those of them that are kept in several versions.
/// </summary>
/// <param name="Kind">The kind of item, which for versions is the kind they are versions of.</param>
/// <param name="Versions">Whether the level lists the versions of the items rather than the items.</param>
public readonly record struct Level(BaseItemKind Kind, bool Versions = false)
{
    /// <summary>
    /// Gets the key the level goes by in a request, in the configuration and in the strings.
    /// </summary>
    public string Key => Versions ? Hierarchy.Version : Kind.ToString();
}
