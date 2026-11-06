import { LightningElement, api } from "lwc";
import TIME_ZONE from "@salesforce/i18n/timeZone";
import { errorMessage, logError, saveFile } from "c/utils";
import { zip } from "c/export";
import { buildWorkbook, mergeStyles } from "c/xlsx";
import { buildCsv } from "c/csv";
import getExport from "@salesforce/apex/DataExport.getExport";
import getSheetData from "@salesforce/apex/DataExport.getSheetData";

/**
 * A button that downloads Salesforce data as Excel workbooks or CSV files, laid out by
 * configuration.
 *
 *   <c-data-export export-name="Account_Overview" record-id={recordId}></c-data-export>
 *
 * export-name is a Data_Export__mdt developer name. Each of its Data_Export_Sheet__mdt records is
 * one table - an object, its columns, an optional filter - and sheets that share a File Name share
 * a file. With a Zip File Name set, several files download as a single zip.
 *
 * The user picks the format from the button's menu; `formats` limits the choice to one. As Excel,
 * each file is a workbook with a worksheet per sheet, styled by Styles__c (c/xlsx, on ExcelJS). As
 * CSV, which has no sheets, every sheet is its own file (c/csv, on PapaParse). Either way the
 * values are the same: c/export reads them for both.
 *
 * The data is read by DataExport, as the running user, and the files are built in the
 * browser, so nothing is left behind in the org.
 *
 * Hosts with their own data skip the configuration: with no export-name, the button downloads
 * `workbooks` instead - columns and rows in the shape lightning-datatable takes.
 *
 *   <c-data-export workbooks={workbooks} label="Export table"></c-data-export>
 *
 *   workbooks = [{ name: "Invoices", style, sheets: [{ name: "Open", columns, rows, style }] }];
 *
 * downloadWorkbooks() does the same from script, for data that only exists once the user asks.
 *
 * Progress and results are shown inline and fired as `exported` / `exporterror` events, not raised
 * as toasts, so the component works inside a modal (see notify() in c/utils).
 */

const SOURCE = "dataExport";

/** Every format, in menu order. */
const FORMATS = {
  excel: { label: "Excel (.xlsx)", name: "Excel", icon: "doctype:excel", extension: ".xlsx" },
  csv: { label: "CSV (.csv)", name: "CSV", icon: "doctype:csv", extension: ".csv" }
};

export default class DataExport extends LightningElement {
  // Data_Export__mdt developer name.
  @api exportName;
  // The record the component is on. Bound as :recordId in each sheet's filter.
  @api recordId;
  // The button's label. Defaults to "Export", or "Export to Excel" / "Export to CSV" for one format.
  @api label;
  // lightning-button variant. A menu of formats is always a neutral button.
  @api variant = "neutral";
  @api disabled = false;
  // Which formats to offer: "both" (a menu), "excel" or "csv" (a single button).
  @api formats = "both";
  // The host's own data, downloaded when there is no export-name. See downloadWorkbooks().
  @api workbooks;
  // With workbooks: bundle several files into one zip with this name.
  @api zipFileName;

  busy = false;
  progress;
  status; // { variant: 'success' | 'warning' | 'error', message }

  /* ── Presentation ─────────────────────────────────────────────────────────────────────────── */

  /** The formats on offer, in menu order. An unrecognised `formats` value offers both. */
  get allowed() {
    const value = String(this.formats || "both").toLowerCase();
    return FORMATS[value] ? [value] : Object.keys(FORMATS);
  }

  get offersChoice() {
    return this.allowed.length > 1;
  }

  get menuItems() {
    return this.allowed.map((value) => ({
      value,
      label: FORMATS[value].label,
      icon: FORMATS[value].icon
    }));
  }

  get buttonLabel() {
    if (this.label) return this.label;
    return this.offersChoice ? "Export" : `Export to ${FORMATS[this.allowed[0]].name}`;
  }

  get buttonDisabled() {
    return this.disabled || this.busy;
  }

  get statusClass() {
    const variant = (this.status && this.status.variant) || "success";
    return [
      "export-status",
      `export-status_${variant}`,
      "slds-var-m-top_x-small"
    ].join(" ");
  }

  /* ── Exporting ────────────────────────────────────────────────────────────────────────────── */

  handleClick() {
    this.download();
  }

  handleSelect(event) {
    this.download(event.detail.value);
  }

