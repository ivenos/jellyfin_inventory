#!/usr/bin/env python3
"""Lays out the sample library: real titles as empty files of a plausible size, and for each one
the answer ffprobe would give for it. Jellyfin reads the answers through probe.sh, so the table
shows a large library without a single encoded frame."""
import copy
import datetime
import json
import os
import pathlib
import random
import re
import struct
import subprocess
import sys
import zipfile
from xml.sax.saxutils import escape

HERE = pathlib.Path(__file__).parent
# Nothing is dated past this day, so the library comes out the same whenever it is built.
TODAY = datetime.date(2026, 9, 1)

# name: (codec, profile, pixel format)
VIDEO = {
    "hevc10": ("hevc", "Main 10", "yuv420p10le"),
    "h264": ("h264", "High", "yuv420p"),
    "vc1": ("vc1", "Advanced", "yuv420p"),
    "av1": ("av1", "Main", "yuv420p10le"),
    "mpeg2": ("mpeg2video", "Main", "yuv420p"),
    "xvid": ("mpeg4", "Advanced Simple Profile", "yuv420p"),
}

# name: (codec, profile, channels, layout, kilobits per second)
AUDIO = {
    "atmos": ("truehd", "Dolby TrueHD + Dolby Atmos", 8, "7.1", 4500),
    "truehd": ("truehd", "Dolby TrueHD", 6, "5.1(side)", 3200),
    "dtsx": ("dts", "DTS-HD MA + DTS:X", 8, "7.1", 4700),
    "dtshd7": ("dts", "DTS-HD MA", 8, "7.1", 4300),
    "dtshd": ("dts", "DTS-HD MA", 6, "5.1(side)", 3400),
    "dtshd1": ("dts", "DTS-HD MA", 1, "mono", 1000),
    "lpcm": ("pcm_s24le", None, 6, "5.1(side)", 6912),
    "dts": ("dts", "DTS", 6, "5.1(side)", 1509),
    "eac3atmos": ("eac3", "Dolby Digital Plus + Dolby Atmos", 6, "5.1(side)", 768),
    "eac3": ("eac3", None, 6, "5.1(side)", 640),
    "ac3": ("ac3", None, 6, "5.1(side)", 640),
    "ac3dvd": ("ac3", None, 6, "5.1(side)", 448),
    "ac3stereo": ("ac3", None, 2, "stereo", 192),
    "aac": ("aac", "LC", 2, "stereo", 160),
    "aac6": ("aac", "LC", 6, "5.1", 384),
    "opus": ("opus", None, 6, "5.1", 320),
    "flac1": ("flac", None, 1, "mono", 620),
    "mp3": ("mp3", None, 2, "stereo", 128),
}

# name: (weight by era old/middle/new, container, video, height, megabits from/to, ranges, audio choices, subtitles, most subtitle tracks)
RELEASES = {
    "uhd remux": ((2, 5, 9), "mkv", "hevc10", 2160, 48, 82, ("dv7", "dv8", "hdr10", "hdr10", "hdr10+"), ("atmos", "atmos", "dtsx", "dtshd7", "dtshd"), "hdmv_pgs_subtitle", 9),
    "uhd web": ((0, 2, 9), "mkv", "hevc10", 2160, 14, 26, ("dv5", "dv8", "hdr10", "hdr10+", "dv8+"), ("eac3atmos", "eac3atmos", "eac3"), "subrip", 12),
    "uhd encode": ((1, 4, 6), "mkv", "hevc10", 2160, 11, 24, ("hdr10", "hdr10", "dv8", "hlg"), ("atmos", "dtshd", "eac3atmos"), "hdmv_pgs_subtitle", 5),
    "remux": ((6, 9, 6), "mkv", "h264", 1080, 22, 36, ("sdr",), ("dtshd", "dtshd", "truehd", "lpcm", "dtshd7"), "hdmv_pgs_subtitle", 8),
    "remux vc1": ((1, 2, 0), "mkv", "vc1", 1080, 18, 28, ("sdr",), ("dtshd", "truehd", "lpcm"), "hdmv_pgs_subtitle", 6),
    "bluray": ((10, 16, 10), "mkv", "h264", 1080, 8, 15, ("sdr",), ("dts", "dts", "ac3", "dtshd"), "subrip", 4),
    "web": ((3, 10, 18), "mkv", "h264", 1080, 4.5, 9, ("sdr",), ("eac3", "eac3", "aac"), "subrip", 10),
    "web mp4": ((1, 3, 4), "mp4", "h264", 1080, 3.5, 7, ("sdr",), ("aac", "aac6"), "mov_text", 2),
    "x265": ((6, 10, 12), "mkv", "hevc10", 1080, 2.4, 7, ("sdr",), ("aac6", "eac3", "opus"), "subrip", 4),
    "av1": ((0, 1, 4), "mkv", "av1", 1080, 1.8, 5, ("sdr",), ("opus",), "subrip", 3),
    "720p": ((8, 9, 4), "mkv", "h264", 720, 3, 6.5, ("sdr",), ("ac3", "ac3dvd", "aac"), "subrip", 2),
    "dvd": ((9, 5, 0), "mkv", "mpeg2", 576, 4.2, 8, ("sdr",), ("ac3dvd", "ac3stereo"), "dvd_subtitle", 5),
    "dvdrip": ((7, 4, 0), "avi", "xvid", 400, 0.9, 1.7, ("sdr",), ("mp3", "ac3dvd"), None, 0),
}

