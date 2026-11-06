import EXCELJS_URL from "@salesforce/resourceUrl/exceljs";
import {
  cellReader,
  dateConverter,
  loadLibrary,
  normalizeType,
  typedValue,
  NUMERIC_TYPES
} from "c/export";

/**
 * Builds styled Excel workbooks (.xlsx) in the browser with ExcelJS, a static resource copied from
 * npm by scripts/vendor-libraries.js. Rows, column types and dates are read by c/export,
 * so an Excel export holds the same values as a CSV one.
 *
 *   import { buildWorkbook } from "c/xlsx";
 *
 *   const bytes = await buildWorkbook(this, [
 *     {
 *       name: "Accounts",
 *       columns: [
 *         { label: "Name", fieldName: "name" },
 *         { label: "Revenue", fieldName: "revenue", type: "currency" }
 *       ],
 *       rows: [{ name: "Acme", revenue: 1200000 }],
 *       style: { header: { fill: { type: "pattern", pattern: "solid", fgColor: { argb: "FF032D60" } } } }
 *     }
 *   ]);
 *
 * buildWorkbook takes the calling component first: loading ExcelJS with loadScript needs one.
 *
 * Rows and column types are as c/export describes. A percent is a fraction (0.125 shows as
 * 12.50%), and date-times are shown in `options.timeZone`.
 *
 * ── Styles ──
 *
 * A sheet's look comes from a style object, merged in order from DEFAULT_STYLE, `options.style`
 * (every sheet in the workbook), and the sheet's own `style`. Later wins, key by key. Cell styles -
 * `header`, `body`, `alternateRows` and each entry of `columns` - are ExcelJS style objects
 * ({ font, fill, border, alignment, numFmt, protection }), so ExcelJS's documentation describes
 * every option: https://github.com/exceljs/exceljs#styles
 *
 *   header          style of the header row
 *   headerHeight    header row height in points
 *   body            style of every data cell
 *   alternateRows   merged over body on every second data row; null for no banding
 *   columns         { [fieldName | label]: style + { width, header, conditionalFormatting } }
 *                     header: style merged over `header` for that column's header cell
 *                     conditionalFormatting: ExcelJS rules, applied to the column's data cells
 *   conditionalFormatting  ExcelJS { ref, rules } entries for the sheet, as written
 *   freezeHeader    keep the header row in view while scrolling (default true)
 *   autoFilter      a filter button on every header (default true)
 *   showGridLines   (default true)
 *   tabColor        ARGB hex for the sheet's tab, e.g. "FF0B5CAB"
 *
 * Anything else ExcelJS can do is reachable from code: a sheet's `customize(worksheet, context)`
 * runs after the sheet is filled, and `options.customize(workbook, ExcelJS)` after every sheet.
 */

export { COLUMN_TYPES } from "c/export";

// Excel's own built-in formats, so dates follow the reader's regional settings. ExcelJS writes a
// format string as a built-in's id only when it matches ExcelJS's table exactly - hence the odd
// quoting in the date-time one (built-in 22).
const TYPE_FORMATS = {
  integer: "#,##0",
  currency: "#,##0.00",
  percent: "0.00%",
  date: "mm-dd-yy",
  datetime: 'm/d/yy "h":mm'
};

const solid = (argb) => ({ type: "pattern", pattern: "solid", fgColor: { argb } });
const thin = (argb) => ({ style: "thin", color: { argb } });

/** The look every sheet starts from. */
export const DEFAULT_STYLE = Object.freeze({
  header: {
    font: { bold: true, color: { argb: "FFFFFFFF" } },
    fill: solid("FF0B5CAB"),
    alignment: { vertical: "middle" },
    border: { bottom: thin("FF032D60") }
  },
  headerHeight: 20,
  body: {
    alignment: { vertical: "top" },
    border: { bottom: thin("FFE5E5E5") }
  },
  alternateRows: { fill: solid("FFF3F6FA") },
  columns: {},
  conditionalFormatting: [],
  freezeHeader: true,
  autoFilter: true,
  showGridLines: true,
  tabColor: null
});

// Excel refuses a longer cell on open, and a longer sheet name is a repair prompt.
const MAX_CELL_LENGTH = 32767;
const MAX_SHEET_NAME_LENGTH = 31;

// Column widths are in characters. Only the first rows are sampled: the width only has to look
// right, and measuring every cell of a large sheet costs more than it is worth.
const WIDTH_SAMPLE_ROWS = 200;
const MIN_WIDTH = 8;
const MAX_WIDTH = 60;

/* ── Workbook ─────────────────────────────────────────────────────────────────────────────────── */

/**
 * One .xlsx file holding the given sheets, in order.
 *
 * @param {LightningElement} cmp the calling component, for loadScript
 * @param {Array<{name: string, columns: Array<{label: string, type?: string, fieldName?: string,
 *          width?: number, style?: object}>, rows: Array<Array|object>, style?: object,
 *          customize?: Function}>} sheets at least one
 * @param {object} [options]
 * @param {string} [options.timeZone] IANA zone date-times are shown in. Defaults to the browser's.
 * @param {object} [options.style] style for every sheet, merged over DEFAULT_STYLE
 * @param {Function} [options.customize] (workbook, ExcelJS) => void, run after every sheet is built
 * @returns {Promise<Uint8Array>} the file's bytes
 * @throws {Error} when there are no sheets or a library will not load
 */
