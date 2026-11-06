import { createElement } from "@lwc/engine-dom";
import DataExport from "c/dataExport";
import { saveFile } from "c/utils";
import { zip } from "c/export";
import { buildWorkbook } from "c/xlsx";
import { buildCsv } from "c/csv";
import getExport from "@salesforce/apex/DataExport.getExport";
import getSheetData from "@salesforce/apex/DataExport.getSheetData";

jest.mock("c/utils", () => ({
  ...jest.requireActual("c/utils"),
  saveFile: jest.fn(),
  logError: jest.fn()
}));
// The format modules have their own suites against the real libraries; here they only have to
// hand back a file.
jest.mock("c/export", () => ({
  ...jest.requireActual("c/export"),
  zip: jest.fn()
}));
jest.mock("c/xlsx", () => ({
  ...jest.requireActual("c/xlsx"),
  buildWorkbook: jest.fn()
}));
jest.mock("c/csv", () => ({ buildCsv: jest.fn() }));
jest.mock(
  "@salesforce/apex/DataExport.getExport",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DataExport.getSheetData",
  () => ({ default: jest.fn() }),
  { virtual: true }
);

const RECORD_ID = "001000000000001AAA";
const DATED = (name, extension) =>
  new RegExp(`^${name} \\d{4}-\\d{2}-\\d{2}\\.${extension}$`);

const DEFINITION = {
  label: "Overview",
  zipFileName: null,
  sheets: [
    { developerName: "Accounts", label: "Accounts", fileName: "Accounts {date}" },
    { developerName: "Contacts", label: "Contacts", fileName: "Accounts {date}" },
    { developerName: "Opps", label: "Open Opportunities", fileName: "Opportunities" }
  ]
};

const sheetData = (rows, extra = {}) => ({
  columns: [
    { label: "Name", type: "text", fieldPath: "Name" },
    { label: "Amount", type: "currency", fieldPath: "Amount" }
  ],
  rows,
  truncated: false,
  rowLimit: 10000,
  ...extra
});

/** An Apex failure as it reaches the component. */
const apexError = (message) => ({ body: { message } });

// A macrotask, not Promise.resolve(): a click runs a chain of awaits (Apex, then building each
// file) that one microtask does not see the end of.
// eslint-disable-next-line @lwc/lwc/no-async-operation
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

function render(props = {}) {
  const element = createElement("c-data-export", { is: DataExport });
  Object.assign(element, { exportName: "Overview", recordId: RECORD_ID, ...props });
  document.body.appendChild(element);
  return element;
}

const status = (element) => element.shadowRoot.querySelector(".export-status");
const savedNames = () => saveFile.mock.calls.map((call) => call[1]);
const menu = (element) => element.shadowRoot.querySelector("lightning-button-menu");
const button = (element) => element.shadowRoot.querySelector("lightning-button");