# name: (weight, extension, codec, sample rate, bit depth, kilobits from/to)
MUSIC = {
    "flac": (40, "flac", "flac", 44100, 16, 780, 1050),
    "flac 24/96": (8, "flac", "flac", 96000, 24, 2700, 3200),
    "flac 24/48": (4, "flac", "flac", 48000, 24, 1500, 1750),
    "mp3 320": (18, "mp3", "mp3", 44100, None, 320, 320),
    "mp3 v0": (8, "mp3", "mp3", 44100, None, 225, 265),
    "aac": (12, "m4a", "aac", 44100, None, 256, 256),
    "alac": (4, "m4a", "alac", 44100, 16, 820, 1000),
    "opus": (4, "opus", "opus", 48000, None, 128, 160),
    "vorbis": (2, "ogg", "vorbis", 44100, None, 192, 224),
}

# folder: (file name, width, height, megabytes from/to, pictures)
ROLLS = {
    "2016-08 Baltic Coast": ("IMG_{:04}.JPG", 3264, 2448, 1.6, 2.9, 24),
    "2019-07 Lisbon": ("IMG_{:04}.jpg", 4032, 3024, 2.2, 4.8, 38),
    "2021-02 Winter Hike": ("DSC{:05}.JPG", 6000, 4000, 7.5, 14, 31),
    "2022-09 Norway": ("DSC{:05}.JPG", 6000, 4000, 7.5, 14, 46),
    "2023-05 Wedding": ("P{:07}.JPG", 5184, 3888, 5, 9, 52),
    "2024-08 Sardinia": ("PXL_{:04}.jpg", 4080, 3072, 2.5, 6, 41),
    "2025-12 New Year": ("PXL_{:04}.jpg", 8160, 6120, 9, 17, 18),
}

FILM = (16 / 9, 1.85, 1.85, 2.39, 2.39, 2.39)
TELEVISION = (16 / 9,) * 7 + (2.0, 2.0, 2.39)
FORMATS = {"mkv": "matroska,webm", "mp4": "mov,mp4,m4a,3gp,3g2,mj2", "m4a": "mov,mp4,m4a,3gp,3g2,mj2", "m4b": "mov,mp4,m4a,3gp,3g2,mj2", "opus": "ogg"}
DUBS = ("deu", "deu", "deu", "fra", "spa", "ita")
SUBTITLES = ("eng", "deu", "fra", "spa", "ita", "nld", "por", "swe", "dan", "nor", "fin", "pol")
USERS = ("admin", "mara", "jonas", "lena")


def dimensions(height, year, rng, shapes):
    """The frame a disc of that year would carry: narrow before widescreen, letterboxed after."""
    width = {2160: 3840, 1080: 1920, 720: 1280, 576: 720, 400: 640}[height]
    if height == 576:
        return (720, 576) if rng.random() < 0.6 else (720, 480)
    aspect = 1.37 if year < 1953 else rng.choice(shapes)
    if height == 400:
        return (640, 480) if aspect < 1.7 else (640, round(640 / aspect / 16) * 16)
    if aspect < 1.7:
        return round(height * aspect / 2) * 2, height
    return width, round(width / aspect / 2) * 2


