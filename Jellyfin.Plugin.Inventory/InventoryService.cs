using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using Jellyfin.Data.Enums;
using Jellyfin.Database.Implementations.Entities;
using Jellyfin.Database.Implementations.Enums;
using MediaBrowser.Controller.Dto;
using MediaBrowser.Controller.Entities;
using MediaBrowser.Controller.Entities.Audio;
using MediaBrowser.Controller.Entities.TV;
using MediaBrowser.Controller.Library;
using MediaBrowser.Model.Entities;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.Inventory;

/// <summary>
/// Builds and caches the inventory rows, and answers queries against them.
/// </summary>
public sealed class InventoryService : IDisposable
{
    private readonly ILibraryManager _libraryManager;
    private readonly IMediaSourceManager _mediaSourceManager;
    private readonly IUserDataManager _userDataManager;
    private readonly IUserManager _userManager;
    private readonly ILogger<InventoryService> _logger;
    private readonly ConcurrentDictionary<BaseItemKind, Cached> _cache = new();

    // Playback is per user, so the shared rows are copied once per user and the copies carry it.
    private readonly ConcurrentDictionary<(BaseItemKind Kind, Guid UserId, bool Everyone), Cached> _perUser = new();

    // Reading playback for every user costs a query each, so the totals are copied onto their own set.
    private readonly ConcurrentDictionary<BaseItemKind, Cached> _everyone = new();

    // Rows built before a library change are dropped the next time they are asked for.
    private int _generation;

    private int _userStamp;

    /// <summary>
    /// Initializes a new instance of the <see cref="InventoryService"/> class.
    /// </summary>
    /// <param name="libraryManager">Instance of the <see cref="ILibraryManager"/> interface.</param>
    /// <param name="mediaSourceManager">Instance of the <see cref="IMediaSourceManager"/> interface.</param>
    /// <param name="userDataManager">Instance of the <see cref="IUserDataManager"/> interface.</param>
    /// <param name="userManager">Instance of the <see cref="IUserManager"/> interface.</param>
    /// <param name="logger">Instance of the <see cref="ILogger{InventoryService}"/> interface.</param>
    public InventoryService(
        ILibraryManager libraryManager,
        IMediaSourceManager mediaSourceManager,
        IUserDataManager userDataManager,
        IUserManager userManager,
        ILogger<InventoryService> logger)
    {
        _libraryManager = libraryManager;
        _mediaSourceManager = mediaSourceManager;
        _userDataManager = userDataManager;
        _userManager = userManager;
        _logger = logger;

        _libraryManager.ItemAdded += OnLibraryChanged;
        _libraryManager.ItemUpdated += OnLibraryChanged;
        _libraryManager.ItemRemoved += OnLibraryChanged;
        _userDataManager.UserDataSaved += OnUserDataSaved;
    }

    /// <summary>
    /// Gets the tabs that hold at least one item, with their levels.
    /// </summary>
    /// <param name="culture">The culture the captions are translated into.</param>
    /// <returns>The populated media types.</returns>
    public IReadOnlyList<MediaTypeInfo> GetMediaTypes(string? culture)
    {
        var types = new List<MediaTypeInfo>();
        foreach (var levels in Hierarchy.All)
        {
            var counts = levels.Select(Count).ToArray();
            var first = Array.FindIndex(counts, c => c > 0);
            if (first < 0)
            {
                continue;
            }

            // Music filed loose in a library has tracks and no album, and a tab listing the empty
            // album level would carry no row to reach them from.
            var available = levels
                .Where((l, i) => i >= first && counts[i] > 0)
                .Select(l => new LevelInfo(l.ToString(), Translations.Get(culture, "level." + l)))
                .ToArray();

            types.Add(new MediaTypeInfo(
                levels[0].ToString(),
                Translations.Get(culture, "mediaType." + levels[0]),
                counts[first],
                available));
        }

        return types;
    }

    // Jellyfin keeps an extra in the general query, so it is counted and taken off again.
    private int Count(BaseItemKind kind) => Total(kind, []) - Total(kind, Enum.GetValues<ExtraType>());

