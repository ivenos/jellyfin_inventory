namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// One level of a media type, such as the seasons within a series.
/// </summary>
/// <param name="Level">The level key.</param>
/// <param name="Label">The translated level caption.</param>
public sealed record LevelInfo(string Level, string Label);
