// Writes the files Inventory/Export answers with, the way Export.cs writes them on a server.

const UNITS = { Bytes: ' (B)', BytesPerHour: ' (B)', Duration: ' (s)', Bitrate: ' (bit/s)' };
const STYLES = { Bytes: 'C-bytes', BytesPerHour: 'C-bytes', Bitrate: 'C-bitrate' };
const ENTITIES = { '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;', '&': '&amp;' };

const MANIFEST = `<?xml version="1.0" encoding="UTF-8"?>
<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
  <manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>
  <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
</manifest:manifest>`;

const OPENING = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" ',
    'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" ',
    'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" ',
    'xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" ',
    'xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0" ',
    'office:version="1.2">',
    '<office:automatic-styles>',
    '<number:date-style style:name="N-date"><number:year number:style="long"/>',
    '<number:text>-</number:text><number:month number:style="long"/>',
    '<number:text>-</number:text><number:day number:style="long"/></number:date-style>',
    '<number:boolean-style style:name="N-bool"><number:boolean/></number:boolean-style>',
    '<number:time-style style:name="N-duration" number:truncate-on-overflow="false"><number:hours/>',
    '<number:text>:</number:text><number:minutes number:style="long"/>',
    '<number:text>:</number:text><number:seconds number:style="long"/></number:time-style>',
    '<number:number-style style:name="N-bytes">',
    '<number:number number:decimal-places="0" number:min-integer-digits="1" number:grouping="true"/>',
    '<number:text> B</number:text></number:number-style>',
    '<number:number-style style:name="N-bitrate">',
    '<number:number number:decimal-places="0" number:min-integer-digits="1" number:grouping="true"/>',
    '<number:text> bit/s</number:text></number:number-style>',
    '<style:style style:name="C-date" style:family="table-cell" style:data-style-name="N-date"/>',
    '<style:style style:name="C-bool" style:family="table-cell" style:data-style-name="N-bool"/>',
    '<style:style style:name="C-duration" style:family="table-cell" style:data-style-name="N-duration"/>',
    '<style:style style:name="C-bytes" style:family="table-cell" style:data-style-name="N-bytes"/>',
    '<style:style style:name="C-bitrate" style:family="table-cell" style:data-style-name="N-bitrate"/>',
    '</office:automatic-styles>',
    '<office:body><office:spreadsheet>',
].join('');

const CRC = Array.from({ length: 256 }, (_, index) => {
    let value = index;
    for (let bit = 0; bit < 8; bit++) { value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1; }
    return value;
});

// What XML 1.0 can hold, which a file name need not keep to.
function printable(value) {
    return String(value).replace(/[^\t\n\r\x20-퟿-�\u{10000}-\u{10FFFF}]/gu, '');
}