    private int Total(BaseItemKind kind, ExtraType[] extras) => _libraryManager.GetCount(new InternalItemsQuery
    {
        IncludeItemTypes = [kind],
        Recursive = true,
        IsVirtualItem = false,
        ExtraTypes = extras
    });

    // The default options join images, provider ids and every user's playback into each item.
    private static DtoOptions Lean() => new(false) { EnableImages = false, EnableUserData = false };

    /// <summary>
    /// Runs a query against one level of one media type.
    /// </summary>
    /// <param name="mediaType">The media type to list.</param>
    /// <param name="level">The level within it, or null for the outermost.</param>
    /// <param name="parentIds">When given, only the children of those items are returned.</param>
    /// <param name="user">The user whose playback data the rows carry, or null for none.</param>
    /// <param name="everyone">Whether the rows carry the playback totals over every user.</param>
    /// <param name="columns">The columns to return.</param>
    /// <param name="search">An optional substring the name, series or path must contain.</param>
    /// <param name="sortBy">The column key to sort on.</param>
    /// <param name="descending">Whether to sort descending.</param>
    /// <param name="startIndex">The first row to return.</param>
    /// <param name="limit">How many rows to return.</param>
    /// <param name="culture">The culture aggregated values are worded in.</param>
    /// <param name="topmost">Whether a row a matching row above it already accounts for is left out.</param>
    /// <returns>The matching page and the totals behind it.</returns>
    public InventoryPage Query(
        string mediaType,
        string? level,
        IReadOnlyList<Guid>? parentIds,
        User? user,
        bool everyone,
        IReadOnlyList<ColumnDefinition> columns,
        string? search,
        string? sortBy,
        bool descending,
        int startIndex,
        int limit,
        string? culture = null,
        bool topmost = false)
    {
        var kind = Hierarchy.Resolve(mediaType, level)
            ?? throw new ArgumentException($"Unknown media type '{mediaType}' or level '{level}'.", nameof(mediaType));

        // The account list is what notices one that came or went, and a request that spans three
        // levels would otherwise ask the database for it three times over.
        if (everyone)
        {
            Users();
        }

        IReadOnlyList<InventoryRow> rows;
        var spanning = !string.IsNullOrWhiteSpace(search)
            && parentIds is not { Count: > 0 }
            && kind == Hierarchy.Levels(mediaType)![0];

        if (spanning)
        {
            // A search reaches through the whole tab: typing an episode name in the series view has
            // to find the episode, which is not on the level being listed.
            rows = Hierarchy.Levels(mediaType)!
                .SelectMany(l => Rows(l, user, everyone))
                .Where(r => Matches(r, search!))
                .ToArray();
        }
        else
        {
            rows = Rows(kind, user, everyone);

            if (parentIds is { Count: > 0 })
            {
                var wanted = parentIds.ToHashSet();
                rows = rows.Where(r => r.ParentId.HasValue && wanted.Contains(r.ParentId.Value)).ToArray();
            }

            if (!string.IsNullOrWhiteSpace(search))
            {
                rows = rows.Where(r => Matches(r, search)).ToArray();
            }
        }

        // A series and its episodes can both match, and the bytes are then counted twice.
        var counted = rows;
        if (spanning && rows.Count > 1)
        {
            var present = rows.Select(r => r.Id).ToHashSet();
            counted = rows.Where(r => !Covered(r, present)).ToArray();
        }

        // A file carries no totals line, so it holds the rows the totals are made of instead.
        if (topmost)
        {
            rows = counted;
        }

        // No column reproduces the season and episode order the children arrive in.
        var sortColumn = Columns.Find(sortBy) ?? (parentIds is null ? columns[0] : null);
        IEnumerable<InventoryRow> sorted = rows;
        if (sortColumn is not null)
        {
            var order = sortColumn.Sort ?? sortColumn.Value;
            sorted = rows.OrderBy(
                r => SortKey(order(r)),
                descending ? NullsLastComparer.Descending : NullsLastComparer.Ascending);
        }

        var mixed = Translations.Get(culture, "Mixed");
        var page = sorted.Skip(startIndex).Take(limit)
            .Select(r => new InventoryRowResult(
                r.Id,
                r.ParentId,
                r.Expandable,
                columns.ToDictionary(c => c.Key, c => Present(r, c, mixed))));

        return new InventoryPage(
            page,
            rows.Count,
            counted.Sum(r => r.Size ?? 0),
            counted.Sum(r => r.Duration ?? 0));
    }