def video(release, year, rng, shapes):
    _, _, kind, height, low, high, ranges, _, _, _ = RELEASES[release]
    codec, profile, pixels = VIDEO[kind]
    width, tall = dimensions(height, year, rng, shapes)
    interlaced = kind == "mpeg2" and rng.random() < 0.7
    rate = "25/1" if (width, tall) == (720, 576) else "30000/1001" if interlaced else rng.choice(("24000/1001",) * 8 + ("24/1", "25/1"))
    look = rng.choice(ranges)
    stream = {
        "codec_name": codec, "profile": profile, "codec_type": "video", "width": width, "height": tall,
        "coded_width": width, "coded_height": tall, "pix_fmt": pixels, "level": 153 if height == 2160 else 41,
        "sample_aspect_ratio": "64:45" if (width, tall) == (720, 576) else "32:27" if (width, tall) == (720, 480) else "1:1",
        "color_range": "tv", "r_frame_rate": rate, "avg_frame_rate": rate, "refs": 1,
        "bit_rate": str(round(rng.uniform(low, high) * tall / height * 1_000_000)),
    }
    if interlaced:
        stream["field_order"] = "tt"
    if look == "sdr":
        stream |= {"color_space": "bt709", "color_transfer": "bt709", "color_primaries": "bt709"} if height >= 720 else {}
    else:
        stream |= {"color_space": "bt2020nc", "color_primaries": "bt2020",
                   "color_transfer": "arib-std-b67" if look == "hlg" else "smpte2084"}
        vision = {"dv5": (5, 0, 0), "dv7": (7, 1, 6), "dv8": (8, 0, 1), "dv8+": (8, 0, 1)}.get(look)
        stream["side_data_list"] = []
        if vision:
            stream["side_data_list"].append({
                "side_data_type": "DOVI configuration record", "dv_version_major": 1, "dv_version_minor": 0,
                "dv_profile": vision[0], "dv_level": 6, "rpu_present_flag": 1, "el_present_flag": vision[1],
                "bl_present_flag": 1, "dv_bl_signal_compatibility_id": vision[2]})
        if look in ("hdr10+", "dv8+"):
            stream["first_frame"] = [{"side_data_type": "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)"}]
    return stream


def audio(kind, language, title=None):
    codec, profile, channels, layout, kilobits = AUDIO[kind]
    stream = {"codec_name": codec, "codec_type": "audio", "sample_rate": "48000", "channels": channels,
              "channel_layout": layout, "bit_rate": str(kilobits * 1000), "tags": {"language": language}}
    if profile:
        stream["profile"] = profile
    if title:
        stream["tags"]["title"] = title
    return stream


def tracks(release, year, language, rng, shapes=FILM):
    """One film's streams: the picture, the original sound, and what a disc adds around them."""
    _, _, _, height, _, _, _, sounds, text, most = RELEASES[release]
    main = rng.choice(sounds)
    if year < 1960 and main in ("dtshd", "dtshd7", "atmos", "dtsx", "truehd", "lpcm"):
        main = rng.choice(("dtshd1", "flac1"))
    streams = [video(release, year, rng, shapes), audio(main, language)]
    if main in ("atmos", "truehd", "dtsx", "dtshd7") and rng.random() < 0.7:
        streams.append(audio("ac3", language))
    if RELEASES[release][1] == "mkv" and rng.random() < 0.38:
        dub = rng.choice([d for d in DUBS if d != language] if language == "eng" else ["eng"])
        streams.append(audio(rng.choice(("ac3", "eac3", "dts") if height >= 1080 else ("ac3dvd", "ac3stereo")), dub))
    if "remux" in release and rng.random() < 0.3:
        streams.append(audio("ac3stereo", language, "Commentary"))
    if text:
        spoken = [language] + [s for s in SUBTITLES if s != language]
        for code in spoken[:rng.randint(0, most)]:
            streams.append({"codec_name": text, "codec_type": "subtitle", "tags": {"language": code}})
    return streams


