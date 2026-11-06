// These run the static resource itself - the browser build of ExcelJS that deploys to the org - and
// read every workbook back to check what was written. JSZip is only used to look inside a file.
import { loadScript } from "lightning/platformResourceLoader";
import { buildWorkbook, mergeStyles, sheetNames, COLUMN_TYPES, DEFAULT_STYLE } from "c/xlsx";

const RESOURCES = "../../../staticresources";
const ExcelJS = require(`${RESOURCES}/exceljs.js`);
const JSZip = require(`${RESOURCES}/jszip.js`);

jest.mock("lightning/platformResourceLoader", () => ({ loadScript: jest.fn() }));

const CMP = {};

/** What loadScript does in the org: define the library's global. */
function provideLibraries() {
  loadScript.mockImplementation((_cmp, url) => {
    if (url.includes("exceljs")) globalThis.ExcelJS = ExcelJS;
    return Promise.resolve();
  });
}

async function readBack(bytes) {
  const workbook = new ExcelJS.Workbook();
  await workbook.xlsx.load(bytes);
  return workbook;
}

async function sheetOf(sheet, options) {
  const workbook = await readBack(await buildWorkbook(CMP, [sheet], options));
  return workbook.worksheets[0];
}

/** The raw XML of one part of a workbook, for what ExcelJS's reader smooths over. */
async function partOf(bytes, name) {
  return (await JSZip.loadAsync(bytes)).file(name).async("string");
}

const fillOf = (cell) => cell.fill && cell.fill.fgColor && cell.fill.fgColor.argb;

/** A fresh copy of c/xlsx, with nothing loaded yet and no library globals defined. */
function freshModule() {
  delete globalThis.ExcelJS;
  let fresh;
  jest.isolateModules(() => {
    fresh = require("c/xlsx");
  });
  return fresh;
}