  /**
   * Download what the button downloads: the configured export, or `workbooks` when there is no
   * export-name.
   *
   * For a configured export, every sheet is fetched first, and one sheet failing fails the export:
   * a download quietly missing a sheet looks complete and is not.
   *
   * @param {"excel"|"csv"} [format] defaults to the first format on offer
   * @returns {Promise<{format: string, files: number, sheets: number, rows: number,
   *          truncated: string[]}|null>} what was downloaded, or null when it failed (the failure is
   *          shown and fired as `exporterror`, so callers need not catch)
   */
  @api
  async download(format) {
    if (this.busy) return null;
    if (!this.exportName) {
      if (this.workbooks) {
        return this.downloadWorkbooks(this.workbooks, {
          format,
          zipFileName: this.zipFileName
        });
      }
      return this.failed(new Error("No export is configured for this button."));
    }
    this.start("Preparing export…");
    try {
      const chosen = this.formatOf(format);
      const definition = await getExport({ exportName: this.exportName });
      const sheets = definition.sheets || [];
      const truncated = [];
      const filled = [];

      for (let i = 0; i < sheets.length; i++) {
        const sheet = sheets[i];
        this.progress = `Reading ${sheet.label} (${i + 1} of ${sheets.length})…`;
        // Sequential on purpose: each sheet is its own Apex transaction with its own limits, and
        // running them together would only race them for the same user's concurrency allowance.
        // eslint-disable-next-line no-await-in-loop
        const data = await getSheetData({
          sheetName: sheet.developerName,
          recordId: this.recordId || null
        });
        if (data.truncated) {
          truncated.push(
            `${sheet.label} stopped at ${Number(data.rowLimit).toLocaleString()} rows.`
          );
        }
        filled.push({
          file: sheet.fileName,
          name: sheet.label,
          columns: data.columns || [],
          rows: data.rows || [],
          style: parseStyles(sheet.styles, `The "${sheet.label}" sheet`)
        });
      }

      const result = await this.save(groupByFile(filled), {
        format: chosen,
        zipFileName: definition.zipFileName,
        style: parseStyles(definition.styles, `The "${definition.label}" export`)
      });
      result.truncated = truncated;
      return this.finished(result);
    } catch (e) {
      return this.failed(e);
    }
  }

  /**
   * Download workbooks built from data the host already has, with no configuration. As CSV, each
   * sheet becomes its own file.
   *
   * @param {Array<{name: string, style?: object, sheets: Array<{name: string, columns: Array<{
   *          label: string, fieldName?: string, type?: string, style?: object}>,
   *          rows: Array<object|Array>, style?: object, customize?: Function}>}>} workbooks
   *          columns and rows in the shape lightning-datatable takes; see c/export for
   *          column types and c/xlsx for styles and the customize hook
   * @param {object} [options]
   * @param {"excel"|"csv"} [options.format] defaults to the first format on offer
   * @param {string} [options.zipFileName] bundle several files into one zip with this name
   * @param {object} [options.style] Excel style for every sheet of every workbook
   * @returns {Promise<object|null>} as download()
   */
  @api
  async downloadWorkbooks(workbooks, options = {}) {
    if (this.busy) return null;
    this.start("Building export…");
    try {
      const books = (workbooks || []).map((book) => ({
        name: book.name,
        style: book.style,
        sheets: book.sheets || []
      }));
      return this.finished(
        await this.save(books, { ...options, format: this.formatOf(options.format) })
      );
    } catch (e) {
      return this.failed(e);
    }
  }

  /** The format asked for, checked against what this button offers. */
  formatOf(format) {
    const value = format ? String(format).toLowerCase() : this.allowed[0];
    if (!this.allowed.includes(value)) {
      const offered = this.allowed.map((key) => FORMATS[key].name).join(" or ");
      throw new Error(`This export is available as ${offered}, not "${format}".`);
    }
    return value;
  }

  /** Build every file in the chosen format and hand them to the browser. */
  async save(books, { format, zipFileName, style } = {}) {
    if (!books.length) {
      throw new Error("There is nothing to export.");
    }
    const files =
      format === "csv" ? await this.csvFiles(books) : await this.excelFiles(books, style);

    const zipped = files.length > 1 && Boolean(zipFileName);
    if (zipped) {
      this.progress = "Zipping files…";
      const archive = await zip(this, uniqueNames(files));
      this.saveData(archive, fileName(zipFileName, ".zip"));
    } else {
      // Separate files: the browser may ask once whether this page can download several.
      uniqueNames(files).forEach((file) => this.saveData(file.data, file.name));
    }

    return {
      format,
      files: files.length,
      zipped,
      sheets: books.reduce((sum, book) => sum + book.sheets.length, 0),
      rows: books.reduce(
        (sum, book) =>
          sum + book.sheets.reduce((n, sheet) => n + (sheet.rows || []).length, 0),
        0
      ),
      truncated: []
    };
  }

  async excelFiles(books, style) {
    const files = [];
    for (const book of books) {
      const name = fileName(book.name, FORMATS.excel.extension);
      this.progress = `Building ${name}…`;
      // eslint-disable-next-line no-await-in-loop
      const data = await buildWorkbook(this, book.sheets, {
        timeZone: TIME_ZONE,
        style: mergeStyles(style, book.style)
      });
      files.push({ name, data });
    }
    return files;
  }