    /// <inheritdoc />
    public void Dispose()
    {
        _libraryManager.ItemAdded -= OnLibraryChanged;
        _libraryManager.ItemUpdated -= OnLibraryChanged;
        _libraryManager.ItemRemoved -= OnLibraryChanged;
        _userDataManager.UserDataSaved -= OnUserDataSaved;

        // Nothing can invalidate these once the handlers are gone.
        _cache.Clear();
        _perUser.Clear();
        _everyone.Clear();
    }

    private static object? Present(InventoryRow row, ColumnDefinition column, string mixed)
        => row.Mixed?.Contains(column.Key) == true ? mixed : column.Value(row);

    private static bool Covered(InventoryRow row, HashSet<Guid> present)
        => (row.ParentId.HasValue && present.Contains(row.ParentId.Value))
            || (row.AncestorId.HasValue && present.Contains(row.AncestorId.Value));

    private static bool Matches(InventoryRow row, string search)
        => row.Name.Contains(search, StringComparison.OrdinalIgnoreCase)
            || (row.SeriesName?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false)
            || (row.Path?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false);

    private static IComparable? SortKey(object? value) => value switch
    {
        null => null,
        string s => s,
        DateTime d => d,
        bool b => b ? 1d : 0d,
        IConvertible c => Convert.ToDouble(c, CultureInfo.InvariantCulture),
        _ => value.ToString()
    };

    private void OnLibraryChanged(object? sender, ItemChangeEventArgs e)
    {
        // No column of this table is drawn from an image.
        if (e?.UpdateReason == ItemUpdateType.ImageUpdate)
        {
            return;
        }

        // A person, a studio or a playlist is on no row, and a metadata refresh writes a great many
        // of them. A library stays, because its name shows up in a column.
        if (e?.Item is { } item
            && Hierarchy.Of(item.GetBaseItemKind()) is null
            && item is not CollectionFolder)
        {
            return;
        }

        Interlocked.Increment(ref _generation);
        _perUser.Clear();
        _everyone.Clear();
    }

    private void OnUserDataSaved(object? sender, UserDataSaveEventArgs e)
    {
        // The report that passes the resume threshold is also the one that marks it played.
        if (e.SaveReason == UserDataSaveReason.PlaybackProgress && e.UserData is not { Played: true })
        {
            return;
        }

        // Marking an episode played moves the season and the series with it, so the whole tab goes.
        if (e.Item is null || Hierarchy.Of(e.Item.GetBaseItemKind()) is not { } levels)
        {
            return;
        }

        // A play by anyone moves the totals, so they go whichever user wrote it.
        foreach (var kind in levels)
        {
            _everyone.TryRemove(kind, out _);
        }

        // By entry rather than by key, or a set another thread has just published is taken with it.
        foreach (var entry in _perUser)
        {
            if ((entry.Key.UserId == e.UserId || entry.Key.Everyone) && levels.Contains(entry.Key.Kind))
            {
                _perUser.TryRemove(entry);
            }
        }
    }

