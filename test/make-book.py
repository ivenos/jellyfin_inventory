#!/usr/bin/env python3
"""Writes a minimal EPUB, enough for Jellyfin to catalogue it as a book."""

import hashlib
import sys
import zipfile
from xml.sax.saxutils import escape

path, title, author = sys.argv[1], sys.argv[2], sys.argv[3]
# A stable id: hash() is salted per process, which would give the same book a new identity
# on every run and leave Jellyfin holding two of them.
identifier = hashlib.sha256(title.encode()).hexdigest()[:32]
title, author = escape(title), escape(author)

container = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""

opf = f"""<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="id">urn:uuid:{identifier}</dc:identifier>
    <dc:title>{title}</dc:title>
    <dc:creator>{author}</dc:creator>
    <dc:language>en</dc:language>
  </metadata>
  <manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="c1"/></spine>
</package>"""

chapter = f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{title}</title></head>
<body><h1>{title}</h1><p>Fixture.</p></body></html>"""

with zipfile.ZipFile(path, "w") as book:
    # The mimetype entry has to be first and stored uncompressed.
    book.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", zipfile.ZIP_STORED)
    book.writestr("META-INF/container.xml", container)
    book.writestr("content.opf", opf)
    book.writestr("c1.xhtml", chapter)