describe("c-data-export", () => {
  beforeEach(() => {
    buildWorkbook.mockResolvedValue(new Uint8Array([80, 75, 3, 4]));
    buildCsv.mockImplementation((_cmp, sheet) => Promise.resolve(`csv of ${sheet.name}`));
    zip.mockResolvedValue(new Uint8Array([80, 75, 5, 6]));
    getExport.mockResolvedValue(DEFINITION);
    getSheetData.mockImplementation(({ sheetName }) =>
      Promise.resolve(
        sheetData(sheetName === "Opps" ? [["Deal", 5000]] : [["Acme", 1], ["Globex", 2]])
      )
    );
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  describe("the button", () => {
    it("is a menu of both formats by default", () => {
      const element = render();
      const items = [...element.shadowRoot.querySelectorAll("lightning-menu-item")];

      expect(menu(element).label).toBe("Export");
      expect(button(element)).toBeNull();
      expect(items.map((item) => [item.value, item.label])).toEqual([
        ["excel", "Excel (.xlsx)"],
        ["csv", "CSV (.csv)"]
      ]);
    });

    it("is a single button when one format is offered", () => {
      const element = render({ formats: "csv", variant: "brand" });

      expect(menu(element)).toBeNull();
      expect(button(element).label).toBe("Export to CSV");
      expect(button(element).variant).toBe("brand");
    });

    it("uses the label given", () => {
      expect(menu(render({ label: "Download" })).label).toBe("Download");
      expect(button(render({ label: "Get it", formats: "excel" })).label).toBe("Get it");
    });

    it("offers both formats for a formats value it does not know", () => {
      expect(menu(render({ formats: "pdf" }))).not.toBeNull();
    });

    it("exports in the format picked from the menu", async () => {
      const element = render();
      menu(element).dispatchEvent(new CustomEvent("select", { detail: { value: "csv" } }));
      await flush();

      expect(getExport).toHaveBeenCalledWith({ exportName: "Overview" });
      expect(buildCsv).toHaveBeenCalled();
      expect(buildWorkbook).not.toHaveBeenCalled();
    });

    it("exports its one format when clicked", async () => {
      const element = render({ formats: "excel" });
      button(element).click();
      await flush();

      expect(buildWorkbook).toHaveBeenCalled();
      expect(buildCsv).not.toHaveBeenCalled();
    });

    it("is disabled, and shows progress, while it works", async () => {
      let release;
      getExport.mockReturnValue(
        new Promise((resolve) => {
          release = () => resolve(DEFINITION);
        })
      );
      const element = render();
      const running = element.download();
      await flush();

      expect(menu(element).disabled).toBe(true);
      expect(element.shadowRoot.querySelector(".export-progress").textContent).toBe(
        "Preparing export…"
      );
      expect(await element.download()).toBeNull(); // a second click while busy does nothing

      release();
      await running;
      await flush();
      expect(menu(element).disabled).toBe(false);
      expect(element.shadowRoot.querySelector(".export-progress")).toBeNull();
      expect(getExport).toHaveBeenCalledTimes(1);
    });
  });

  describe("a configured export", () => {
    it("reads every sheet for the current record", async () => {
      await render().download();

      expect(getSheetData.mock.calls.map((call) => call[0])).toEqual([
        { sheetName: "Accounts", recordId: RECORD_ID },
        { sheetName: "Contacts", recordId: RECORD_ID },
        { sheetName: "Opps", recordId: RECORD_ID }
      ]);
    });

    it("sends a blank record id as null", async () => {
      await render({ recordId: undefined }).download();
      expect(getSheetData.mock.calls[0][0].recordId).toBeNull();
    });

    it("defaults to Excel: one workbook per File Name, in order, with {date} filled in", async () => {
      const element = render();
      const result = await element.download();

      expect(buildWorkbook).toHaveBeenCalledTimes(2);
      const [cmp, sheets, options] = buildWorkbook.mock.calls[0];
      // The component itself, which loadScript needs - not the host element.
      expect(cmp).not.toBe(element);
      expect(cmp.template).toBeTruthy();
      expect(sheets.map((sheet) => sheet.name)).toEqual(["Accounts", "Contacts"]);
      expect(sheets[0].rows).toEqual([["Acme", 1], ["Globex", 2]]);
      expect(typeof options.timeZone).toBe("string");

      expect(savedNames()).toEqual([
        expect.stringMatching(DATED("Accounts", "xlsx")),
        "Opportunities.xlsx"
      ]);
      expect(result).toEqual({
        format: "excel",
        files: 2,
        zipped: false,
        sheets: 3,
        rows: 5,
        truncated: []
      });
      expect(status(element).textContent).toBe(
        "Downloaded 2 Excel files (3 sheets, 5 rows)."
      );
    });

    it("as CSV, writes every sheet as its own file", async () => {
      const element = render();
      const result = await element.download("csv");

      expect(buildCsv).toHaveBeenCalledTimes(3);
      expect(buildCsv.mock.calls[0][1].columns[1]).toEqual(
        expect.objectContaining({ type: "currency" })
      );
      // A file holding several sheets names each CSV after its sheet; a file of one sheet does not.
      expect(savedNames()).toEqual([
        expect.stringMatching(/^Accounts \d{4}-\d{2}-\d{2} - Accounts\.csv$/),
        expect.stringMatching(/^Accounts \d{4}-\d{2}-\d{2} - Contacts\.csv$/),
        "Opportunities.csv"
      ]);
      expect(result).toEqual(expect.objectContaining({ format: "csv", files: 3, sheets: 3 }));
      expect(status(element).textContent).toBe("Downloaded 3 CSV files (3 sheets, 5 rows).");
    });

    it("hands the browser each file through the template's own anchor", async () => {
      const element = render();
      await element.download("csv");

      const [blob, , options] = saveFile.mock.calls[2];
      expect(blob).toBeInstanceOf(Blob);
      expect(blob.type).toBe("application/octet-stream");
      expect(blob.size).toBe("csv of Open Opportunities".length);
      expect(options.anchor).toBe(element.shadowRoot.querySelector(".export-anchor"));
    });

    it("bundles several files into one zip when the export names one", async () => {
      getExport.mockResolvedValue({ ...DEFINITION, zipFileName: "Overview {date}" });
      const element = render();
      const result = await element.download("csv");

      expect(savedNames()).toEqual([expect.stringMatching(DATED("Overview", "zip"))]);
      expect(zip.mock.calls[0][1].map((entry) => entry.name)).toEqual([
        expect.stringMatching(/ - Accounts\.csv$/),
        expect.stringMatching(/ - Contacts\.csv$/),
        "Opportunities.csv"
      ]);
      expect(zip.mock.calls[0][1][2].data).toBe("csv of Open Opportunities");
      expect(result.zipped).toBe(true);
      expect(status(element).textContent).toBe(
        "Downloaded 3 CSV files in one zip (3 sheets, 5 rows)."
      );
    });

    it("does not zip a single file", async () => {
      getExport.mockResolvedValue({
        ...DEFINITION,
        zipFileName: "Overview",
        sheets: DEFINITION.sheets.slice(0, 2)
      });
      await render().download("excel");

      expect(savedNames()).toEqual([expect.stringMatching(DATED("Accounts", "xlsx"))]);
    });

    it("makes a file name safe to save", async () => {
      getExport.mockResolvedValue({
        ...DEFINITION,
        sheets: [{ developerName: "Accounts", label: "Accounts", fileName: 'Q1/Q2: "draft"' }]
      });
      await render().download();

      expect(savedNames()).toEqual(["Q1-Q2- -draft-.xlsx"]);
    });

    it("styles each sheet with the export's styles under its own", async () => {
      getExport.mockResolvedValue({
        ...DEFINITION,
        styles: '{"header": {"font": {"italic": true}}}',
        sheets: [
          { ...DEFINITION.sheets[0], styles: '{"tabColor": "FF0B5CAB"}' },
          DEFINITION.sheets[1]
        ]
      });
      await render().download("excel");

      const [, sheets, options] = buildWorkbook.mock.calls[0];
      expect(options.style).toEqual({ header: { font: { italic: true } } });
      expect(sheets[0].style).toEqual({ tabColor: "FF0B5CAB" });
      expect(sheets[1].style).toBeUndefined();
    });

    it("names the record whose styles will not parse", async () => {
      getExport.mockResolvedValue({
        ...DEFINITION,
        sheets: [{ ...DEFINITION.sheets[0], styles: "{oops" }]
      });
      const element = render();
      await element.download();

      expect(buildWorkbook).not.toHaveBeenCalled();
      expect(status(element).textContent).toBe(
        'The "Accounts" sheet has Styles that are not valid JSON.'
      );
    });

    it("warns, and says where, when a sheet was cut at its row limit", async () => {
      getSheetData.mockImplementation(({ sheetName }) =>
        Promise.resolve(
          sheetData(
            [["Acme", 1]],
            sheetName === "Contacts" ? { truncated: true, rowLimit: 1000 } : {}
          )
        )
      );
      const element = render();
      const handler = jest.fn();
      element.addEventListener("exported", handler);
      await element.download();

      expect(handler.mock.calls[0][0].detail.truncated).toEqual([
        "Contacts stopped at 1,000 rows."
      ]);
      expect(status(element).className).toContain("export-status_warning");
      expect(status(element).textContent).toContain("Contacts stopped at 1,000 rows.");
    });

    it("fires exported with what was downloaded", async () => {
      const element = render();
      const handler = jest.fn();
      element.addEventListener("exported", handler);
      await element.download("csv");

      expect(handler).toHaveBeenCalledTimes(1);
      expect(handler.mock.calls[0][0].detail).toEqual({
        format: "csv",
        files: 3,
        zipped: false,
        sheets: 3,
        rows: 5,
        truncated: []
      });
    });
  });

  describe("failures", () => {
    it("fails the whole export when one sheet fails, naming the problem", async () => {
      getSheetData.mockImplementation(({ sheetName }) => {
        if (sheetName === "Contacts") {
          return Promise.reject(apexError('The "Contacts" sheet could not be read: bad filter'));
        }
        return Promise.resolve(sheetData([]));
      });
      const element = render();
      const handler = jest.fn();
      element.addEventListener("exporterror", handler);

      expect(await element.download()).toBeNull();
      expect(saveFile).not.toHaveBeenCalled();
      expect(handler.mock.calls[0][0].detail.message).toBe(
        'The "Contacts" sheet could not be read: bad filter'
      );
      expect(status(element).className).toContain("export-status_error");
    });

    it("reports an unknown export", async () => {
      getExport.mockRejectedValue(apexError('There is no data export named "Nope".'));
      const element = render({ exportName: "Nope" });
      await element.download();

      expect(status(element).textContent).toBe('There is no data export named "Nope".');
    });

    it("says so when no export is configured, without calling Apex", async () => {
      const element = render({ exportName: undefined });
      await element.download();

      expect(getExport).not.toHaveBeenCalled();
      expect(status(element).textContent).toBe("No export is configured for this button.");
    });

    it("refuses a format the button does not offer", async () => {
      const element = render({ formats: "excel" });
      await element.download("csv");

      expect(getExport).not.toHaveBeenCalled();
      expect(status(element).textContent).toBe('This export is available as Excel, not "csv".');
    });

    it("reports a file that cannot be built", async () => {
      buildCsv.mockRejectedValue(new Error("The Papa library could not be loaded."));
      const element = render();
      await element.download("csv");

      expect(saveFile).not.toHaveBeenCalled();
      expect(status(element).textContent).toBe("The Papa library could not be loaded.");
    });

    it("retries as text/plain when the browser refuses the blob's type", async () => {
      saveFile.mockImplementationOnce(() => {
        throw new Error("Unsupported MIME type");
      });
      await render().download();

      expect(saveFile.mock.calls[0][0].type).toBe("application/octet-stream");
      expect(saveFile.mock.calls[1][0].type).toBe("text/plain");
      expect(saveFile.mock.calls[1][1]).toBe(saveFile.mock.calls[0][1]);
    });
  });

  describe("the host's own data", () => {
    const columns = [
      { label: "Name", fieldName: "name" },
      { label: "Size", fieldName: "size", type: "number" }
    ];

    it("downloads it without touching configuration", async () => {
      const element = render({ exportName: undefined });
      const result = await element.downloadWorkbooks([
        { name: "Selection", sheets: [{ name: "Rows", columns, rows: [{ name: "a", size: 1 }] }] }
      ]);

      expect(getExport).not.toHaveBeenCalled();
      expect(savedNames()).toEqual(["Selection.xlsx"]);
      expect(result).toEqual(
        expect.objectContaining({ format: "excel", files: 1, sheets: 1, rows: 1 })
      );
    });

    it("downloads it as CSV when asked", async () => {
      const element = render({ exportName: undefined });
      await element.downloadWorkbooks(
        [{ name: "Selection", sheets: [{ name: "Rows", columns, rows: [] }] }],
        { format: "csv" }
      );

      expect(savedNames()).toEqual(["Selection.csv"]);
    });

    it("is what the button downloads when there is no export name", async () => {
      const element = render({
        exportName: undefined,
        workbooks: [
          { name: "One", sheets: [{ name: "Rows", columns, rows: [] }] },
          { name: "Two", sheets: [{ name: "Rows", columns, rows: [] }] }
        ],
        zipFileName: "Both"
      });
      menu(element).dispatchEvent(new CustomEvent("select", { detail: { value: "csv" } }));
      await flush();

      expect(getExport).not.toHaveBeenCalled();
      expect(zip.mock.calls[0][1].map((entry) => entry.name)).toEqual(["One.csv", "Two.csv"]);
      expect(savedNames()).toEqual(["Both.zip"]);
    });

    it("gives way to a configured export when both are set", async () => {
      const element = render({
        workbooks: [{ name: "Ignored", sheets: [{ name: "Rows", columns, rows: [] }] }]
      });
      await element.download();

      expect(getExport).toHaveBeenCalled();
      expect(savedNames()).not.toContain("Ignored.xlsx");
    });

    it("keeps file names apart, zipped or not", async () => {
      const element = render();
      const sheets = [{ name: "Rows", columns, rows: [] }];
      await element.downloadWorkbooks(
        [
          { name: "Report", sheets },
          { name: "Report", sheets }
        ],
        { zipFileName: "Reports" }
      );
      expect(zip.mock.calls[0][1].map((entry) => entry.name)).toEqual([
        "Report.xlsx",
        "Report (2).xlsx"
      ]);

      saveFile.mockClear();
      await element.downloadWorkbooks([
        { name: "Report", sheets },
        { name: "Report", sheets }
      ]);
      expect(savedNames()).toEqual(["Report.xlsx", "Report (2).xlsx"]);
    });

    it("layers the call's style, then each workbook's, under each sheet's", async () => {
      const element = render();
      const sheet = { name: "Rows", columns, rows: [], style: { tabColor: "FF2E844A" } };
      await element.downloadWorkbooks(
        [{ name: "Styled", style: { header: { font: { italic: true } } }, sheets: [sheet] }],
        { style: { header: { font: { size: 14 } }, alternateRows: null } }
      );

      const [, sheets, options] = buildWorkbook.mock.calls[0];
      expect(options.style).toEqual({
        header: { font: { size: 14, italic: true } },
        alternateRows: null
      });
      expect(sheets[0].style).toEqual({ tabColor: "FF2E844A" });
    });

    it("reports an empty request as an error", async () => {
      const element = render();
      expect(await element.downloadWorkbooks([])).toBeNull();
      expect(status(element).textContent).toBe("There is nothing to export.");
    });
  });
});
