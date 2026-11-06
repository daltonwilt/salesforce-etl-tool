import { loadScript } from "lightning/platformResourceLoader";
import JSZIP_URL from "@salesforce/resourceUrl/jszip";

/**
 * What every export format shares: loading a library from a static resource, reading rows,
 * turning a value into its column's type, and zipping files together.
 *
 *   import { cellReader, typedValue, dateConverter, zip } from "c/export";
 *
 * c/xlsx and c/csv write the formats; this decides what each cell holds, so a sheet carries the
 * same values whichever format the user picks.
 *
 * Rows are arrays in column order, or objects read through each column's fieldName - the shape
 * lightning-datatable takes. Column types follow lightning-datatable: a percent is a fraction
 * (0.125 is 12.5%), dates are "YYYY-MM-DD" or Date objects, and date-times are ISO strings with an
 * offset, epoch milliseconds or Date objects.
 */

/** The column types a sheet understands. Anything else is text. */
export const COLUMN_TYPES = [
  "text",
  "number",
  "integer",
  "currency",
  "percent",
  "date",
  "datetime",
  "boolean"
];

export const NUMERIC_TYPES = new Set(["number", "integer", "currency", "percent"]);

/* ── Libraries ────────────────────────────────────────────────────────────────────────────────── */

const loading = {};

/**
 * Load a static resource script once per page and return the global it defines. A failed load is
 * forgotten, so the next export tries again rather than failing for the rest of the page.
 *
 * @param {LightningElement} cmp the calling component - loadScript needs one
 * @param {string} url           the static resource, from @salesforce/resourceUrl
 * @param {string} globalName    what the script defines, e.g. "ExcelJS"
 * @returns {Promise<any>} the library
 * @throws {Error} "The <globalName> library could not be loaded."
 */
export async function loadLibrary(cmp, url, globalName) {
  const scope = typeof window !== "undefined" ? window : globalThis;
  if (!scope[globalName]) {
    loading[url] = loading[url] || loadScript(cmp, url);
    try {
      await loading[url];
    } catch (e) {
      delete loading[url];
      throw new Error(`The ${globalName} library could not be loaded.`, { cause: e });
    }
  }
  if (!scope[globalName]) {
    throw new Error(`The ${globalName} library could not be loaded.`);
  }
  return scope[globalName];
}

/**
 * A deflated zip archive of the given files, in order, built with JSZip.
 *
 * @param {LightningElement} cmp the calling component, for loadScript
 * @param {Array<{name: string, data: Uint8Array|string}>} entries strings are written as UTF-8
 * @returns {Promise<Uint8Array>} the archive's bytes
 */
export async function zip(cmp, entries) {
  const JSZip = await loadLibrary(cmp, JSZIP_URL, "JSZip");
  const archive = new JSZip();
  for (const entry of entries) {
    archive.file(entry.name, entry.data);
  }
  return archive.generateAsync({ type: "uint8array", compression: "DEFLATE" });
}

/* ── Values ───────────────────────────────────────────────────────────────────────────────────── */

/** A function reading one column's value from a row, whether the row is an array or an object. */
export function cellReader(column, index) {
  const fieldName = column && column.fieldName;
  return (row) => {
    if (row == null) return null;
    if (Array.isArray(row)) return row[index];
    return fieldName ? row[fieldName] : undefined;
  };
}

/** The column's type, or "text" for a missing or unknown one. */
export function normalizeType(type) {
  const value = String(type || "text").toLowerCase();
  return COLUMN_TYPES.includes(value) ? value : "text";
}

/**
 * A cell's value as its column's type: a boolean, a number, a Date (see dateConverter), or a
 * string. Null for an empty cell. A value that does not fit its type comes back as a string
 * rather than being lost.
 *
 * @param {any} value       the raw value
 * @param {string} type     a normalized column type
 * @param {Function} toDate from dateConverter()
 */
export function typedValue(value, type, toDate) {
  if (value === null || value === undefined || value === "") return null;

  if (type === "boolean") {
    const bool = toBoolean(value);
    if (bool !== null) return bool;
  } else if (NUMERIC_TYPES.has(type)) {
    const number = typeof value === "number" ? value : Number(value);
    if (Number.isFinite(number)) return number;
  } else if (type === "date" || type === "datetime") {
    const date = toDate(value, type);
    if (date) return date;
  }
  return String(value).replace(/\r\n?/g, "\n");
}

function toBoolean(value) {
  if (typeof value === "boolean") return value;
  if (value === 1 || value === 0) return value === 1;
  const text = String(value).trim().toLowerCase();
  if (text === "true") return true;
  if (text === "false") return false;
  return null;
}

/* ── Dates ────────────────────────────────────────────────────────────────────────────────────── */

/**
 * A function turning a date or date-time value into a Date whose UTC fields are what the reader
 * should see, or null when the value is not a date.
 *
 * A spreadsheet date has no time zone - it is the wall-clock time shown - and ExcelJS writes a
 * Date by its UTC fields, so a date-time becomes its wall-clock time in timeZone, held in the UTC
 * fields. A date is never shifted: "2026-11-06" is 6 November everywhere.
 *
 * @param {string} [timeZone] IANA zone, e.g. "America/New_York"; the browser's when blank or unknown
 */
export function dateConverter(timeZone) {
  const wallClock = wallClockReader(timeZone);
  return (value, type) => {
    if (type === "date") {
      const parts = dateParts(value);
      return parts ? new Date(Date.UTC(parts[0], parts[1] - 1, parts[2])) : null;
    }
    const instant = toInstant(value);
    return instant === null ? null : new Date(wallClock(instant));
  };
}

/** [year, month, day] from a "YYYY-MM-DD" string (or the date part of an ISO string) or a Date. */
function dateParts(value) {
  if (value instanceof Date) {
    return Number.isNaN(value.getTime())
      ? null
      : [value.getFullYear(), value.getMonth() + 1, value.getDate()];
  }
  const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(value));
  return match ? [Number(match[1]), Number(match[2]), Number(match[3])] : null;
}

/** Epoch milliseconds from a Date, a number of milliseconds or an ISO string. Null when invalid. */
function toInstant(value) {
  let ms;
  if (value instanceof Date) {
    ms = value.getTime();
  } else if (typeof value === "number") {
    ms = value;
  } else {
    const text = String(value);
    // Not Date.parse alone: it reads a string without an offset as local time in some engines and
    // UTC in others. Salesforce always sends one, so require it rather than guess.
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})$/.test(text)) {
      return null;
    }
    ms = Date.parse(text);
  }
  return Number.isFinite(ms) ? ms : null;
}

const WALL_CLOCK_FIELDS = {
  hourCycle: "h23",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit"
};

/** A function giving an instant's wall-clock time in timeZone, as epoch ms read as UTC. */
function wallClockReader(timeZone) {
  let format;
  try {
    format = new Intl.DateTimeFormat("en-US", {
      ...WALL_CLOCK_FIELDS,
      timeZone: timeZone || undefined
    });
  } catch {
    // An unrecognised zone name is a RangeError; showing browser time beats failing the export.
    format = new Intl.DateTimeFormat("en-US", WALL_CLOCK_FIELDS);
  }
  return (ms) => {
    const parts = {};
    for (const part of format.formatToParts(new Date(ms))) {
      parts[part.type] = Number(part.value);
    }
    return Date.UTC(
      parts.year,
      parts.month - 1,
      parts.day,
      parts.hour % 24, // older engines write midnight as 24 even with h23
      parts.minute,
      parts.second,
      ((ms % 1000) + 1000) % 1000 // formatToParts drops milliseconds
    );
  };
}
