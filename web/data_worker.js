/*
 * Signal Analysis Studio - data worker
 *
 * Keeps ZIP directory parsing, CSV parsing, YAML application and processed
 * ZIP creation off Flutter Web's UI event loop. The protocol intentionally uses small positional arrays so it
 * survives structured-clone boundaries without framework-specific objects.
 *
 * Requests:
 *   ['index', requestId, archiveId, Uint8Array]
 *   ['extract', requestId, archiveId, entryId]
 *   ['clear', 0]
 * Responses:
 *   ['indexed', requestId, JSON-string entries]
 *   ['extracted', requestId, Uint8Array]
 *   ['error', requestId, message]
 */
'use strict';

const archives = new Map();
const outputSessions = new Map();
const decoderUtf8 = new TextDecoder('utf-8');
const decoderLatin1 = new TextDecoder('latin1');
const encoderUtf8 = new TextEncoder();

self.onmessage = async (event) => {
  const message = event.data;
  if (!Array.isArray(message) || message.length < 2) return;

  const type = message[0];
  const requestId = Number(message[1]) || 0;

  try {
    if (type === 'clear') {
      archives.clear();
      outputSessions.clear();
      return;
    }

    if (type === 'release') {
      archives.delete(String(message[2]));
      return;
    }

    if (type === 'index') {
      const archiveId = String(message[2]);
      const payload = message[3];
      const bytes = payload instanceof Uint8Array
        ? payload
        : new Uint8Array(payload);
      const entries = parseZipDirectory(bytes);
      for (const entry of entries) {
        if (!entry.path.toLowerCase().endsWith('.csv')) continue;
        if (entry.method !== 0 && entry.method !== 8) {
          throw new Error(`Unsupported ZIP compression method ${entry.method} for ${entry.path}.`);
        }
        if (entry.method === 8 && typeof DecompressionStream !== 'function') {
          throw new Error('Browser has no DecompressionStream support.');
        }
      }
      archives.set(archiveId, {
        bytes,
        entries: new Map(entries.map((entry) => [entry.id, entry])),
      });

      const publicEntries = entries.map((entry) => ({
        id: entry.id,
        path: entry.path,
        compressedSize: entry.compressedSize,
        uncompressedSize: entry.uncompressedSize,
      }));
      self.postMessage(['indexed', requestId, JSON.stringify(publicEntries)]);
      return;
    }

    if (type === 'extract') {
      const archiveId = String(message[2]);
      const entryId = Number(message[3]);
      const archive = archives.get(archiveId);
      if (!archive) throw new Error(`ZIP archive ${archiveId} is not loaded.`);
      const entry = archive.entries.get(entryId);
      if (!entry) throw new Error(`ZIP entry ${entryId} was not found.`);

      const result = await extractEntry(archive.bytes, entry);
      self.postMessage(['extracted', requestId, result], [result.buffer]);
      return;
    }

    if (type === 'parseCsv') {
      const payload = message[2];
      const bytes = payload instanceof Uint8Array
        ? payload
        : new Uint8Array(payload);
      const parsed = parseCsv(bytes);
      postParsedCsv(requestId, parsed);
      return;
    }

    if (type === 'parseZipEntry') {
      const archiveId = String(message[2]);
      const entryId = Number(message[3]);
      const archive = archives.get(archiveId);
      if (!archive) throw new Error(`ZIP archive ${archiveId} is not loaded.`);
      const entry = archive.entries.get(entryId);
      if (!entry) throw new Error(`ZIP entry ${entryId} was not found.`);
      const bytes = await extractEntry(archive.bytes, entry);
      const parsed = parseCsv(bytes);
      postParsedCsv(requestId, parsed);
      return;
    }

    if (type === 'processCsvToOutput') {
      const sessionId = String(message[2]);
      const path = String(message[3]);
      const payload = message[4];
      const rules = parseTransformRules(message[5]);
      const bytes = payload instanceof Uint8Array
        ? payload
        : new Uint8Array(payload);
      const processed = transformCsv(bytes, rules);
      addOutputFile(sessionId, path, processed);
      self.postMessage(['outputAdded', requestId, processed.byteLength]);
      return;
    }

    if (type === 'processZipEntryToOutput') {
      const sessionId = String(message[2]);
      const archiveId = String(message[3]);
      const entryId = Number(message[4]);
      const path = String(message[5]);
      const rules = parseTransformRules(message[6]);
      const archive = archives.get(archiveId);
      if (!archive) throw new Error(`ZIP archive ${archiveId} is not loaded.`);
      const entry = archive.entries.get(entryId);
      if (!entry) throw new Error(`ZIP entry ${entryId} was not found.`);
      const bytes = await extractEntry(archive.bytes, entry);
      const processed = transformCsv(bytes, rules);
      addOutputFile(sessionId, path, processed);
      self.postMessage(['outputAdded', requestId, processed.byteLength]);
      return;
    }

    if (type === 'addTextToOutput') {
      const sessionId = String(message[2]);
      const path = String(message[3]);
      const text = String(message[4] ?? '');
      addOutputFile(sessionId, path, encoderUtf8.encode(text));
      self.postMessage(['outputAdded', requestId, text.length]);
      return;
    }

    if (type === 'finalizeOutput') {
      const sessionId = String(message[2]);
      const files = outputSessions.get(sessionId) || [];
      const zip = buildStoredZip(files);
      outputSessions.delete(sessionId);
      self.postMessage(['outputZip', requestId, zip], [zip.buffer]);
      return;
    }

    if (type === 'discardOutput') {
      outputSessions.delete(String(message[2]));
      self.postMessage(['outputDiscarded', requestId]);
      return;
    }

    throw new Error(`Unsupported worker request: ${String(type)}`);
  } catch (error) {
    const messageText = error && error.message ? error.message : String(error);
    // ZIP indexing receives a transferred ArrayBuffer. Return it to the main
    // thread on failure so Dart can execute the compatibility fallback without
    // keeping a second full archive copy during normal operation.
    if (type === 'index') {
      const payload = message[3];
      const bytes = payload instanceof Uint8Array
        ? payload
        : new Uint8Array(payload);
      self.postMessage(['indexError', requestId, messageText, bytes], [bytes.buffer]);
      return;
    }
    self.postMessage(['error', requestId, messageText]);
  }
};


