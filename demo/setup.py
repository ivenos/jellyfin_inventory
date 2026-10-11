#!/usr/bin/env python3
"""Sets a fresh Jellyfin up around the sample library: the first user, the libraries, and once
they are scanned the people who watched them. Prints the administrator's token."""
import json
import pathlib
import sys
import time
import urllib.parse
import urllib.request

base, out = sys.argv[1], pathlib.Path(sys.argv[2])
PASSWORD = "inventoryshots"
LIBRARIES = {"Movies": "movies", "Shows": "tvshows", "Music": "music", "Books": "books", "Photos": "homevideos"}
KINDS = ("Movie", "Series", "Season", "Episode", "MusicArtist", "MusicAlbum", "Audio", "Book", "Photo", "PhotoAlbum")
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
    return call("Items", Recursive="true", IncludeItemTypes="Movie,Episode,Audio,Book,Photo", **fields)


for attempt in range(90):
    try:
        call("Startup/Configuration")
        break
    except OSError:
        time.sleep(2)
else:
    sys.exit("the server did not come up")

call("Startup/Configuration", {"UICulture": "en-US", "MetadataCountryCode": "US", "PreferredMetadataLanguage": "en"})
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
for name, watched in json.loads((out / "plays.json").read_text()).items():
    if name not in users:
        users[name] = call("Users/New", {"Name": name, "Password": PASSWORD})["Id"]
    for path, seen in watched.items():
        call(f"UserItems/{ids[path]}/UserData", {"Played": True, **seen}, userId=users[name])

print(token)