export async function buildWorkbook(cmp, sheets, options = {}) {
  if (!Array.isArray(sheets) || sheets.length === 0) {
    throw new Error("A workbook needs at least one sheet.");
  }
  const ExcelJS = await loadLibrary(cmp, EXCELJS_URL, "ExcelJS");
  const workbook = new ExcelJS.Workbook();
  workbook.created = new Date();

  const names = sheetNames(sheets.map((sheet) => sheet && sheet.name));
  const toDate = dateConverter(options.timeZone);

  sheets.forEach((sheet, index) => {
    const style = mergeStyles(DEFAULT_STYLE, options.style, sheet && sheet.style);
    const worksheet = workbook.addWorksheet(names[index], {
      properties: style.tabColor ? { tabColor: { argb: style.tabColor } } : {},
      views: [
        style.freezeHeader
          ? { state: "frozen", ySplit: 1, showGridLines: style.showGridLines }
          : { showGridLines: style.showGridLines }
      ]
    });
    fillWorksheet(worksheet, sheet || {}, style, toDate);
    if (sheet && typeof sheet.customize === "function") {
      sheet.customize(worksheet, { workbook, ExcelJS, style });
    }
  });

  if (typeof options.customize === "function") {
    options.customize(workbook, ExcelJS);
  }
  const buffer = await workbook.xlsx.writeBuffer();
  return new Uint8Array(buffer);
}

function fillWorksheet(worksheet, sheet, style, toDate) {
  const columns = sheet.columns || [];
  const rows = sheet.rows || [];
  if (!columns.length) return;

  const types = columns.map((column) => normalizeType(column.type));
  const read = columns.map((column, index) => cellReader(column, index));
  const columnStyles = columns.map((column) => columnStyleOf(column, style));

  // Two styles per column, worked out once: ExcelJS shares a style object between the cells it is
  // given to, so 100,000 cells cost two objects a column rather than 100,000.
  const cellStyles = columns.map((_column, c) => {
    // eslint-disable-next-line no-unused-vars -- pulled out so they do not reach the cell style
    const { width, header, conditionalFormatting, ...own } = columnStyles[c];
    const typed = TYPE_FORMATS[types[c]] ? { numFmt: TYPE_FORMATS[types[c]] } : {};
    const plain = mergeStyles(style.body, typed, own);
    return {
      plain,
      banded: style.alternateRows ? mergeStyles(plain, style.alternateRows, own) : plain
    };
  });

  worksheet.columns = columns.map((column, c) => ({
    key: `c${c}`,
    width:
      positive(columnStyles[c].width) ||
      positive(column.width) ||
      estimateWidth(column, types[c], rows, read[c])
  }));

  const headerRow = worksheet.getRow(1);
  columns.forEach((column, c) => {
    const cell = headerRow.getCell(c + 1);
    cell.value = excelValue(String(column.label == null ? "" : column.label));
    cell.style = mergeStyles(style.header, columnStyles[c].header);
  });
  if (style.headerHeight) headerRow.height = style.headerHeight;

  rows.forEach((row, r) => {
    const sheetRow = worksheet.getRow(r + 2);
    const band = r % 2 === 1 ? "banded" : "plain";
    for (let c = 0; c < columns.length; c++) {
      const cell = sheetRow.getCell(c + 1);
      const value = excelValue(typedValue(read[c](row), types[c], toDate));
      if (value !== null) cell.value = value;
      // Styled even when empty, so banding and borders run unbroken across the row.
      cell.style = cellStyles[c][band];
    }
  });

  const lastColumn = columnLetters(columns.length - 1);
  if (style.autoFilter) {
    worksheet.autoFilter = `A1:${lastColumn}1`;
  }
  if (rows.length) {
    columns.forEach((_column, c) => {
      const rules = columnStyles[c].conditionalFormatting;
      if (Array.isArray(rules) && rules.length) {
        const letter = columnLetters(c);
        worksheet.addConditionalFormatting({
          ref: `${letter}2:${letter}${rows.length + 1}`,
          rules: copyOf(rules)
        });
      }
    });
  }
  for (const entry of style.conditionalFormatting || []) {
    if (entry && entry.ref && Array.isArray(entry.rules)) {
      worksheet.addConditionalFormatting({ ref: entry.ref, rules: copyOf(entry.rules) });
    }
  }
}

/**
 * A deep copy of plain data. ExcelJS writes to the rules it is given (their priority), and rules
 * from a host's @api property are read-only proxies that throw on any write.
 */
function copyOf(value) {
  return JSON.parse(JSON.stringify(value));
}

/**
 * The style given for one column: from the sheet style's `columns`, looked up by fieldName (or
 * the fieldPath Apex sends) and then by label, with the column's own `style` over it.
 */
function columnStyleOf(column, style) {
  const byName = style.columns || {};
  const key = column.fieldName || column.fieldPath;
  return mergeStyles(
    (key && byName[key]) || {},
    (column.label && byName[column.label]) || {},
    column.style || {}
  );
}

