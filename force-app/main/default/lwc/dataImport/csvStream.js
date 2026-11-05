/**
 * Reading a CSV file in the browser without ever holding it whole.
 *
 * The file is streamed, grouped into logical records, and handed out one at a time. Nothing here
 * keeps more than the current record plus the current chunk, so file size is bounded by what the
 * browser will open rather than by anything this code does — which is the point. Apex never sees
 * the file; it sees slices.
 *
 * A "record" is one spreadsheet row, which is not the same as one line: a quoted cell may contain
 * newlines, and every one of these templates carries a ten-line instruction block in a single cell.
 */

/** Default slice size. The Long Text field it lands in holds 131,072 characters. */
export const CHUNK_TARGET_CHARS = 120000;

/**
 * The most a slice may ever be, whatever a template asks for.
 *
 * Data_Import_Chunk__c.Body__c holds 131,072 characters and the insert fails above that. A
 * template sizing by rows cannot know how wide its rows will turn out, so this stays in force
 * underneath any setting.
 */
const HARD_MAX_CHARS = 131000;

/**
 * Slice size for a template: `{ "chunk": { "rows": 500 } }` or `{ "chunk": { "chars": 60000 } }`.
 *
 * Rows and characters are not alternatives at the boundary — a row limit still yields to the
 * character ceiling, because the field cap is a fact and the row count is a preference.
 */
export function chunkLimits(spec) {
  const chunk = (spec && spec.chunk) || {};
  const chars =
    chunk.chars > 0
      ? Math.min(chunk.chars, HARD_MAX_CHARS)
      : CHUNK_TARGET_CHARS;
  const rows = chunk.rows > 0 ? chunk.rows : null;
  return { chars, rows };
}

/**
 * Yields the file's logical records in order.
 *
 * Physical lines are joined while the quote count is odd, which is what RFC 4180 means by a newline
 * inside a quoted field: doubled quotes ("") contribute two, so only an unclosed opening quote
 * leaves the count odd.
 *
 * Decoding is incremental. A byte-range slice can cut a multi-byte character in half, so the
 * decoder is told the stream is continuing and holds the partial character until the next read.
 */
/**
 * The file's bytes, a block at a time.
 *
 * Prefers a ReadableStream, but does not rely on one: Lightning Web Security does not expose
 * Blob.stream() in every context, and without a fallback the whole import dies before it starts.
 * Slicing with FileReader is slower and equally unbounded, which is what actually matters.
 */
async function* blocks(file) {
  if (typeof file.stream === "function") {
    const reader = file.stream().getReader();
    for (;;) {
      // eslint-disable-next-line no-await-in-loop
      const { done, value } = await reader.read();
      if (done) return;
      yield value;
    }
  }

  const BLOCK = 1 << 20; // 1 MB at a time — never the whole file
  for (let start = 0; start < file.size; start += BLOCK) {
    const slice = file.slice(start, Math.min(start + BLOCK, file.size));
    // eslint-disable-next-line no-await-in-loop
    const buffer = await readArrayBuffer(slice);
    yield new Uint8Array(buffer);
  }
}

function readArrayBuffer(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error);
    reader.readAsArrayBuffer(blob);
  });
}

export async function* records(file) {
  const decoder = new TextDecoder("utf-8");
  let buffer = "";
  let pending = null;

  const emit = function* (line) {
    const joined = pending === null ? line : `${pending}\n${line}`;
    if (countQuotes(joined) % 2 === 1) {
      pending = joined;
      return;
    }
    pending = null;
    yield joined;
  };

  for await (const block of blocks(file)) {
    buffer += decoder.decode(block, { stream: true });

    let index = buffer.indexOf("\n");
    while (index >= 0) {
      yield* emit(stripCr(buffer.slice(0, index)));
      buffer = buffer.slice(index + 1);
      index = buffer.indexOf("\n");
    }
  }

  buffer += decoder.decode();
  if (buffer.length) {
    yield* emit(stripCr(buffer));
  }
  // An unterminated quote at end of file: take what is there rather than dropping the row.
  if (pending !== null) {
    yield pending;
  }
}

function stripCr(line) {
  return line.endsWith("\r") ? line.slice(0, -1) : line;
}

function countQuotes(text) {
  let count = 0;
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '"') count++;
  }
  return count;
}

/**
 * One record split into cells, RFC 4180.
 *
 * Only called for records that need inspecting — the section markers and the match key — never for
 * every row, because the rows themselves are shipped to Apex as text and parsed there.
 */