function text(value) {
    const cell = printable(value).replace(/^[=+\-@\t\r]/, "'$&");
    return /[,;\t"\r\n]/.test(cell) ? `"${cell.replaceAll('"', '""')}"` : cell;
}

function escape(value) {
    return printable(value).replace(/[<>"'&]/g, (char) => ENTITIES[char]);
}

function sheetName(value) {
    const name = printable(value).replace(/[[\]*?:/\\]/g, '').trim().slice(0, 31).trimEnd();
    return name || 'Inventory';
}

// Math.Round settles a tie on the even side, where Math.round goes up.
function even(value) {
    const rounded = Math.round(value);
    return rounded - value === 0.5 && rounded % 2 ? rounded - 1 : rounded;
}

function two(value) {
    return String(value).padStart(2, '0');
}

function typed(attributes, shown) {
    return `<table:table-cell ${attributes}><text:p>${shown}</text:p></table:table-cell>`;
}

function cell(value, format, sheet) {
    if (value === null || value === undefined) { return '<table:table-cell/>'; }

    if (typeof value === 'number' && format === 'Duration') {
        const time = even(value * 1000);
        const whole = even(time / 1000);
        const span = `PT${Math.trunc(time / 3600000)}H${Math.trunc(time / 60000) % 60}M${(time % 60000) / 1000}S`;
        const clock = `${Math.trunc(whole / 3600)}:${two(Math.trunc(whole / 60) % 60)}:${two(whole % 60)}`;
        return typed(`table:style-name="C-duration" office:value-type="time" office:time-value="${span}"`, clock);
    }

    if (typeof value === 'boolean') {
        return typed(`table:style-name="C-bool" office:value-type="boolean" office:boolean-value="${value}"`,
            escape(value ? sheet.Yes : sheet.No));
    }

    if (typeof value === 'number') {
        const style = STYLES[format] ? `table:style-name="${STYLES[format]}" ` : '';
        return typed(`${style}office:value-type="float" office:value="${value}"`, value);
    }

    if (format === 'Date') {
        const stamp = value.slice(0, 10);
        return typed(`table:style-name="C-date" office:value-type="date" office:date-value="${stamp}"`, stamp);
    }

    return typed('office:value-type="string"', escape(value));
}

function content(sheet) {
    const row = (cells) => `<table:table-row>${cells.join('')}</table:table-row>`;
    return OPENING
        + `<table:table table:name="${escape(sheetName(sheet.SheetName))}">`
        + `<table:table-column table:number-columns-repeated="${sheet.Columns.length}"/>`
        + row(sheet.Columns.map((column) => typed('office:value-type="string"', escape(column.Label))))
        + sheet.Rows.map((line) => row(sheet.Columns.map((column) => cell(line.Values[column.Key], column.Format, sheet)))).join('')
        + '</table:table></office:spreadsheet></office:body></office:document-content>';
}

function crc32(bytes) {
    let crc = -1;
    for (const byte of bytes) { crc = CRC[(crc ^ byte) & 255] ^ (crc >>> 8); }
    return ~crc >>> 0;
}

// Little-endian, each value as wide as the digit in its place says.
function pack(widths, ...values) {
    const view = new DataView(new ArrayBuffer([...widths].reduce((sum, width) => sum + Number(width), 0)));
    let at = 0;
    values.forEach((value, index) => {
        if (widths[index] === '2') { view.setUint16(at, value, true); } else { view.setUint32(at, value, true); }
        at += Number(widths[index]);
    });
    return new Uint8Array(view.buffer);
}

function zip(files) {
    const encoder = new TextEncoder();
    const now = new Date();
    const time = (now.getHours() << 11) | (now.getMinutes() << 5) | (now.getSeconds() >> 1);
    const date = ((now.getFullYear() - 1980) << 9) | ((now.getMonth() + 1) << 5) | now.getDate();
    const entries = [];
    const directory = [];
    let offset = 0;

    for (const [name, written] of files) {
        const path = encoder.encode(name);
        const body = encoder.encode(written);
        const entry = [20, 0, 0, time, date, crc32(body), body.length, body.length, path.length, 0];
        entries.push(pack('42222244422', 0x04034b50, ...entry), path, body);
        directory.push(pack('42222224442222244', 0x02014b50, 20, ...entry, 0, 0, 0, 0, offset), path);
        offset += 30 + path.length + body.length;
    }

    const size = directory.reduce((sum, part) => sum + part.length, 0);
    return [...entries, ...directory, pack('42222442', 0x06054b50, 0, 0, files.length, files.length, size, offset, 0)];
}

function csv(sheet) {
    let comma = false;
    try {
        comma = new Intl.NumberFormat(sheet.Culture).formatToParts(1.5).some((part) => part.type === 'decimal' && part.value === ',');
    } catch { /* A culture nobody knows is written the invariant way. */ }

    const scalar = (value, format) => {
        if (value === null || value === undefined) { return ''; }
        if (typeof value === 'boolean') { return text(value ? sheet.Yes : sheet.No); }
        if (typeof value === 'number') { return String(value).replace('.', comma ? ',' : '.'); }
        return format === 'Date' ? value.slice(0, 10) : text(value);
    };
    const lines = [
        sheet.Columns.map((column) => text(column.Label + (UNITS[column.Format] ?? ''))),
        ...sheet.Rows.map((row) => sheet.Columns.map((column) => scalar(row.Values[column.Key], column.Format))),
    ];

    // The BOM is what makes Excel read it as UTF-8 rather than the local codepage.
    return ['﻿', ...lines.map((line) => line.join(comma ? ';' : ',') + '\r\n')];
}

function ods(sheet) {
    // The mimetype entry has to come first and be stored, not deflated.
    return zip([
        ['mimetype', 'application/vnd.oasis.opendocument.spreadsheet'],
        ['META-INF/manifest.xml', MANIFEST],
        ['content.xml', content(sheet)],
    ]);
}

export function exportFile(sheet) {
    return new Blob(sheet.Format === 'ods' ? ods(sheet) : csv(sheet), { type: sheet.ContentType });
}