class Float64ColumnBuilder {
  constructor(chunkSize = 8192) {
    this.chunkSize = chunkSize;
    this.chunks = [];
    this.active = new Float64Array(chunkSize);
    this.activeLength = 0;
    this.length = 0;
  }

  add(value) {
    if (this.activeLength === this.active.length) {
      this.chunks.push(this.active);
      this.active = new Float64Array(this.chunkSize);
      this.activeLength = 0;
    }
    this.active[this.activeLength++] = value;
    this.length++;
  }

  finish() {
    const out = new Float64Array(this.length);
    let offset = 0;
    for (const chunk of this.chunks) {
      out.set(chunk, offset);
      offset += chunk.length;
    }
    if (this.activeLength > 0) {
      out.set(this.active.subarray(0, this.activeLength), offset);
    }
    return out;
  }
}

function postParsedCsv(requestId, parsed) {
  const metadata = {
    headers: parsed.headers,
    logicalHeaders: parsed.logicalHeaders,
    normalizationScales: parsed.normalizationScales,
    minimumValues: parsed.minimumValues,
    maximumValues: parsed.maximumValues,
    rowCount: parsed.rowCount,
  };
  const transfer = parsed.columns.map((column) => column.buffer);
  self.postMessage(
    ['parsedCsv', requestId, JSON.stringify(metadata), parsed.columns],
    transfer,
  );
}