    private IReadOnlyList<InventoryRow> Rows(BaseItemKind kind, User? user, bool everyone)
    {
        if (user is null)
        {
            return everyone ? Everyone(kind) : Shared(kind);
        }

        return Build(_perUser, (kind, user.Id, everyone), _ =>
        {
            // Read inside the factory, or an invalidation landing in between is stamped away.
            var basis = everyone ? Everyone(kind) : Shared(kind);
            var levels = Hierarchy.Of(kind);
            var leaf = levels is null ? kind : levels[^1];

            if (leaf != kind)
            {
                // Jellyfin keeps no playback record on a series, a season or an album, and folds
                // what its own client shows there out of the children.
                var toLeaves = levels![0] == kind;
                var byParent = Rows(leaf, user, everyone).ToLookup(r => toLeaves ? r.AncestorId : r.ParentId);

                return basis.Select(row =>
                {
                    var copy = row.Copy();
                    FoldPlayback(copy, byParent[row.Id].ToArray());
                    return copy;
                }).ToArray();
            }

            var playback = _userDataManager.GetUserDataBatch(Items(kind), user);

            return basis.Select(row =>
            {
                if (!playback.TryGetValue(row.Id, out var data))
                {
                    return row;
                }

                var copy = row.Copy();
                copy.PlayCount = data.PlayCount > 0 ? data.PlayCount : null;
                copy.LastPlayed = data.LastPlayedDate;
                copy.Played = data.Played;
                return copy;
            }).ToArray();
        });
    }

    private IReadOnlyList<InventoryRow> Everyone(BaseItemKind kind)
        => Build(_everyone, kind, k => BuildEveryone(k, Users()));

    // A bit stands for a user by position, so the order has to hold across levels built at
    // different moments, and nothing tells a plugin that an account came or went.
    private User[] Users()
    {
        var users = _userManager.GetUsers().OrderBy(u => u.Id).ToArray();
        var stamp = users.Aggregate(users.Length, (hash, user) => (hash * 31) + user.Id.GetHashCode());
        if (Interlocked.Exchange(ref _userStamp, stamp) != stamp)
        {
            _everyone.Clear();
            foreach (var entry in _perUser)
            {
                if (entry.Key.Everyone)
                {
                    _perUser.TryRemove(entry);
                }
            }
        }

        return users;
    }

    private IReadOnlyList<InventoryRow> BuildEveryone(BaseItemKind kind, IReadOnlyList<User> users)
    {
        var rows = Shared(kind);
        var levels = Hierarchy.Of(kind);
        var leaf = levels is null ? kind : levels[^1];

        if (leaf != kind)
        {
            var toLeaves = levels![0] == kind;
            var byParent = Everyone(leaf).ToLookup(r => toLeaves ? r.AncestorId : r.ParentId);

            return rows.Select(row =>
            {
                var copy = row.Copy();
                FoldEveryone(copy, byParent[row.Id].ToArray());
                return copy;
            }).ToArray();
        }

        var items = Items(kind);
        var copies = rows.Select(r => r.Copy()).ToArray();
        var watchers = new List<int>?[copies.Length];
        var index = 0;

        foreach (var user in users)
        {
            var playback = _userDataManager.GetUserDataBatch(items, user);
            for (var at = 0; at < copies.Length; at++)
            {
                var copy = copies[at];
                if (!playback.TryGetValue(copy.Id, out var data))
                {
                    continue;
                }

                if (data.PlayCount > 0)
                {
                    copy.EveryonePlayCount = (copy.EveryonePlayCount ?? 0) + data.PlayCount;
                }

                if (data.LastPlayedDate is { } played
                    && (copy.EveryoneLastPlayed is null || played > copy.EveryoneLastPlayed))
                {
                    copy.EveryoneLastPlayed = played;
                }

                if (data.Played)
                {
                    (watchers[at] ??= []).Add(index);
                }
            }

            index++;
        }

        for (var at = 0; at < copies.Length; at++)
        {
            if (watchers[at] is { } set)
            {
                copies[at].PlayedBy = set;
            }
        }

        return copies;
    }

    private static void FoldPlayback(InventoryRow row, IReadOnlyList<InventoryRow> children)
    {
        if (children.Count == 0)
        {
            return;
        }

        var plays = children.Sum(c => c.PlayCount ?? 0);
        row.PlayCount = plays > 0 ? plays : null;
        row.LastPlayed = children.Max(c => c.LastPlayed);
        row.Played = children.All(c => c.Played == true);
    }

    private static void FoldEveryone(InventoryRow row, IReadOnlyList<InventoryRow> children)
    {
        if (children.Count == 0)
        {
            return;
        }

        var plays = children.Sum(c => c.EveryonePlayCount ?? 0);
        row.EveryonePlayCount = plays > 0 ? plays : null;
        row.EveryoneLastPlayed = children.Max(c => c.EveryoneLastPlayed);
        row.PlayedBy = children.Select(c => c.PlayedBy).Aggregate(Shared);
    }