/**
 * Style objects merged left to right: a later value wins, plain objects merge key by key, and
 * arrays and everything else are replaced whole. Null and undefined arguments are skipped.
 *
 * A value set to null removes it - so `{ alternateRows: null }` turns banding off.
 *
 * @returns {object} a new object; the arguments are not changed
 */
export function mergeStyles(...styles) {
  const out = {};
  for (const style of styles) {
    if (!isPlainObject(style)) continue;
    for (const [key, value] of Object.entries(style)) {
      if (value === null) {
        out[key] = null;
      } else if (isPlainObject(value) && isPlainObject(out[key])) {
        out[key] = mergeStyles(out[key], value);
      } else if (isPlainObject(value)) {
        out[key] = mergeStyles(value);
      } else if (Array.isArray(value)) {
        out[key] = value.slice();
      } else if (value !== undefined) {
        out[key] = value;
      }
    }
  }
  return out;
}

function isPlainObject(value) {
  return (
    value !== null &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    !(value instanceof Date)
  );
}

/**
 * Valid, unique Excel sheet names for the names given, in the same order.
 *
 * Excel refuses a name longer than 31 characters, one containing : \ / ? * [ or ], one that
 * starts or ends with an apostrophe, the reserved name "History", and two names that differ only
 * in case. Each offending character becomes a hyphen, a blank name becomes "Sheet<n>", and a
 * repeat gets " (2)", " (3)" and so on, shortening the name to make room. ExcelJS throws on most of
 * these instead, which would fail an export over a label.
 *
 * @param {string[]} requested the names asked for
 * @returns {string[]} names Excel will accept
 */
export function sheetNames(requested) {
  const used = new Set();
  return requested.map((raw, index) => {
    let base = String(raw == null ? "" : raw)
      .replace(/[:\\/?*[\]]/g, "-")
      // eslint-disable-next-line no-control-regex -- control characters are what is being removed
      .replace(/[\u0000-\u001f]/g, " ")
      .trim()
      .replace(/^'+|'+$/g, "")
      .trim();
    if (!base) base = `Sheet${index + 1}`;
    if (base.toLowerCase() === "history") base = "History-";
    base = base.substring(0, MAX_SHEET_NAME_LENGTH).trim();

    let name = base;
    for (let n = 2; used.has(name.toLowerCase()); n++) {
      const suffix = ` (${n})`;
      name = base.substring(0, MAX_SHEET_NAME_LENGTH - suffix.length).trim() + suffix;
    }
    used.add(name.toLowerCase());
    return name;
  });
}

/* ── Cells ────────────────────────────────────────────────────────────────────────────────────── */

/**
 * A typed value as ExcelJS should write it. Text loses the two characters ExcelJS lets through
 * that XML cannot carry - U+FFFE and U+FFFF, which make Excel call the file corrupt - and is cut
 * at Excel's cell limit. ExcelJS removes control characters itself.
 */
function excelValue(value) {
  if (typeof value !== "string") return value;
  const text = value.replace(/[\ufffe\uffff]/g, "");
  return text.length > MAX_CELL_LENGTH ? text.substring(0, MAX_CELL_LENGTH) : text;
}

function positive(value) {
  return Number.isFinite(value) && value > 0 ? Math.min(value, 255) : 0;
}

/** A width that fits the column's header and the values in its first rows, in characters. */
function estimateWidth(column, type, rows, read) {
  // A little extra for the header's filter button.
  let longest = String(column.label == null ? "" : column.label).length + 2;
  if (type === "date") {
    longest = Math.max(longest, 10);
  } else if (type === "datetime") {
    longest = Math.max(longest, 16);
  } else {
    const sample = Math.min(rows.length, WIDTH_SAMPLE_ROWS);
    for (let i = 0; i < sample; i++) {
      const value = read(rows[i]);
      if (value === null || value === undefined) continue;
      longest = Math.max(longest, shownLength(value, type));
    }
  }
  return Math.min(Math.max(longest + 2, MIN_WIDTH), MAX_WIDTH);
}

/** Roughly how wide a value shows once Excel adds its grouping separators and decimals. */
function shownLength(value, type) {
  if (!NUMERIC_TYPES.has(type) || type === "number") {
    return String(value).split("\n")[0].length;
  }
  const number = Number(value);
  if (!Number.isFinite(number)) return String(value).length;
  const fixed = type === "currency" || type === "percent";
  const shown = (type === "percent" ? number * 100 : number).toLocaleString("en-US", {
    minimumFractionDigits: fixed ? 2 : 0,
    maximumFractionDigits: fixed ? 2 : 0
  });
  return shown.length + (type === "percent" ? 1 : 0);
}

/** "A" for 0, "Z" for 25, "AA" for 26. */
function columnLetters(index) {
  let letters = "";
  let n = index + 1;
  while (n > 0) {
    const remainder = (n - 1) % 26;
    letters = String.fromCharCode(65 + remainder) + letters;
    n = Math.floor((n - 1) / 26);
  }
  return letters;
}