function parseCsv(bytes) {
  const text = decoderUtf8.decode(bytes);
  if (!text.length) {
    return {
      headers: [],
      logicalHeaders: [],
      normalizationScales: [],
      minimumValues: [],
      maximumValues: [],
      rowCount: 0,
      columns: [],
    };
  }

  let headers = null;
  let columns = null;
  let logical = null;
  let logicalSeen = null;
  let maxAbs = null;
  let minimumValues = null;
  let maximumValues = null;
  let rowCount = 0;

  const row = [];
  let field = '';
  let inQuotes = false;

  const commitField = () => {
    row.push(field);
    field = '';
  };

  const consumeRow = () => {
    if (!row.length) return;
    if (headers === null) {
      headers = row.map((value) => value.trim());
      columns = headers.map(() => new Float64ColumnBuilder());
      logical = headers.map(() => true);
      logicalSeen = headers.map(() => false);
      maxAbs = headers.map(() => 0);
      minimumValues = headers.map(() => Number.POSITIVE_INFINITY);
      maximumValues = headers.map(() => Number.NEGATIVE_INFINITY);
      row.length = 0;
      return;
    }

    if (row.length === 1 && row[0].trim() === '') {
      row.length = 0;
      return;
    }

    for (let j = 0; j < headers.length; j++) {
      const parsed = j < row.length ? parseCsvCell(row[j]) : null;
      if (parsed === null) {
        columns[j].add(0);
        minimumValues[j] = Math.min(minimumValues[j], 0);
        maximumValues[j] = Math.max(maximumValues[j], 0);
        logical[j] = false;
        continue;
      }
      columns[j].add(parsed);
      maxAbs[j] = Math.max(maxAbs[j], Math.abs(parsed));
      minimumValues[j] = Math.min(minimumValues[j], parsed);
      maximumValues[j] = Math.max(maximumValues[j], parsed);
      if (parsed === 0 || parsed === 1) {
        logicalSeen[j] = true;
      } else {
        logical[j] = false;
      }
    }
    rowCount++;
    row.length = 0;
  };

  for (let i = 0; i < text.length; i++) {
    const ch = text.charCodeAt(i);
    if (ch === 34) { // quote
      if (inQuotes && i + 1 < text.length && text.charCodeAt(i + 1) === 34) {
        field += '"';
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (!inQuotes && ch === 44) { // comma
      commitField();
    } else if (!inQuotes && (ch === 10 || ch === 13)) { // newline
      commitField();
      consumeRow();
      if (ch === 13 && i + 1 < text.length && text.charCodeAt(i + 1) === 10) {
        i++;
      }
    } else {
      field += text[i];
    }
  }

  if (field.length || row.length) {
    commitField();
    consumeRow();
  }

  if (headers === null || columns === null) {
    return {
      headers: [],
      logicalHeaders: [],
      normalizationScales: [],
      minimumValues: [],
      maximumValues: [],
      rowCount: 0,
      columns: [],
    };
  }

  const logicalHeaders = [];
  for (let i = 0; i < headers.length; i++) {
    if (logical[i] && logicalSeen[i]) logicalHeaders.push(headers[i]);
  }

  return {
    headers,
    logicalHeaders,
    normalizationScales: maxAbs.map((value) => value === 0 ? 1 : value),
    minimumValues: minimumValues.map((value) => Number.isFinite(value) ? value : 0),
    maximumValues: maximumValues.map((value) => Number.isFinite(value) ? value : 0),
    rowCount,
    columns: columns.map((builder) => builder.finish()),
  };
}

function parseCsvCell(raw) {
  const value = String(raw).trim();
  if (!value.length) return null;
  const lower = value.toLowerCase();
  if (lower === 'true') return 1;
  if (lower === 'false') return 0;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}


function parseTransformRules(raw) {
  if (!raw) return { logical: {}, invalid: [] };
  const decoded = typeof raw === 'string' ? JSON.parse(raw) : raw;
  const logical = decoded && typeof decoded.logical === 'object'
    ? decoded.logical
    : {};
  const invalid = Array.isArray(decoded && decoded.invalid)
    ? decoded.invalid
        .filter((range) => Array.isArray(range) && range.length >= 2)
        .map((range) => [Number(range[0]), Number(range[1])])
        .filter((range) => Number.isInteger(range[0]) && Number.isInteger(range[1]) && range[0] <= range[1])
        .sort((a, b) => a[0] - b[0])
    : [];
  return { logical, invalid };
}

function addOutputFile(sessionId, path, bytes) {
  const files = outputSessions.get(sessionId) || [];
  files.push({ path, bytes: bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes) });
  outputSessions.set(sessionId, files);
}

function transformCsv(bytes, rules) {
  const logicalKeys = Object.keys(rules.logical || {});
  const invalid = rules.invalid || [];
  if (!logicalKeys.length && !invalid.length) return bytes.slice();

  const text = decoderUtf8.decode(bytes);
  if (!text.length) return bytes.slice();

  let headers = null;
  const output = [];
  const row = [];
  let field = '';
  let inQuotes = false;
  let sampleIndex = 0;
  let invalidCursor = 0;
  let logicalPlans = null;

  const commitField = () => {
    row.push(field);
    field = '';
  };

  const serializeRow = (cells) => {
    output.push(cells.map(escapeCsvCell).join(','), '\n');
  };

  const consumeRow = () => {
    if (!row.length) return;
    if (headers === null) {
      headers = row.map((value) => value.trim());
      logicalPlans = [];
      for (const feature of logicalKeys) {
        const column = headers.indexOf(feature);
        if (column < 0) continue;
        const ranges = Array.isArray(rules.logical[feature])
          ? rules.logical[feature]
              .filter((entry) => Array.isArray(entry) && entry.length >= 3)
              .map((entry) => [Number(entry[0]), Number(entry[1]), Number(entry[2])])
              .filter((entry) => Number.isInteger(entry[0]) && Number.isInteger(entry[1]) &&
                  entry[0] <= entry[1] && (entry[2] === 0 || entry[2] === 1))
              .sort((a, b) => a[0] - b[0])
          : [];
        if (ranges.length) logicalPlans.push({ column, ranges, cursor: 0 });
      }
      serializeRow(row);
      row.length = 0;
      return;
    }

    // Ignore a completely empty trailing line, matching the analyzer parser.
    if (row.length === 1 && row[0].trim() === '') {
      row.length = 0;
      return;
    }

    // IMPORTANT ORDER: apply logical 0/1 edits using ORIGINAL sample indexes
    // before deciding whether this original row belongs to an invalid range.
    for (const plan of logicalPlans) {
      while (plan.cursor < plan.ranges.length &&
          plan.ranges[plan.cursor][1] < sampleIndex) {
        plan.cursor++;
      }
      if (plan.cursor < plan.ranges.length) {
        const range = plan.ranges[plan.cursor];
        if (sampleIndex >= range[0] && sampleIndex <= range[1]) {
          while (row.length <= plan.column) row.push('');
          row[plan.column] = String(range[2]);
        }
      }
    }

    while (invalidCursor < invalid.length && invalid[invalidCursor][1] < sampleIndex) {
      invalidCursor++;
    }
    const remove = invalidCursor < invalid.length &&
      sampleIndex >= invalid[invalidCursor][0] &&
      sampleIndex <= invalid[invalidCursor][1];

    if (!remove) serializeRow(row);
    sampleIndex++;
    row.length = 0;
  };

  for (let i = 0; i < text.length; i++) {
    const ch = text.charCodeAt(i);
    if (ch === 34) {
      if (inQuotes && i + 1 < text.length && text.charCodeAt(i + 1) === 34) {
        field += '"';
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (!inQuotes && ch === 44) {
      commitField();
    } else if (!inQuotes && (ch === 10 || ch === 13)) {
      commitField();
      consumeRow();
      if (ch === 13 && i + 1 < text.length && text.charCodeAt(i + 1) === 10) i++;
    } else {
      field += text[i];
    }
  }
  if (field.length || row.length) {
    commitField();
    consumeRow();
  }
  return encoderUtf8.encode(output.join(''));
}

function escapeCsvCell(value) {
  const text = String(value ?? '');
  if (!/[",\r\n]/.test(text)) return text;
  return `"${text.replace(/"/g, '""')}"`;
}

function crc32(bytes) {
  let crc = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) {
    crc ^= bytes[i];
    for (let bit = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function buildStoredZip(files) {
  if (files.length > 0xffff) throw new Error('Too many output files for non-ZIP64 export.');
  const locals = [];
  const central = [];
  let offset = 0;
  const dosTime = 0;
  const dosDate = 0x21; // 1980-01-01

  for (const file of files) {
    const nameBytes = encoderUtf8.encode(file.path);
    const data = file.bytes instanceof Uint8Array ? file.bytes : new Uint8Array(file.bytes);
    if (data.byteLength > 0xffffffff || offset > 0xffffffff) {
      throw new Error('Output is too large for non-ZIP64 export.');
    }
    const checksum = crc32(data);
    const local = new Uint8Array(30 + nameBytes.length + data.length);
    const lv = new DataView(local.buffer);
    lv.setUint32(0, 0x04034b50, true);
    lv.setUint16(4, 20, true);
    lv.setUint16(6, 0x0800, true); // UTF-8 names
    lv.setUint16(8, 0, true); // stored
    lv.setUint16(10, dosTime, true);
    lv.setUint16(12, dosDate, true);
    lv.setUint32(14, checksum, true);
    lv.setUint32(18, data.length, true);
    lv.setUint32(22, data.length, true);
    lv.setUint16(26, nameBytes.length, true);
    lv.setUint16(28, 0, true);
    local.set(nameBytes, 30);
    local.set(data, 30 + nameBytes.length);
    locals.push(local);

    const cd = new Uint8Array(46 + nameBytes.length);
    const cv = new DataView(cd.buffer);
    cv.setUint32(0, 0x02014b50, true);
    cv.setUint16(4, 20, true);
    cv.setUint16(6, 20, true);
    cv.setUint16(8, 0x0800, true);
    cv.setUint16(10, 0, true);
    cv.setUint16(12, dosTime, true);
    cv.setUint16(14, dosDate, true);
    cv.setUint32(16, checksum, true);
    cv.setUint32(20, data.length, true);
    cv.setUint32(24, data.length, true);
    cv.setUint16(28, nameBytes.length, true);
    cv.setUint16(30, 0, true);
    cv.setUint16(32, 0, true);
    cv.setUint16(34, 0, true);
    cv.setUint16(36, 0, true);
    cv.setUint32(38, 0, true);
    cv.setUint32(42, offset, true);
    cd.set(nameBytes, 46);
    central.push(cd);
    offset += local.length;
  }

  const centralOffset = offset;
  const centralSize = central.reduce((sum, part) => sum + part.length, 0);
  const totalSize = centralOffset + centralSize + 22;
  if (totalSize > 0xffffffff) throw new Error('Output ZIP exceeds 4 GiB ZIP32 limit.');
  const out = new Uint8Array(totalSize);
  let cursor = 0;
  for (const part of locals) { out.set(part, cursor); cursor += part.length; }
  for (const part of central) { out.set(part, cursor); cursor += part.length; }
  const ev = new DataView(out.buffer, cursor, 22);
  ev.setUint32(0, 0x06054b50, true);
  ev.setUint16(4, 0, true);
  ev.setUint16(6, 0, true);
  ev.setUint16(8, files.length, true);
  ev.setUint16(10, files.length, true);
  ev.setUint32(12, centralSize, true);
  ev.setUint32(16, centralOffset, true);
  ev.setUint16(20, 0, true);
  return out;
}

function parseZipDirectory(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const eocd = findEndOfCentralDirectory(view);
  const entryCount = view.getUint16(eocd + 10, true);
  const directorySize = view.getUint32(eocd + 12, true);
  const directoryOffset = view.getUint32(eocd + 16, true);

  if (entryCount === 0xffff ||
      directorySize === 0xffffffff ||
      directoryOffset === 0xffffffff) {
    throw new Error('ZIP64 archive: use the Dart fallback path.');
  }

  const end = directoryOffset + directorySize;
  if (directoryOffset < 0 || end > bytes.byteLength) {
    throw new Error('Invalid ZIP central directory bounds.');
  }

  const entries = [];
  let cursor = directoryOffset;
  let id = 0;

  while (cursor + 46 <= end && entries.length < entryCount) {
    if (view.getUint32(cursor, true) !== 0x02014b50) {
      throw new Error('Invalid ZIP central directory header.');
    }

    const flags = view.getUint16(cursor + 8, true);
    const method = view.getUint16(cursor + 10, true);
    const compressedSize = view.getUint32(cursor + 20, true);
    const uncompressedSize = view.getUint32(cursor + 24, true);
    const fileNameLength = view.getUint16(cursor + 28, true);
    const extraLength = view.getUint16(cursor + 30, true);
    const commentLength = view.getUint16(cursor + 32, true);
    const localHeaderOffset = view.getUint32(cursor + 42, true);

    if (compressedSize === 0xffffffff ||
        uncompressedSize === 0xffffffff ||
        localHeaderOffset === 0xffffffff) {
      throw new Error('ZIP64 entry: use the Dart fallback path.');
    }

    const nameStart = cursor + 46;
    const nameEnd = nameStart + fileNameLength;
    if (nameEnd > bytes.byteLength) {
      throw new Error('Invalid ZIP filename bounds.');
    }
    const nameBytes = bytes.subarray(nameStart, nameEnd);
    const utf8 = (flags & 0x0800) !== 0;
    const path = (utf8 ? decoderUtf8 : decoderLatin1).decode(nameBytes);

    if (localHeaderOffset + 30 > bytes.byteLength ||
        view.getUint32(localHeaderOffset, true) !== 0x04034b50) {
      throw new Error(`Invalid local header for ${path}.`);
    }
    const localNameLength = view.getUint16(localHeaderOffset + 26, true);
    const localExtraLength = view.getUint16(localHeaderOffset + 28, true);
    const dataOffset = localHeaderOffset + 30 + localNameLength + localExtraLength;
    if (dataOffset + compressedSize > bytes.byteLength) {
      throw new Error(`Invalid compressed data bounds for ${path}.`);
    }

    entries.push({
      id: id++,
      path,
      method,
      flags,
      compressedSize,
      uncompressedSize,
      dataOffset,
    });

    cursor = nameEnd + extraLength + commentLength;
  }

  return entries;
}

function findEndOfCentralDirectory(view) {
  // EOCD is at least 22 bytes. ZIP comments can add at most 65535 bytes.
  const minimum = Math.max(0, view.byteLength - 22 - 0xffff);
  for (let offset = view.byteLength - 22; offset >= minimum; offset--) {
    if (view.getUint32(offset, true) === 0x06054b50) return offset;
  }
  throw new Error('ZIP end-of-central-directory record was not found.');
}

async function extractEntry(bytes, entry) {
  const compressed = bytes.subarray(
    entry.dataOffset,
    entry.dataOffset + entry.compressedSize,
  );

  if (entry.method === 0) {
    // Stored entry: clone before transferring so the archive backing buffer is
    // not detached from the worker.
    return compressed.slice();
  }

  if (entry.method !== 8) {
    throw new Error(`Unsupported ZIP compression method ${entry.method}.`);
  }

  if (typeof DecompressionStream !== 'function') {
    throw new Error('Browser has no DecompressionStream support.');
  }

  const stream = new Blob([compressed])
    .stream()
    .pipeThrough(new DecompressionStream('deflate-raw'));
  const buffer = await new Response(stream).arrayBuffer();
  const output = new Uint8Array(buffer);

  if (entry.uncompressedSize && output.byteLength !== entry.uncompressedSize) {
    throw new Error(
      `Decompressed size mismatch for ${entry.path}: ` +
      `${output.byteLength} != ${entry.uncompressedSize}`,
    );
  }
  return output;
}