    // Both sides list their users in the order the server gave them, so one pass down the two is enough.
    private static IReadOnlyList<int> Shared(IReadOnlyList<int> left, IReadOnlyList<int> right)
    {
        if (left.Count == 0 || right.Count == 0)
        {
            return [];
        }

        var both = new List<int>(Math.Min(left.Count, right.Count));
        for (int a = 0, b = 0; a < left.Count && b < right.Count;)
        {
            if (left[a] == right[b])
            {
                both.Add(left[a]);
                a++;
                b++;
            }
            else if (left[a] < right[b])
            {
                a++;
            }
            else
            {
                b++;
            }
        }

        return both;
    }

    private IReadOnlyList<InventoryRow> Shared(BaseItemKind kind) => Build(_cache, kind, BuildRows);

    // Lazy rather than a plain factory: a page that opens several tabs builds each set once.
    private IReadOnlyList<InventoryRow> Build<TKey>(
        ConcurrentDictionary<TKey, Cached> cache,
        TKey key,
        Func<TKey, IReadOnlyList<InventoryRow>> build)
        where TKey : notnull
    {
        // Stamped when the entry is made and not when it finishes, or a set folded from one that
        // was still building would hold older rows under the newer number.
        if (cache.TryGetValue(key, out var existing) && existing.Generation != Volatile.Read(ref _generation))
        {
            cache.TryRemove(new KeyValuePair<TKey, Cached>(key, existing));
        }

        var entry = cache.GetOrAdd(key, k => new Cached(
            Volatile.Read(ref _generation),
            new Lazy<IReadOnlyList<InventoryRow>>(() => build(k), LazyThreadSafetyMode.ExecutionAndPublication)));

        try
        {
            return entry.Rows.Value;
        }
        catch
        {
            // A faulted Lazy rethrows forever, so the entry has to go rather than be found again.
            cache.TryRemove(new KeyValuePair<TKey, Cached>(key, entry));
            throw;
        }
    }

    private IReadOnlyList<InventoryRow> BuildRows(BaseItemKind kind)
    {
        var levels = Hierarchy.Of(kind);
        var leaf = levels is null ? kind : levels[^1];
        var items = Items(kind);
        var roots = _libraryManager.GetUserRootFolder().Children.OfType<Folder>().ToList();
        var rows = new List<InventoryRow>(items.Count);

        if (leaf == kind)
        {
            // A book or a photo never has a stream, and asking anyway is one query per item.
            var streamed = kind is not (BaseItemKind.Book or BaseItemKind.Photo);

            // Reading the path of the others would name a folder rip "2049" after its own name.
            var fromPath = kind is BaseItemKind.Book or BaseItemKind.Photo or BaseItemKind.AudioBook;

            foreach (var item in items)
            {
                var row = NewRow(item, roots);
                if (streamed)
                {
                    ApplyStreams(row, _mediaSourceManager.GetMediaStreams(item.Id));
                }

                if (fromPath)
                {
                    ApplyFile(row, item);
                }

                rows.Add(row);
            }
        }
        else
        {
            // The leaf rows already carry every stream attribute, so a series totals its episodes
            // from memory instead of asking the database again for each series and each season.
            var toLeaves = levels![0] == kind;
            var byParent = Shared(leaf).ToLookup(r => toLeaves ? r.AncestorId : r.ParentId);

            // What can be opened is the level directly below, which for a series is its seasons
            // rather than the episodes it is totalled from.
            var below = toLeaves && levels[1] != leaf
                ? Shared(levels[1]).ToLookup(r => r.ParentId)
                : byParent;

            foreach (var item in items)
            {
                var row = NewRow(item, roots);
                Fold(row, byParent[item.Id].ToArray());
                row.Expandable = below[item.Id].Any();
                rows.Add(row);
            }
        }

        _logger.LogDebug("Built {Count} inventory rows for {Kind}", rows.Count, kind);
        return rows;
    }

