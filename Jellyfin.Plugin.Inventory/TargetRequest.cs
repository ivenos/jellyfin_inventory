using System;
using System.Collections.Generic;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// Items to add to a collection or a playlist, or to take out of one.
/// </summary>
public class TargetRequest
{
    /// <summary>
    /// Gets or sets the kind of target, <see cref="Hierarchy.Collection"/> or <see cref="Hierarchy.Playlist"/>.
    /// </summary>
    public string? Kind { get; set; }

    /// <summary>
    /// Gets or sets a value indicating whether the items are taken out rather than added.
    /// </summary>
    public bool Remove { get; set; }

    /// <summary>
    /// Gets or sets the id of an existing target.
    /// </summary>
    public Guid? Id { get; set; }

    /// <summary>
    /// Gets or sets the name of a target to create, when adding.
    /// </summary>
    public string? Name { get; set; }

    /// <summary>
    /// Gets or sets the ids of the items.
    /// </summary>
    public IReadOnlyList<Guid>? Ids { get; set; }

    /// <summary>
    /// Gets or sets a listing every row of which is taken as well.
    /// </summary>
    public TargetSelection? All { get; set; }
}
