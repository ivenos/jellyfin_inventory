# Changelog

All notable changes to this project are documented in this file, in the format of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Dependencies

- jsdom 30.1.1 -> 30.1.2 (#8)
- mcr.microsoft.com/playwright v1.63.0-noble -> v1.64.0-noble (#9)

## [1.1.0] - 2026-10-02

### Added

- A Quality column, from 144p to 8K, that sorts and filters by class (#7).
- `Schema` lists the quality classes in their order.
- A failed export or column save shows a message of its own.

### Changed

- A CSV names the unit of sizes, runtimes and bitrates in its header (#6).
- An ODS shows runtimes as times, and sizes and bitrates with their unit (#6).
- A filter reads 48,000 as one number, not as 48.

### Fixed

- The sidebar entry could pick the wrong language when English came first.
- Books showed a runtime and a size per hour.
- A series with two notations of 23.976 fps showed a mixed frame rate.
- DVD and Blu-ray folders counted only their first file.
- A .strm file took its bitrate from the size of the text file.
- The table kept its scroll position after a page turn, sort, search or filter.
- A failed first load left an empty page or a disabled filter button.
- Quick changes to the rows per page or the expand level could be saved out of order.
- The spacing was off in right-to-left languages.

### Dependencies

- jsdom 30.1.0 -> 30.1.1 (#4)

## [1.0.0] - 2026-09-17

### Added

- Filters on any column, up to twenty at once.
- An Inventory entry in the dashboard sidebar.
- The Inventory logo above the table, linking to the project.
- Tracks filed loose beside the albums are listed in the Music tab.
- The plugin shows its logo in the catalog and on the plugins page.
- `Schema` lists the filters each column takes.

### Changed

- The Albums tab is called Music and counts tracks.
- The table fills the window and keeps its header in place.
- Plays and Plays (all users) show 0 instead of an empty cell.
- Filters on size, runtime and bitrate match the rounded value the table shows.
- Numbers can be typed with a decimal comma.
- Coming back to the page restores the tab, its sort and its page.
- A CSV quotes every text cell that holds a separator.
- An item kept in several versions counts every file and shows no size per hour.

### Fixed

- A filtered table with fewer than five rows vanished in a low window.
- A movie grouped with a version in another library was counted twice on Jellyfin 12.1.
- A movie played in its second version showed no play count and no date.
- Firefox showed rows above the table header after scrolling.
- Opening the page a second time could leave it empty.
- Turning the page right after typing a filter could run past the last page.
- A library that shrank left the table on a page that was gone.
- A saved filter on a column that no longer exists broke the page.
- The page offered more filters than the server accepts.
- Exports in Arabic and Persian wrote a decimal separator no spreadsheet reads.
- A canceled download was logged as a server error.
- A failed request could leave the rows of another tab on screen.
- Expanded rows stayed open after the table changed.
- A first column of numbers lost its indentation.
- Height was shown with digit grouping.
- The API accepted `parentIds` with an invalid id in it.
- The first load of a large table was slow.

### Security

- A name with a semicolon or a tab could start a formula in a spreadsheet.
- An invented language code on an export caused an error and wasted memory.
- A configuration saved with empty lists broke the plugin until the next restart.

## [0.2.0] - 2026-09-10

### Added

- Rows per page, from 50 to 10000, chosen in the footer and remembered.
- Three columns for playback across all users: Plays, Last played and Fully played by.
- The tab and the export show that they are loading.
- `Schema` reports the language it answered in.

### Changed

- Played is called Fully played.
- A large export no longer builds up in memory and stops when the browser leaves.
- `Items` and `Export` refuse a sort column they do not know.

### Fixed

- A movie split into several files showed the size of its first file and no runtime.
- Trailers and other extras were listed as items of their own and counted in the totals.
- The frame rate could read 1000 fps.
- An item played to the end showed as played only after the next stop.
- The dropdowns had no arrow, and a disabled button looked clickable.
- A failed first load left the page blank.
- Expanding a level on a large page sent hundreds of requests at once.
- A row with nothing below it lost its alignment and the keyboard focus.
- Long paths were not shortened, and the footer did not wrap in a narrow window.
- Screen readers did not announce a page change or which row a control opens.

## [0.1.0] - 2026-09-09

### Added

- A table in the dashboard that lists everything in your libraries, down to a single episode.
- 38 columns in the groups General, Video, Audio, Subtitles and Playback.
- Folder rows total size, runtime and item count, and show Mixed where items differ.
- A column selection per level and how far a tab opens, both remembered.
- Search across all levels, sorting on any column and paging.
- Export of the current view as CSV or ODS.
- English, German, Spanish, French and Italian.

[Unreleased]: https://github.com/ivenos/jellyfin_inventory/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/ivenos/jellyfin_inventory/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/ivenos/jellyfin_inventory/compare/v0.2.0...v1.0.0
[0.2.0]: https://github.com/ivenos/jellyfin_inventory/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ivenos/jellyfin_inventory/releases/tag/v0.1.0
