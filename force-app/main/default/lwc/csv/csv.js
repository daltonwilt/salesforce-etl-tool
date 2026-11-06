import PAPAPARSE_URL from "@salesforce/resourceUrl/papaparse";
import {
  cellReader,
  dateConverter,
  loadLibrary,
  normalizeType,
  typedValue
} from "c/export";

/**
 * Writes a sheet as CSV with PapaParse, a static resource copied from npm by
 * scripts/vendor-libraries.js.
 *
 *   import { buildCsv } from "c/csv";
 *
 *   const text = await buildCsv(this, { columns, rows }, { timeZone: TIME_ZONE });
 *
 * Takes the same sheets as c/xlsx - rows, columns and types as c/export describes - and holds
 * the same values, written as plain text. Styles have nothing to apply to and are ignored.
 *
 *   number types  as the number itself, with no grouping or currency symbol; a percent stays a
 *                 fraction (0.125), as Salesforce reports and other systems importing it expect
 *   date          2026-11-06
 *   datetime      2026-11-06 08:30:00, in options.timeZone
 *   boolean       true / false
 *
 * Text that a spreadsheet would run as a formula - starting with = + - @, a tab or a carriage
 * return - is prefixed with an apostrophe. A CSV from Salesforce data is opened in Excel more often
 * than not, and a field value of =HYPERLINK(...) should arrive as text, not as a link.
 */

// Excel reads a CSV as the local ANSI code page unless it starts with a byte order mark, which
// turns every accented name into mojibake. Other readers skip it.
const BYTE_ORDER_MARK = "\ufeff";

/**
 * One sheet as CSV text.
 *
 * @param {LightningElement} cmp the calling component, for loadScript
 * @param {{columns: Array<{label: string, type?: string, fieldName?: string}>,
 *          rows: Array<Array|object>}} sheet
 * @param {object} [options]
 * @param {string} [options.timeZone] IANA zone date-times are shown in. Defaults to the browser's.
 * @param {string} [options.delimiter] defaults to ","
 * @param {boolean} [options.byteOrderMark] start with a UTF-8 byte order mark (default true)
 * @returns {Promise<string>} the CSV, header row first, lines ending CRLF as RFC 4180 has it
 */
export async function buildCsv(cmp, sheet, options = {}) {
  const Papa = await loadLibrary(cmp, PAPAPARSE_URL, "Papa");
  const columns = (sheet && sheet.columns) || [];
  const rows = (sheet && sheet.rows) || [];
  const types = columns.map((column) => normalizeType(column.type));
  const read = columns.map((column, index) => cellReader(column, index));
  const toDate = dateConverter(options.timeZone);

  const data = rows.map((row) =>
    columns.map((_column, c) => csvValue(typedValue(read[c](row), types[c], toDate), types[c]))
  );
  const text = Papa.unparse(
    {
      fields: columns.map((column) => String(column.label == null ? "" : column.label)),
      data
    },
    {
      delimiter: options.delimiter || ",",
      newline: "\r\n",
      escapeFormulae: true
    }
  );
  return options.byteOrderMark === false ? text : BYTE_ORDER_MARK + text;
}

/** A typed value as CSV text. Dates are written from their UTC fields - see dateConverter. */
function csvValue(value, type) {
  if (value === null) return "";
  if (value instanceof Date) {
    const date = [
      value.getUTCFullYear(),
      pad(value.getUTCMonth() + 1),
      pad(value.getUTCDate())
    ].join("-");
    if (type === "date") return date;
    const time = [value.getUTCHours(), value.getUTCMinutes(), value.getUTCSeconds()]
      .map(pad)
      .join(":");
    return `${date} ${time}`;
  }
  return value;
}

function pad(n) {
  return String(n).padStart(2, "0");
}