    private IReadOnlyList<BaseItem> Items(BaseItemKind kind) => _libraryManager.GetItemList(new InternalItemsQuery
    {
        IncludeItemTypes = [kind],
        Recursive = true,
        IsVirtualItem = false,
        // Kept wherever the sorted column ties, which is what orders the episodes of a season.
        OrderBy =
        [
            (ItemSortBy.ParentIndexNumber, SortOrder.Ascending),
            (ItemSortBy.IndexNumber, SortOrder.Ascending),
            (ItemSortBy.SortName, SortOrder.Ascending)
        ],
        DtoOptions = Lean()
    // A trailer or a making of belongs to the film it sits with, not to a row of its own.
    }).Where(item => item.ExtraType is null).ToArray();

    private static void Fold(InventoryRow row, IReadOnlyList<InventoryRow> children)
    {
        row.Children = children.Count;
        if (children.Count == 0)
        {
            // A series whose episodes are all missing would otherwise report its metadata runtime.
            row.Size = null;
            row.Duration = null;
            row.Container = null;
            return;
        }

        var mixed = new HashSet<string>(StringComparer.Ordinal);
        row.Mixed = mixed;

        row.Size = children.Any(c => c.Size.HasValue) ? children.Sum(c => c.Size ?? 0) : null;
        // Rounded, or adding up seventy-two episodes writes 721.6560000000011 into the spreadsheet.
        row.Duration = children.Any(c => c.Duration.HasValue)
            ? Math.Round(children.Sum(c => c.Duration ?? 0), 3)
            : null;

        row.Container = Common(children, c => c.Container, mixed, "container");
        row.VideoCodec = Common(children, c => c.VideoCodec, mixed, "videoCodec");
        row.VideoProfile = Common(children, c => c.VideoProfile, mixed, "videoProfile");
        row.Resolution = Common(children, c => c.Resolution, mixed, "resolution");
        row.VideoRange = Common(children, c => c.VideoRange, mixed, "videoRange");
        row.DolbyVision = Common(children, c => c.DolbyVision, mixed, "dolbyVision");
        row.PixelFormat = Common(children, c => c.PixelFormat, mixed, "pixelFormat");
        row.AudioCodec = Common(children, c => c.AudioCodec, mixed, "audioCodec");
        row.AudioLayout = Common(children, c => c.AudioLayout, mixed, "audioLayout");
        row.SpatialAudio = Common(children, c => c.SpatialAudio, mixed, "spatialAudio");
        row.AudioLanguages = Common(children, c => c.AudioLanguages, mixed, "audioLanguages");
        row.SubtitleLanguages = Common(children, c => c.SubtitleLanguages, mixed, "subtitleLanguages");

        row.Width = CommonValue(children, c => c.Width, mixed, null);
        row.Height = CommonValue(children, c => c.Height, mixed, "height");
        row.BitDepth = CommonValue(children, c => c.BitDepth, mixed, "bitDepth");
        row.FrameRate = CommonValue(children, c => c.FrameRate, mixed, "frameRate");
        row.Interlaced = CommonValue(children, c => c.Interlaced, mixed, "interlaced");
        row.AudioChannels = CommonValue(children, c => c.AudioChannels, mixed, "audioChannels");
        row.AudioSampleRate = CommonValue(children, c => c.AudioSampleRate, mixed, "audioSampleRate");
        row.AudioBitrate = CommonValue(children, c => c.AudioBitrate, mixed, "audioBitrate");
        row.VideoBitrate = CommonValue(children, c => c.VideoBitrate, mixed, "videoBitrate");
        row.AudioTracks = CommonValue(children, c => c.AudioTracks, mixed, "audioTracks");
        row.SubtitleTracks = CommonValue(children, c => c.SubtitleTracks, mixed, "subtitleTracks");

        row.Rateable = children.All(c => c.Size.HasValue && c.Duration.HasValue);
        row.TotalBitrate = row.Rateable && row.Size is > 0 && row.Duration is > 0
            ? (long?)(row.Size.Value * 8 / row.Duration.Value)
            : null;
    }