def release_for(year, rng, pool=RELEASES):
    era = 0 if year < 1990 else 1 if year < 2012 else 2
    names = list(pool)
    return rng.choices(names, weights=[RELEASES[name][0][era] for name in names])[0]


def added(year, rng):
    first = max(datetime.date(2014, 3, 1), datetime.date(year, 6, 1))
    day = first + datetime.timedelta(days=rng.randrange(max(1, (TODAY - first).days)))
    return datetime.datetime.combine(day, datetime.time(rng.randrange(7, 24), rng.randrange(60), rng.randrange(60)))


def jpeg(width, height):
    """A grey picture of that size: per block one bit for no change and one for nothing more."""
    blocks = -(-width // 8) * -(-height // 8)
    table = b"\xff\xc4" + struct.pack(">HB16B", 20, 0, 1, *[0] * 15) + b"\x00"
    return (b"\xff\xd8\xff\xdb" + struct.pack(">HB", 67, 0) + bytes([1] * 64)
            + b"\xff\xc0" + struct.pack(">HBHHBBBB", 11, 8, height, width, 1, 1, 0x11, 0)
            + table + table[:4] + b"\x10" + table[5:]
            + b"\xff\xda" + struct.pack(">HBBBBBB", 8, 1, 1, 0, 0, 63, 0) + bytes(-(-blocks // 4)) + b"\xff\xd9")


def dated(path, day):
    stamp = day.replace(tzinfo=datetime.timezone.utc).timestamp()
    os.utime(path, (stamp, stamp))


def safe(title):
    return re.sub(r'[/\\:*?"<>|]', lambda m: " -" if m.group() == ":" else "", title).strip(" .")


def listed(name):
    return [line.split("\t") for line in (HERE / name).read_text(encoding="utf-8").splitlines()]


class Library:
    def __init__(self, out):
        self.media = pathlib.Path(out, "media")
        self.cards = pathlib.Path(out, "probe")
        self.plays = {user: {} for user in USERS}

    def place(self, relative, size, day, content=b""):
        """A file that is empty past its content, dated the day it joined the library."""
        path = self.media / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "wb") as file:
            file.write(content)
            file.truncate(max(size, len(content)))
        dated(path, day)
        return path

    def probed(self, relative, seconds, streams, day, tags=None):
        size = round(sum(int(s.get("bit_rate", 0)) for s in streams) * seconds / 8 * 1.004)
        path = self.place(relative, size, day)
        for index, stream in enumerate(streams):
            stream |= {"index": index, "disposition": {"default": int(index < 2), "forced": 0}}
        # Jellyfin asks for the first frame too, which is where HDR10+ shows.
        frames = [{"media_type": "video", "stream_index": 0, "side_data_list": streams[0].pop("first_frame")}] if "first_frame" in streams[0] else []
        extension = path.suffix[1:]
        card = self.cards / (relative + ".json")
        card.parent.mkdir(parents=True, exist_ok=True)
        card.write_text(json.dumps({"streams": streams, "frames": frames, "chapters": [], "format": {
            "filename": "/media/" + relative, "nb_streams": len(streams), "format_name": FORMATS.get(extension, extension),
            "duration": f"{seconds:.3f}", "size": str(size), "bit_rate": str(round(size * 8 / seconds)), "tags": tags or {}}}))

    def note(self, folder, kind, day, genres="", **fields):
        """What a folder cannot say for itself: when it was added, its genres, and a title in characters a path may not hold."""
        inner = "".join(f"<{key}>{escape(str(value))}</{key}>" for key, value in (fields | {"dateadded": day}).items())
        inner += "".join(f"<genre>{escape(genre)}</genre>" for genre in genres.split(", ") if genre)
        (self.media / folder).mkdir(parents=True, exist_ok=True)
        (self.media / folder / f"{kind}.nfo").write_text(f"<{kind}>{inner}</{kind}>\n", encoding="utf-8")

    def played(self, relative, since, rng, share, counts=(1, 1, 1, 2, 2, 3, 5)):
        for user in USERS:
            if rng.random() < share[user]:
                day = since + datetime.timedelta(days=rng.randrange(1, 900), minutes=rng.randrange(1440))
                day = min(day, datetime.datetime.combine(TODAY, datetime.time(21, 30)))
                self.plays[user]["/media/" + relative] = {"PlayCount": rng.choice(counts), "LastPlayedDate": day.isoformat() + "Z"}


def movies(library):
    for title, year, minutes, language, genres in listed("movies.tsv"):
        rng = random.Random(f"{title} {year}")
        release = release_for(int(year), rng)
        name = f"{safe(title)} ({year})"
        day = added(int(year), rng)
        relative = f"movies/{name}/{name}.{RELEASES[release][1]}"
        library.probed(relative, int(minutes) * 60 + rng.randrange(60), tracks(release, int(year), language, rng), day)
        library.note(f"movies/{name}", "movie", day, genres, title=title, year=year)
        library.played(relative, day, rng, {"admin": 0.42, "mara": 0.3, "jonas": 0.18, "lena": 0.08})


def series(library):
    episodic = {name: RELEASES[name] for name in ("uhd web", "bluray", "web", "x265", "720p", "dvdrip")}
    for title, year, seasons, episodes, minutes, language, genres in listed("series.tsv"):
        rng = random.Random(f"{title} {year}")
        year, seasons, episodes, minutes = int(year), int(seasons), int(episodes), int(minutes)
        minutes = minutes if 20 <= minutes <= 65 else rng.choice((24, 44, 48, 52, 58))
        show = f"shows/{safe(title)} ({year})"
        day = added(year, rng)
        library.note(show, "tvshow", day, genres, title=title, year=year)
        follows = {user: rng.random() < share for user, share in zip(USERS, (0.5, 0.35, 0.25, 0.1))}
        seen = {user: rng.randrange(1, episodes + 1) for user in USERS}
        shape = (4 / 3 if year < 2004 else rng.choice(TELEVISION),)
        number = 0
        release = None
        for season in range(1, seasons + 1):
            aired = year + season - 1
            # A series mostly comes from one source, and now and then a later season from a newer one.
            if release is None or rng.random() < 0.12:
                release = release_for(aired, rng, episodic)
            # A season is cut the same way throughout, only the bitrate is each episode's own.
            pattern = tracks(release, aired, language, random.Random(f"{title} {release}"), shape)
            # What had aired when the series joined came with it, the rest as it aired.
            arrived = max(day, min(added(aired, rng), datetime.datetime.combine(TODAY, datetime.time(20))))
            library.note(f"{show}/Season {season:02}", "season", arrived)
            for episode in range(1, episodes // seasons + (season <= episodes % seasons) + 1):
                number += 1
                # One episode from another source is what makes a season read as mixed.
                source = release_for(aired, rng, episodic) if rng.random() < 0.004 else release
                streams = copy.deepcopy(pattern) if source == release else tracks(source, aired, language, rng, shape)
                streams[0]["bit_rate"] = str(round(int(streams[0]["bit_rate"]) * rng.uniform(0.75, 1.25)))
                relative = f"{show}/Season {season:02}/{safe(title)} S{season:02}E{episode:02}.{RELEASES[source][1]}"
                at = arrived + datetime.timedelta(minutes=episode)
                library.probed(relative, minutes * 60 + rng.randrange(-180, 240), streams, at)
                library.played(relative, at, rng, {user: float(follows[user] and number <= seen[user]) for user in USERS})


def music(library):
    albums = {}
    for artist, album, year, disc, number, title, seconds, genres in listed("albums.tsv"):
        albums.setdefault((artist, album, int(year), genres), []).append((int(disc), int(number), title, int(seconds)))
    for (artist, album, year, genres), songs in albums.items():
        rng = random.Random(f"{artist} {album}")
        _, extension, codec, rate, depth, low, high = MUSIC[rng.choices(list(MUSIC), weights=[m[0] for m in MUSIC.values()])[0]]
        folder = f"music/{safe(artist)}/{safe(album)} ({year})"
        day = added(year, rng)
        library.note(folder, "album", day)
        liked = {user: rng.random() * share for user, share in zip(USERS, (0.9, 0.5, 0.7, 0.3))}
        for disc, number, title, seconds in songs:
            stream = {"codec_name": codec, "codec_type": "audio", "sample_rate": str(rate), "channels": 2, "channel_layout": "stereo",
                      "bit_rate": str(round(rng.uniform(low, high) * 1000))} | ({"bits_per_raw_sample": str(depth)} if depth else {})
            prefix = f"{disc}-{number:02}" if songs[-1][0] > 1 else f"{number:02}"
            relative = f"{folder}/{prefix} {safe(title)}.{extension}"
            library.probed(relative, max(seconds, 5), [stream], day + datetime.timedelta(seconds=number), {
                "title": title, "artist": artist, "album_artist": artist, "album": album, "date": str(year), "track": str(number), "disc": str(disc),
                "genre": genres.replace(", ", ";")})
            library.played(relative, day, rng, liked, (1, 2, 3, 4, 6, 9, 14, 23, 41))


def audiobooks(library):
    books = {}
    for authors, title, year, number, chapter, seconds, narrators, genres in listed("audiobooks.tsv"):
        books.setdefault((authors, title, int(year), narrators, genres), []).append((int(number), chapter, int(seconds)))
    for (authors, title, year, narrators, genres), chapters in books.items():
        rng = random.Random(f"{authors} {title}")
        day = added(year, rng)
        tags = {"album": title, "artist": authors, "album_artist": authors, "composer": narrators, "genre": genres.replace(", ", ";"), "date": str(year)}
        folder = f"audiobooks/{safe(authors.split('; ')[0])}/{safe(title)}"
        shape = rng.random()
        if shape < 0.5:
            relative = f"audiobooks/{safe(title)}.m4b" if shape < 0.06 else f"{folder}/{safe(title)}.m4b"
            stream = {"codec_name": "aac", "profile": "LC", "codec_type": "audio", "sample_rate": "44100", "channels": 2,
                      "channel_layout": "stereo", "bit_rate": str(rng.choice((62, 62, 125)) * 1000)}
            library.probed(relative, sum(c[2] for c in chapters), [stream], day, tags | {"title": title})
            files = [relative]
        else:
            stereo = rng.random() < 0.4
            files = []
            for number, chapter, seconds in chapters:
                relative = f"{folder}/{number:03} {safe(chapter)}.mp3"
                stream = {"codec_name": "mp3", "codec_type": "audio", "sample_rate": "44100", "channels": 1 + stereo,
                          "channel_layout": "stereo" if stereo else "mono", "bit_rate": str((128 if stereo else 64) * 1000)}
                library.probed(relative, seconds, [stream], day + datetime.timedelta(seconds=number), tags | {"title": chapter, "track": str(number)})
                files.append(relative)
        # A listener is through every file up to the one they stopped in.
        for user, share in zip(USERS, (0.55, 0.3, 0.2, 0.1)):
            if rng.random() < share:
                heard = files if rng.random() < 0.5 else files[:rng.randrange(len(files))]
                for relative in heard:
                    library.played(relative, day, rng, {u: float(u == user) for u in USERS}, (1,))


def books(library):
    for title, author in listed("books.tsv"):
        rng = random.Random(title)
        extension = rng.choice(("epub",) * 8 + ("pdf", "mobi"))
        day = added(2014, rng)
        path = library.place(f"books/{author}/{safe(title)}/{safe(title)}.{extension}", rng.randrange(400_000, 9_000_000), day)
        if extension == "epub":
            subprocess.run([sys.executable, HERE.parent / "test/make-book.py", path, title, author], check=True)
            with zipfile.ZipFile(path, "a") as book:
                book.writestr("cover.jpg", bytes(rng.randrange(150_000, 1_200_000)))
            dated(path, day)


def photos(library):
    for folder, (name, width, height, low, high, count) in ROLLS.items():
        rng = random.Random(folder)
        taken = datetime.datetime(int(folder[:4]), int(folder[5:7]), rng.randrange(1, 15), 9)
        first = rng.randrange(100, 9000)
        for shot in range(count):
            taken += datetime.timedelta(minutes=rng.randrange(2, 400))
            upright = rng.random() < 0.25
            size = (height, width) if upright else (width, height)
            library.place(f"photos/{folder}/{name.format(first + shot)}", round(rng.uniform(low, high) * 1_000_000), taken, jpeg(*size))


if __name__ == "__main__":
    library = Library(sys.argv[1])
    for section in (movies, series, music, audiobooks, books, photos):
        section(library)
    pathlib.Path(sys.argv[1], "plays.json").write_text(json.dumps(library.plays))
