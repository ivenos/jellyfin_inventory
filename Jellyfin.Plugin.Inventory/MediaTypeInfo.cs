using System.Collections.Generic;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// A tab: a collection kind, how many items its top level holds, and the levels it can be broken down into.
/// </summary>
/// <param name="MediaType">The key of the top level, which also names the tab.</param>
/// <param name="Label">The translated tab caption.</param>
/// <param name="Count">The number of items at the top level.</param>
/// <param name="Levels">The levels available, outermost first.</param>
public sealed record MediaTypeInfo(
    string MediaType,
    string Label,
    int Count,
    IReadOnlyList<LevelInfo> Levels);