export function cells(record) {
  if (!record.includes('"')) {
    return record.split(",");
  }
  const out = [];
  let field = "";
  let inQuotes = false;
  for (let i = 0; i < record.length; i++) {
    const ch = record[i];
    if (inQuotes) {
      if (ch === '"') {
        if (record[i + 1] === '"') {
          field += '"';
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field += ch;
      }
    } else if (ch === '"') {
      inQuotes = true;
    } else if (ch === ",") {
      out.push(field);
      field = "";
    } else {
      field += ch;
    }
  }
  out.push(field);
  return out;
}

/** 'A' -> 0, 'AA' -> 26. Null for anything that is not a column letter. */
export function columnIndex(letter) {
  if (!letter) return null;
  const upper = String(letter).trim().toUpperCase();
  let index = 0;
  for (let i = 0; i < upper.length; i++) {
    const position = upper.charCodeAt(i) - 65;
    if (position < 0 || position > 25) return null;
    index = index * 26 + (position + 1);
  }
  return index - 1;
}

export function cellAt(list, index) {
  if (index === null || index === undefined || index >= list.length) return "";
  return (list[index] || "").trim();
}

/**
 * Reads the whole file once and produces everything Apex cannot work out for itself.
 *
 * Two of these exist because of where they have to happen, not because it is convenient:
 *
 *   sectionMap      a table whose length is not known until the file is read cannot be located
 *                   from the template, and a chunk cannot infer it from the chunk before — Batch
 *                   Apex does not promise to process chunks in order.
 *   duplicateKeys   needs whole-file state. A Set of a few million keys is comfortable here and
 *                   fatal in a 12 MB Apex heap. Left undetected it is worse than either outcome:
 *                   two rows in one chunk both insert, two rows in different chunks may update
 *                   instead, so the same file gives a different answer depending on where the
 *                   chunk boundary happened to fall.
 *
 * @param file      the user's File
 * @param spec      the parsed template definition
 * @param onChunk   async (body, sequence, firstRowNumber) — staged as it is produced
 * @param onProgress optional (bytesRead, totalBytes)
 */
export async function sliceFile(file, spec, onChunk, onProgress) {
  const rowSections = (spec.sections || []).filter((s) => s.type === "rows");
  const open = new Map(); // sectionName -> firstRow, still looking for its end
  const sectionMap = [];
  const seenKeys = new Map(); // sectionName -> Set of keys
  const duplicates = [];

  let rowNumber = 0;
  let sequence = 0;
  let bytes = 0;
  const limits = chunkLimits(spec);
  let buffer = [];
  let bufferChars = 0;
  let bufferFirstRow = 1;

  const flush = async () => {
    if (!buffer.length) return;
    await onChunk(buffer.join("\n"), sequence, bufferFirstRow);
    sequence++;
    buffer = [];
    bufferChars = 0;
  };

  for await (const record of records(file)) {
    rowNumber++;
    bytes += record.length + 1;

    const parsed = needsInspection(rowSections) ? cells(record) : null;
    if (parsed) {
      trackSections(rowSections, parsed, record, rowNumber, open, sectionMap);
      trackDuplicates(
        rowSections,
        parsed,
        rowNumber,
        open,
        seenKeys,
        duplicates,
      );
    }

    if (!buffer.length) bufferFirstRow = rowNumber;
    buffer.push(record);
    bufferChars += record.length + 1;

    // Always break between records, never inside one — a chunk has to parse on its own.
    if (
      bufferChars >= limits.chars ||
      (limits.rows && buffer.length >= limits.rows)
    ) {
      await flush();
    }
    if (onProgress && rowNumber % 5000 === 0) onProgress(bytes, file.size);
  }
  await flush();

  // Any section still open runs to the end of the file.
  open.forEach((firstRow, sectionName) => {
    sectionMap.push({ sectionName, firstRow, lastRow: null });
  });

  return {
    sectionMap,
    duplicates,
    totalChunks: sequence,
    totalRows: rowNumber,
  };
}

function needsInspection(rowSections) {
  return rowSections.some(
    (s) => s.startsAfter || s.endsAt || s.endsBefore || s.matchOn,
  );
}

/** Opens a section when its marker is seen, and closes it at the first blank row after. */
function trackSections(
  rowSections,
  parsed,
  record,
  rowNumber,
  open,
  sectionMap,
) {
  const blank = record.replace(/[,\s]/g, "").length === 0;

  rowSections.forEach((section) => {
    const key = section.sectionName || "";
    if (open.has(key)) {
      // Two ways a table ends: a blank line, or a row that announces itself as not data — a totals
      // line directly under the last record, which nothing else would catch.
      const endsHere =
        (blank && section.endsAt === "blankRow") ||
        (section.endsBefore && cellAt(parsed, 0).includes(section.endsBefore));
      if (endsHere) {
        sectionMap.push({
          sectionName: key,
          firstRow: open.get(key),
          lastRow: rowNumber - 1,
        });
        open.delete(key);
      }
      return;
    }
    if (section.startsAfter) {
      // The marker sits above the headings, so data begins after both. How many heading rows sit
      // between them is the template's business — assuming one loses the first record of any
      // template that has two, silently and with no error.
      if (cellAt(parsed, 0).includes(section.startsAfter)) {
        const headings = section.headingRows == null ? 1 : section.headingRows;
        open.set(key, rowNumber + 1 + headings);
      }
    } else if (section.firstDataRow && rowNumber === section.firstDataRow) {
      open.set(key, section.firstDataRow);
    }
  });
}

/** Records a key seen twice within one section — the file contradicts itself. */
function trackDuplicates(
  rowSections,
  parsed,
  rowNumber,
  open,
  seenKeys,
  duplicates,
) {
  rowSections.forEach((section) => {
    if (!section.matchOn || !section.matchOn.column) return;
    const key = section.sectionName || "";
    if (!open.has(key) || rowNumber < open.get(key)) return;

    const value = cellAt(parsed, columnIndex(section.matchOn.column));
    if (!value) return;

    if (!seenKeys.has(key)) seenKeys.set(key, new Map());
    const seen = seenKeys.get(key);
    const lower = value.toLowerCase();
    if (seen.has(lower)) {
      duplicates.push(
        `Row ${rowNumber}, column ${section.matchOn.column}: "${value}" also appears on row ${seen.get(lower)}. The key must identify a single record.`,
      );
    } else {
      seen.set(lower, rowNumber);
    }
  });
}