  /** One CSV per sheet: "<file>.csv" when the file has one sheet, "<file> - <sheet>.csv" if more. */
  async csvFiles(books) {
    const files = [];
    for (const book of books) {
      for (const sheet of book.sheets) {
        const base = book.sheets.length > 1 ? `${book.name} - ${sheet.name}` : book.name;
        const name = fileName(base, FORMATS.csv.extension);
        this.progress = `Building ${name}…`;
        // eslint-disable-next-line no-await-in-loop
        const data = await buildCsv(this, sheet, { timeZone: TIME_ZONE });
        files.push({ name, data });
      }
    }
    return files;
  }

  /**
   * Hand a file to the browser to save.
   *
   * Lightning Web Security only creates object URLs for an allow-list of MIME types (see saveFile
   * in c/utils). The blob's type does not change its bytes or the saved file - the download name
   * does - so a refused type is retried as text/plain, the type c/utils has proven allowed.
   */
  saveData(data, name) {
    const anchor = this.refs && this.refs.anchor;
    try {
      saveFile(new Blob([data], { type: "application/octet-stream" }), name, {
        anchor,
        source: SOURCE
      });
    } catch (refused) {
      logError(`${SOURCE}.saveData`, refused);
      saveFile(new Blob([data], { type: "text/plain" }), name, {
        anchor,
        source: SOURCE
      });
    }
  }

  /* ── Status ───────────────────────────────────────────────────────────────────────────────── */

  start(progress) {
    this.busy = true;
    this.status = undefined;
    this.progress = progress;
  }

  finished(result) {
    this.busy = false;
    this.progress = undefined;
    const summary = describe(result);
    this.status = result.truncated.length
      ? { variant: "warning", message: `${summary} ${result.truncated.join(" ")}` }
      : { variant: "success", message: summary };
    this.dispatchEvent(new CustomEvent("exported", { detail: result }));
    return result;
  }

  failed(error) {
    logError(SOURCE, error);
    this.busy = false;
    this.progress = undefined;
    const message = errorMessage(error, "The export could not be created.");
    this.status = { variant: "error", message };
    this.dispatchEvent(new CustomEvent("exporterror", { detail: { message } }));
    return null;
  }
}

/* ── Helpers ──────────────────────────────────────────────────────────────────────────────────── */

/**
 * Styles JSON from configuration as an object. DataExport has already checked it
 * parses; this guards against a payload that did not come through it.
 */
function parseStyles(json, owner) {
  if (!json) return undefined;
  try {
    return JSON.parse(json);
  } catch {
    throw new Error(`${owner} has Styles that are not valid JSON.`);
  }
}

/** Sheets grouped into files by File Name, each file placed where its first sheet was. */
function groupByFile(sheets) {
  const books = new Map();
  for (const sheet of sheets) {
    const name = sheet.file || "Export";
    const key = String(name).trim().toLowerCase();
    if (!books.has(key)) {
      books.set(key, { name, sheets: [] });
    }
    books.get(key).sheets.push(sheet);
  }
  return [...books.values()];
}

/**
 * A safe file name: {date} becomes today's date, characters Windows and macOS refuse become
 * hyphens, and the extension is added when it is missing.
 */
function fileName(name, extension) {
  const today = new Date();
  const date = [
    today.getFullYear(),
    String(today.getMonth() + 1).padStart(2, "0"),
    String(today.getDate()).padStart(2, "0")
  ].join("-");
  let base = String(name || "Export")
    .replace(/\{date\}/gi, date)
    // eslint-disable-next-line no-control-regex -- control characters are what is being removed
    .replace(/[\\/:*?"<>|\u0000-\u001f]/g, "-")
    .trim();
  if (!base) base = "Export";
  return base.toLowerCase().endsWith(extension) ? base : base + extension;
}

/** File names made unique, since a zip or a downloads folder cannot hold two of the same name. */
function uniqueNames(files) {
  const used = new Set();
  return files.map((file) => {
    let name = file.name;
    const dot = name.lastIndexOf(".");
    for (let n = 2; used.has(name.toLowerCase()); n++) {
      name = `${file.name.substring(0, dot)} (${n})${file.name.substring(dot)}`;
    }
    used.add(name.toLowerCase());
    return { name, data: file.data };
  });
}

function describe({ format, files, zipped, sheets, rows }) {
  const plural = (n, word) => `${n.toLocaleString()} ${word}${n === 1 ? "" : "s"}`;
  const what = `${files.toLocaleString()} ${FORMATS[format].name} file${files === 1 ? "" : "s"}`;
  return `Downloaded ${what}${zipped ? " in one zip" : ""} (${plural(sheets, "sheet")}, ${plural(rows, "row")}).`;
}