    private InventoryRow NewRow(BaseItem item, List<Folder> roots)
    {
        var row = new InventoryRow
        {
            Id = item.Id,
            Name = item.Name ?? string.Empty,
            Year = item.ProductionYear,
            Path = item.Path,
            Container = item.Container,
            Size = item.Size,
            DateAdded = item.DateCreated > DateTime.MinValue ? item.DateCreated : null,
            Duration = item.RunTimeTicks is > 0 ? item.RunTimeTicks.Value / (double)TimeSpan.TicksPerSecond : null,
            Library = _libraryManager.GetCollectionFolders(item, roots).FirstOrDefault()?.Name
        };

        if (item is Video video && video.AdditionalParts.Length > 0)
        {
            // A stacked film keeps its later parts as items of their own, and carries only the first.
            var parts = video.GetAdditionalParts().ToArray();
            var bytes = (item.Size ?? 0) + parts.Sum(p => p.Size ?? 0);
            row.Size = bytes > 0 ? bytes : null;
            var ticks = (item.RunTimeTicks ?? 0) + parts.Sum(p => p.RunTimeTicks ?? 0);
            row.Duration = ticks > 0 ? ticks / (double)TimeSpan.TicksPerSecond : null;
        }

        if (item is Episode episode)
        {
            row.SeriesName = episode.SeriesName;
            row.SeasonNumber = episode.ParentIndexNumber;
            row.EpisodeNumber = episode.IndexNumber;
            row.ParentId = Identifier(episode.SeasonId);
            row.AncestorId = Identifier(episode.SeriesId);
        }
        else if (item is Season season)
        {
            row.SeriesName = season.SeriesName;
            row.SeasonNumber = season.IndexNumber;
            row.ParentId = Identifier(season.SeriesId);
            row.AncestorId = row.ParentId;
        }
        else if (item is Audio track)
        {
            row.ParentId = track.AlbumEntity?.Id;
            row.AncestorId = row.ParentId;
        }

        return row;
    }

    private static Guid? Identifier(Guid value) => value.Equals(default) ? null : value;

    // Jellyfin names no container for a photo, a book or an audiobook, and keeps a photo's
    // dimensions on the item rather than on a stream. Both are only read where nothing was found.
    private static void ApplyFile(InventoryRow row, BaseItem item)
    {
        // A folder that happens to carry a dot, such as "Show 2.0" or "Dune 2.10", is not a format.
        if (string.IsNullOrEmpty(row.Container)
            && Path.GetExtension(item.Path) is { Length: > 2 } suffix
            && suffix[1..].All(char.IsAsciiLetterOrDigit)
            && suffix[1..].Any(char.IsAsciiLetter))
        {
            row.Container = suffix[1..].ToLowerInvariant();
        }

        if (row.Height is null && item.Width > 0 && item.Height > 0)
        {
            row.Width = item.Width;
            row.Height = item.Height;
            row.Resolution = string.Create(CultureInfo.InvariantCulture, $"{item.Width}x{item.Height}");
        }
    }

