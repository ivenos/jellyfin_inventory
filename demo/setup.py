#!/usr/bin/env python3
"""Sets a fresh Jellyfin up around the sample library: the first user, the libraries, and once
they are scanned the genres, artists, authors and narrators, which Jellyfin reads from the files
alone, the year of the audiobooks, which it reads from no tag of a file over 2 GiB, and the people
who watched them. Prints the administrator's token."""
import json
import pathlib
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

base, out = sys.argv[1], pathlib.Path(sys.argv[2])
PASSWORD = "inventoryshots"
LIBRARIES = {"Movies": "movies", "Shows": "tvshows", "Music": "music", "Audiobooks": "books", "Books": "books", "Photos": "homevideos"}
KINDS = ("Movie", "Series", "Season", "Episode", "MusicArtist", "MusicAlbum", "Audio", "AudioBook", "Book", "Photo", "PhotoAlbum")
token = None


def call(path, body=None, **params):
    known = f'Token="{token}"' if token else 'Client="demo", Device="cli", DeviceId="inventory-demo", Version="1.0.0"'
    request = urllib.request.Request(
        f"{base}/{path}?{urllib.parse.urlencode(params)}",
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": "MediaBrowser " + known, "Content-Type": "application/json"},
        method="GET" if body is None else "POST",
    )
    with urllib.request.urlopen(request, timeout=300) as response:
        answer = response.read()
        return json.loads(answer) if answer else None


def held(**fields):
    return call("Items", Recursive="true", IncludeItemTypes="Movie,Episode,Audio,AudioBook,Book,Photo", **fields)


for attempt in range(90):
    try:
        call("Startup/Configuration")
        break
    except OSError:
        time.sleep(2)
else:
    sys.exit("the server did not come up")

call("Startup/Configuration", {"ServerName": "Jellyfin", "UICulture": "en-US", "MetadataCountryCode": "US", "PreferredMetadataLanguage": "en"})
call("Startup/User")
call("Startup/User", {"Name": "admin", "Password": PASSWORD})
call("Startup/Complete", {})
token = call("Users/AuthenticateByName", {"Username": "admin", "Pw": PASSWORD})["AccessToken"]

# EnableInternetProviders is obsolete in 12.0, an empty fetcher list per type is what holds.
options = {"LibraryOptions": {"EnableChapterImageExtraction": False, "TypeOptions": [
    {"Type": kind, "MetadataFetchers": [], "MetadataFetcherOrder": [], "ImageFetchers": [], "ImageFetcherOrder": []}
    for kind in KINDS]}}
for name, kind in LIBRARIES.items():
    call("Library/VirtualFolders", options, name=name, collectionType=kind, paths="/media/" + name.lower(), refreshLibrary="false")
call("Library/Refresh", {})

files = sum(1 for path in (out / "media").rglob("*") if path.is_file() and path.suffix != ".nfo")
for attempt in range(360):
    found = held(Limit=0)["TotalRecordCount"]
    if found == files and all(task["State"] == "Idle" for task in call("ScheduledTasks") if task["Key"] == "RefreshLibrary"):
        break
    print(f"scanned {found} of {files}", file=sys.stderr, flush=True)
    time.sleep(5)
else:
    sys.exit(f"the library did not settle, {found} of {files} files are in")

ids = {item["Path"]: item["Id"] for item in held(Fields="Path")["Items"]}
users = {user["Name"]: user["Id"] for user in call("Users")}


def tags(item):
    return json.loads((out / "probe" / (item["Path"].removeprefix("/media/") + ".json")).read_text())["format"]["tags"]


def edit(item_id, changes):
    call(f"Items/{item_id}", call(f"Items/{item_id}", userId=users["admin"]) | changes)


edits, albums = [], {}
for track in call("Items", Recursive="true", IncludeItemTypes="Audio", Fields="Path")["Items"]:
    card = tags(track)
    changes = {"Genres": [genre for genre in card.get("genre", "").split(";") if genre],
               "ArtistItems": [{"Name": card["artist"]}], "AlbumArtists": [{"Name": card["album_artist"]}]}
    albums.setdefault(track.get("AlbumId"), changes)
    edits.append((track["Id"], changes))
for book in call("Items", Recursive="true", IncludeItemTypes="AudioBook", Fields="Path")["Items"]:
    card = tags(book)
    people = [{"Name": name, "Type": "Author"} for name in card["artist"].split("; ")]
    people += [{"Name": name, "Type": "Narrator"} for name in card["composer"].split("; ") if name]
    edits.append((book["Id"], {"Genres": [g for g in card["genre"].split(";") if g], "People": people, "ProductionYear": int(card["date"])}))
with ThreadPoolExecutor(8) as pool:
    list(pool.map(lambda pair: edit(*pair), edits))
    list(pool.map(lambda pair: edit(pair[0], {"Genres": pair[1]["Genres"], "AlbumArtists": pair[1]["AlbumArtists"]}),
                  [(album, changes) for album, changes in albums.items() if album]))

for name, watched in json.loads((out / "plays.json").read_text()).items():
    if name not in users:
        users[name] = call("Users/New", {"Name": name, "Password": PASSWORD})["Id"]
    for path, seen in watched.items():
        call(f"UserItems/{ids[path]}/UserData", {"Played": True, **seen}, userId=users[name])

print(token)