describe("c/xlsx", () => {
  beforeEach(() => {
    provideLibraries();
  });

  afterEach(() => {
    jest.clearAllMocks();
  });

  describe("libraries", () => {
    afterEach(() => {
      provideLibraries();
      globalThis.ExcelJS = ExcelJS;
    });

    it("loads ExcelJS once and reuses it", async () => {
      const xlsx = freshModule();
      await xlsx.buildWorkbook(CMP, [{ name: "A", columns: [], rows: [] }]);
      await xlsx.buildWorkbook(CMP, [{ name: "B", columns: [], rows: [] }]);

      expect(loadScript).toHaveBeenCalledTimes(1);
      expect(loadScript.mock.calls[0][0]).toBe(CMP);
      expect(loadScript.mock.calls[0][1]).toContain("exceljs");
    });

    it("says so when a library will not load, and tries again next time", async () => {
      const xlsx = freshModule();
      loadScript.mockRejectedValueOnce(new Error("blocked"));
      await expect(
        xlsx.buildWorkbook(CMP, [{ name: "A", columns: [], rows: [] }])
      ).rejects.toThrow("The ExcelJS library could not be loaded.");

      await expect(
        xlsx.buildWorkbook(CMP, [{ name: "A", columns: [], rows: [] }])
      ).resolves.toBeInstanceOf(Uint8Array);
      expect(loadScript).toHaveBeenCalledTimes(2);
    });

    it("says so when the script loads but defines nothing", async () => {
      const xlsx = freshModule();
      loadScript.mockResolvedValue();
      await expect(
        xlsx.buildWorkbook(CMP, [{ name: "A", columns: [], rows: [] }])
      ).rejects.toThrow("could not be loaded");
    });
  });

  describe("buildWorkbook", () => {
    it("writes one worksheet per sheet, in order", async () => {
      const workbook = await readBack(
        await buildWorkbook(CMP, [
          { name: "One", columns: [{ label: "A" }], rows: [] },
          { name: "Two", columns: [{ label: "B" }], rows: [] }
        ])
      );
      expect(workbook.worksheets.map((ws) => ws.name)).toEqual(["One", "Two"]);
    });

    it("refuses a workbook with no sheets", async () => {
      await expect(buildWorkbook(CMP, [])).rejects.toThrow("at least one sheet");
      await expect(buildWorkbook(CMP)).rejects.toThrow("at least one sheet");
    });

    it("reads object rows through each column's fieldName, and array rows by position", async () => {
      const columns = [
        { label: "Name", fieldName: "name" },
        { label: "Size", fieldName: "size", type: "number" }
      ];
      const fromObjects = await sheetOf({ name: "S", columns, rows: [{ size: 4, name: "x" }] });
      const fromArrays = await sheetOf({ name: "S", columns, rows: [["x", 4]] });

      for (const ws of [fromObjects, fromArrays]) {
        expect(ws.getCell("A1").value).toBe("Name");
        expect(ws.getCell("A2").value).toBe("x");
        expect(ws.getCell("B2").value).toBe(4);
      }
    });

    it("writes each column type with its number format", async () => {
      const ws = await sheetOf({
        name: "S",
        columns: [
          { label: "Number", type: "number" },
          { label: "Integer", type: "integer" },
          { label: "Currency", type: "currency" },
          { label: "Percent", type: "percent" },
          { label: "Boolean", type: "boolean" },
          { label: "Text" }
        ],
        rows: [[1.5, 12000, 99.95, 0.125, true, "hi"]]
      });

      expect(ws.getCell("A2").value).toBe(1.5);
      expect(ws.getCell("A2").numFmt).toBeUndefined();
      expect([ws.getCell("B2").value, ws.getCell("B2").numFmt]).toEqual([12000, "#,##0"]);
      expect([ws.getCell("C2").value, ws.getCell("C2").numFmt]).toEqual([99.95, "#,##0.00"]);
      expect([ws.getCell("D2").value, ws.getCell("D2").numFmt]).toEqual([0.125, "0.00%"]);
      expect(ws.getCell("E2").value).toBe(true);
      expect(ws.getCell("F2").value).toBe("hi");
    });

    it("uses Excel's built-in date formats, which follow the reader's regional settings", async () => {
      const bytes = await buildWorkbook(CMP, [
        {
          name: "S",
          columns: [
            { label: "Day", type: "date" },
            { label: "When", type: "datetime" }
          ],
          rows: [["2026-11-06", "2026-07-01T12:00:00Z"]]
        }
      ]);
      const styles = await partOf(bytes, "xl/styles.xml");

      expect(styles).toMatch(/<xf [^>]*numFmtId="14"/);
      expect(styles).toMatch(/<xf [^>]*numFmtId="22"/);
      expect(styles).not.toContain('formatCode="mm-dd-yy"');
    });

    it("writes dates without shifting them, whatever the time zone", async () => {
      const ws = await sheetOf(
        {
          name: "S",
          columns: [{ label: "Day", type: "date" }],
          rows: [["2026-11-06"], [new Date(2024, 1, 29)]]
        },
        { timeZone: "Pacific/Kiritimati" } // UTC+14: a shifted date would land a day late
      );

      expect(ws.getCell("A2").value.toISOString()).toBe("2026-11-06T00:00:00.000Z");
      expect(ws.getCell("A3").value.toISOString()).toBe("2024-02-29T00:00:00.000Z");
    });

    it("shows date-times as wall-clock time in the zone given", async () => {
      const columns = [{ label: "When", type: "datetime" }];
      const rows = [["2026-07-01T12:00:00.000Z"]];
      const utc = await sheetOf({ name: "S", columns, rows }, { timeZone: "UTC" });
      const newYork = await sheetOf(
        { name: "S", columns, rows },
        { timeZone: "America/New_York" }
      );

      expect(utc.getCell("A2").value.toISOString()).toBe("2026-07-01T12:00:00.000Z");
      // Noon UTC is 08:00 in New York in July (EDT, UTC-4).
      expect(newYork.getCell("A2").value.toISOString()).toBe("2026-07-01T08:00:00.000Z");
    });

    it("accepts a Date or epoch milliseconds for a date-time", async () => {
      const ms = Date.UTC(2026, 6, 1, 18, 0, 0);
      const ws = await sheetOf(
        {
          name: "S",
          columns: [{ label: "When", type: "datetime" }],
          rows: [[ms], [new Date(ms)]]
        },
        { timeZone: "UTC" }
      );
      expect(ws.getCell("A2").value.toISOString()).toBe("2026-07-01T18:00:00.000Z");
      expect(ws.getCell("A3").value.toISOString()).toBe("2026-07-01T18:00:00.000Z");
    });

    it("falls back to the browser's zone for a zone it does not know", async () => {
      const ws = await sheetOf(
        {
          name: "S",
          columns: [{ label: "When", type: "datetime" }],
          rows: [["2026-07-01T12:00:00Z"]]
        },
        { timeZone: "Not/AZone" }
      );
      expect(ws.getCell("A2").value).toBeInstanceOf(Date);
    });

    it("keeps a value that does not fit its column's type as text", async () => {
      const ws = await sheetOf({
        name: "S",
        columns: [
          { label: "Number", type: "number" },
          { label: "Date", type: "date" },
          { label: "When", type: "datetime" },
          { label: "Flag", type: "boolean" }
        ],
        rows: [["n/a", "soon", "2026-07-01 12:00", "maybe"]]
      });

      expect(ws.getCell("A2").value).toBe("n/a");
      expect(ws.getCell("B2").value).toBe("soon");
      // No offset, so which instant it means is a guess - better shown as written.
      expect(ws.getCell("C2").value).toBe("2026-07-01 12:00");
      expect(ws.getCell("D2").value).toBe("maybe");
    });

    it("reads text booleans and 1/0", async () => {
      const ws = await sheetOf({
        name: "S",
        columns: [{ label: "Flag", type: "boolean" }],
        rows: [["TRUE"], ["false"], [1], [0]]
      });
      expect([2, 3, 4, 5].map((r) => ws.getCell(`A${r}`).value)).toEqual([
        true,
        false,
        true,
        false
      ]);
    });

    it("leaves empty values empty", async () => {
      const ws = await sheetOf({
        name: "S",
        columns: [{ label: "A" }, { label: "B", type: "number" }, { label: "C" }],
        rows: [[null, undefined, ""]]
      });
      expect(["A2", "B2", "C2"].map((ref) => ws.getCell(ref).value)).toEqual([null, null, null]);
    });

    it("writes nothing XML cannot carry, and keeps markup as text", async () => {
      const ws = await sheetOf({
        name: "S",
        columns: [{ label: '<b>&"' }],
        rows: [["a\u0000b\u0007c\r\nd\ud800e"]]
      });
      expect(ws.getCell("A1").value).toBe('<b>&"');
      // ExcelJS drops the control characters, and an unpaired surrogate - which UTF-8 cannot
      // encode - arrives as the replacement character rather than corrupting the file.
      expect(ws.getCell("A2").value).toBe(`abc\nd${String.fromCharCode(0xfffd)}e`);
    });

    it("cuts text at Excel's cell limit", async () => {
      const ws = await sheetOf({
        name: "S",
        columns: [{ label: "A" }],
        rows: [["x".repeat(40000)]]
      });
      expect(ws.getCell("A2").value).toHaveLength(32767);
    });

    it("sizes columns to their content, within limits, unless a width is given", async () => {
      const ws = await sheetOf({
        name: "S",
        columns: [
          { label: "Id" },
          { label: "Description" },
          { label: "Long" },
          { label: "Fixed", width: 30 },
          { label: "Day", type: "date" }
        ],
        rows: [["1", "twenty characters ok", "y".repeat(500), "", "2026-01-01"]]
      });
      expect(ws.columns.map((column) => column.width)).toEqual([8, 22, 60, 30, 12]);
    });

    it("runs the sheet's and the workbook's customize hooks, in that order", async () => {
      const order = [];
      const bytes = await buildWorkbook(
        CMP,
        [
          {
            name: "S",
            columns: [{ label: "A" }],
            rows: [["x"]],
            customize: (worksheet, context) => {
              order.push("sheet");
              expect(context.ExcelJS).toBe(ExcelJS);
              worksheet.getCell("C1").value = "added";
            }
          }
        ],
        {
          customize: (workbook) => {
            order.push("workbook");
            workbook.creator = "Test";
          }
        }
      );

      const workbook = await readBack(bytes);
      expect(order).toEqual(["sheet", "workbook"]);
      expect(workbook.worksheets[0].getCell("C1").value).toBe("added");
      expect(workbook.creator).toBe("Test");
    });

    it("writes a sheet with no columns as an empty sheet", async () => {
      const ws = await sheetOf({ name: "Empty", columns: [], rows: [[1]] });
      expect(ws.rowCount).toBe(0);
    });

    it("lists every type it formats", () => {
      expect(COLUMN_TYPES).toEqual(
        expect.arrayContaining(["text", "number", "currency", "percent", "date", "datetime"])
      );
    });
  });

  describe("styles", () => {
    const columns = [
      { label: "Name", fieldName: "name" },
      { label: "Amount", fieldName: "amount", type: "currency" }
    ];
    const rows = [
      { name: "a", amount: 1 },
      { name: "b", amount: -2 },
      { name: "c", amount: 3 }
    ];

    it("gives every sheet a styled, frozen, filtered header and banded rows by default", async () => {
      const ws = await sheetOf({ name: "S", columns, rows });

      expect(ws.getCell("A1").font.bold).toBe(true);
      expect(fillOf(ws.getCell("A1"))).toBe(DEFAULT_STYLE.header.fill.fgColor.argb);
      expect(ws.views[0]).toEqual(expect.objectContaining({ state: "frozen", ySplit: 1 }));
      expect(ws.autoFilter).toBe("A1:B1");
      expect(fillOf(ws.getCell("A2"))).toBeUndefined();
      expect(fillOf(ws.getCell("A3"))).toBe(DEFAULT_STYLE.alternateRows.fill.fgColor.argb);
      expect(fillOf(ws.getCell("A4"))).toBeUndefined();
    });

    it("layers workbook style, then sheet style, over the default", async () => {
      const bytes = await buildWorkbook(
        CMP,
        [
          { name: "Plain", columns, rows },
          {
            name: "Own",
            columns,
            rows,
            style: { header: { font: { italic: true } }, tabColor: "FF2E844A" }
          }
        ],
        {
          style: {
            header: {
              fill: { type: "pattern", pattern: "solid", fgColor: { argb: "FF032D60" } }
            }
          }
        }
      );
      const [plain, own] = (await readBack(bytes)).worksheets;

      expect(fillOf(plain.getCell("A1"))).toBe("FF032D60");
      expect(plain.getCell("A1").font.bold).toBe(true); // the default's bold survives the merge
      expect(plain.getCell("A1").font.italic).toBeFalsy();
      expect(fillOf(own.getCell("A1"))).toBe("FF032D60");
      expect(own.getCell("A1").font).toEqual(
        expect.objectContaining({ bold: true, italic: true })
      );
      expect(own.properties.tabColor).toEqual({ argb: "FF2E844A" });
    });

    it("styles a column by fieldName or label, over its type's format", async () => {
      const ws = await sheetOf({
        name: "S",
        columns,
        rows,
        style: {
          columns: {
            amount: { numFmt: '"$"#,##0.00', font: { bold: true }, width: 20 },
            Name: { header: { alignment: { horizontal: "center" } } }
          }
        }
      });

      expect(ws.getCell("B2").numFmt).toBe('"$"#,##0.00');
      expect(ws.getCell("B2").font.bold).toBe(true);
      expect(ws.getCell("B3").font.bold).toBe(true); // banded rows keep the column's style
      expect(ws.getColumn(2).width).toBe(20);
      expect(ws.getCell("A1").alignment.horizontal).toBe("center");
      expect(ws.getCell("B1").alignment.horizontal).toBeUndefined();
    });

    it("styles a column from the column's own style too", async () => {
      const ws = await sheetOf({
        name: "S",
        columns: [
          {
            label: "Name",
            fieldName: "name",
            style: { font: { color: { argb: "FFBA0517" } } }
          }
        ],
        rows
      });
      expect(ws.getCell("A2").font.color.argb).toBe("FFBA0517");
    });

    it("finds a column by the fieldPath Apex sends", async () => {
      const ws = await sheetOf({
        name: "S",
        columns: [{ label: "Owner", fieldPath: "Owner.Name" }],
        rows: [["Pat"]],
        style: { columns: { "Owner.Name": { font: { italic: true } } } }
      });
      expect(ws.getCell("A2").font.italic).toBe(true);
    });

    it("applies a column's conditional formatting to its data cells", async () => {
      const negative = {
        type: "cellIs",
        operator: "lessThan",
        formulae: [0],
        style: { font: { color: { argb: "FFBA0517" } } }
      };
      const contains = {
        type: "containsText",
        operator: "containsText",
        text: "b",
        style: { font: { bold: true } }
      };
      const ws = await sheetOf({
        name: "S",
        columns,
        rows,
        style: {
          columns: { amount: { conditionalFormatting: [negative] } },
          conditionalFormatting: [{ ref: "A2:A4", rules: [contains] }]
        }
      });

      expect(ws.conditionalFormattings.map((cf) => cf.ref)).toEqual(["B2:B4", "A2:A4"]);
      expect(ws.conditionalFormattings[0].rules[0]).toEqual(
        expect.objectContaining({ type: "cellIs", operator: "lessThan" })
      );
    });

    it("turns banding, freezing, filters and grid lines off when asked", async () => {
      const ws = await sheetOf({
        name: "S",
        columns,
        rows,
        style: {
          alternateRows: null,
          freezeHeader: false,
          autoFilter: false,
          showGridLines: false
        }
      });

      expect(fillOf(ws.getCell("A3"))).toBeUndefined();
      expect(ws.views[0].state).not.toBe("frozen");
      expect(ws.views[0].showGridLines).toBe(false);
      expect(ws.autoFilter).toBeFalsy();
    });
  });

  describe("mergeStyles", () => {
    it("merges objects key by key, later winning", () => {
      expect(
        mergeStyles(
          { font: { bold: true, size: 11 }, fill: { a: 1 } },
          { font: { size: 14 } },
          { fill: { b: 2 } }
        )
      ).toEqual({ font: { bold: true, size: 14 }, fill: { a: 1, b: 2 } });
    });

    it("replaces arrays whole, keeps a key set to null as null, and skips missing arguments", () => {
      expect(
        mergeStyles({ list: [1, 2], keep: 1, drop: { x: 1 } }, null, { list: [3], drop: null })
      ).toEqual({ list: [3], keep: 1, drop: null });
    });

    it("leaves its arguments alone", () => {
      const base = { font: { bold: true } };
      mergeStyles(base, { font: { size: 9 } });
      expect(base).toEqual({ font: { bold: true } });
    });
  });

  describe("sheetNames", () => {
    it("replaces the characters Excel forbids", () => {
      expect(sheetNames(["Q1/Q2: [draft]*?\\"])).toEqual(["Q1-Q2- -draft----"]);
    });

    it("cuts names to 31 characters", () => {
      expect(sheetNames(["x".repeat(40)])[0]).toHaveLength(31);
    });

    it("names blank sheets by position", () => {
      expect(sheetNames(["", null, "   "])).toEqual(["Sheet1", "Sheet2", "Sheet3"]);
    });

    it("numbers repeats, ignoring case, and keeps them within the limit", () => {
      const long = "y".repeat(31);
      expect(sheetNames(["Data", "data", "DATA", long, long])).toEqual([
        "Data",
        "data (2)",
        "DATA (3)",
        long,
        `${"y".repeat(27)} (2)`
      ]);
    });

    it("strips apostrophes at either end and avoids the reserved name", () => {
      expect(sheetNames(["'quoted'", "History"])).toEqual(["quoted", "History-"]);
    });

    it("produces names ExcelJS accepts", async () => {
      const workbook = await readBack(
        await buildWorkbook(CMP, [
          { name: "a/b", columns: [], rows: [] },
          { name: "A/B", columns: [], rows: [] }
        ])
      );
      expect(workbook.worksheets.map((ws) => ws.name)).toEqual(["a-b", "A-B (2)"]);
    });
  });
});