    private void ApplyStreams(InventoryRow row, IReadOnlyList<MediaStream> streams)
    {
        var video = streams.FirstOrDefault(s => s.Type == MediaStreamType.Video);
        if (video is not null)
        {
            row.VideoCodec = video.Codec;
            row.VideoProfile = video.Profile;
            row.VideoBitrate = video.BitRate;
            row.Width = video.Width is > 0 ? video.Width : null;
            row.Height = video.Height is > 0 ? video.Height : null;
            row.FrameRate = video.ReferenceFrameRate;
            row.BitDepth = video.BitDepth;
            row.PixelFormat = video.PixelFormat;
            row.Interlaced = video.IsInterlaced;
            row.Resolution = video.Width is > 0 && video.Height is > 0
                ? string.Create(CultureInfo.InvariantCulture, $"{video.Width}x{video.Height}")
                : null;
            row.VideoRange = video.VideoRangeType == VideoRangeType.Unknown ? null : video.VideoRangeType.ToString();
            row.DolbyVision = video.VideoDoViTitle;
        }

        var audioStreams = streams.Where(s => s.Type == MediaStreamType.Audio).ToArray();
        var audio = audioStreams.FirstOrDefault(s => s.IsDefault) ?? audioStreams.FirstOrDefault();
        if (audio is not null)
        {
            row.AudioCodec = audio.Codec;
            row.AudioLayout = audio.ChannelLayout;
            row.AudioChannels = audio.Channels;
            row.AudioBitrate = audio.BitRate;
            row.AudioSampleRate = audio.SampleRate;
            row.SpatialAudio = audio.AudioSpatialFormat == AudioSpatialFormat.None ? null : audio.AudioSpatialFormat.ToString();
        }

        // A file waiting to be probed has no streams at all, not a file that carries no sound.
        row.AudioTracks = streams.Count > 0 ? audioStreams.Length : null;
        row.AudioLanguages = Join(audioStreams.Select(s => s.Language));

        var subtitles = streams.Where(s => s.Type == MediaStreamType.Subtitle).ToArray();
        row.SubtitleTracks = streams.Count > 0 ? subtitles.Length : null;
        row.SubtitleLanguages = Join(subtitles.Select(s => s.Language));

        row.TotalBitrate = row.Size is > 0 && row.Duration is > 0
            ? (long?)(row.Size.Value * 8 / row.Duration.Value)
            : streams.Sum(s => (long)(s.BitRate ?? 0)) is var sum && sum > 0 ? sum : null;
    }

    private static string? Join(IEnumerable<string?> values)
    {
        // "und" is the ISO 639-2 code for undetermined, not a German word.
        var distinct = values
            .Select(v => string.IsNullOrWhiteSpace(v) ? "und" : v)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Order(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        return distinct.Length > 0 ? string.Join(", ", distinct) : null;
    }

    // A value the children disagree on is left empty and the column noted, so the table can word it
    // rather than showing the blank cell an unprobed file gets. Nothing counts as disagreement.
    private static T? CommonValue<T>(
        IReadOnlyList<InventoryRow> children,
        Func<InventoryRow, T?> read,
        ISet<string> mixed,
        string? column)
        where T : struct
    {
        var values = children.Select(read).Where(v => v.HasValue).Select(v => v!.Value).ToArray();
        var distinct = values.Distinct().Take(2).ToArray();
        if (distinct.Length == 1 && values.Length == children.Count)
        {
            return distinct[0];
        }

        if (distinct.Length > 0 && column is not null)
        {
            mixed.Add(column);
        }

        return null;
    }

    private static string? Common(
        IReadOnlyList<InventoryRow> children,
        Func<InventoryRow, string?> read,
        ISet<string> mixed,
        string column)
    {
        var values = children.Select(read).Where(v => !string.IsNullOrEmpty(v)).ToArray();
        var distinct = values.Distinct(StringComparer.OrdinalIgnoreCase).Take(2).ToArray();
        if (distinct.Length == 1 && values.Length == children.Count)
        {
            return distinct[0];
        }

        if (distinct.Length > 0)
        {
            mixed.Add(column);
        }

        return null;
    }

    private sealed record Cached(int Generation, Lazy<IReadOnlyList<InventoryRow>> Rows);

    // Empty cells belong at the end whichever way the column is sorted, so the direction is applied
    // here rather than by OrderByDescending, which would reverse the nulls along with the values.
    private sealed class NullsLastComparer : IComparer<IComparable?>
    {
        private readonly int _sign;

        private NullsLastComparer(int sign) => _sign = sign;

        public static NullsLastComparer Ascending { get; } = new(1);

        public static NullsLastComparer Descending { get; } = new(-1);

        public int Compare(IComparable? x, IComparable? y)
        {
            if (x is null)
            {
                return y is null ? 0 : 1;
            }

            if (y is null)
            {
                return -1;
            }

            // Linguistic rather than ordinal, or "Ärzte" sorts behind "Zulu" in four of the five
            // languages this ships with.
#pragma warning disable CA1309
            return _sign * (x is string a && y is string b
                ? string.Compare(a, b, StringComparison.InvariantCultureIgnoreCase)
                : x.CompareTo(y));
#pragma warning restore CA1309
        }
    }
}
