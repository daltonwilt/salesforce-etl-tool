import { loadScript } from "lightning/platformResourceLoader";
import { buildCsv } from "c/csv";

// The static resource itself - the browser build of PapaParse that deploys to the org.
const Papa = require("../../../staticresources/papaparse.js");

jest.mock("lightning/platformResourceLoader", () => ({ loadScript: jest.fn() }));

const CMP = {};
const BOM = String.fromCharCode(0xfeff);

/** The CSV's lines, without the byte order mark. */
async function linesOf(sheet, options) {
  const text = await buildCsv(CMP, sheet, options);
  return text.replace(BOM, "").split("\r\n");
}

describe("c/csv", () => {
  beforeEach(() => {
    loadScript.mockImplementation(() => {
      globalThis.Papa = Papa;
      return Promise.resolve();
    });
  });

  afterEach(() => {
    jest.clearAllMocks();
  });

  it("writes a header row, then a line per row, ending lines with CRLF", async () => {
    const text = await buildCsv(CMP, {
      columns: [{ label: "Name" }, { label: "Size", type: "number" }],
      rows: [["a", 1], ["b", 2]]
    });
    expect(text).toBe(`${BOM}Name,Size\r\na,1\r\nb,2`);
  });

  it("starts with a byte order mark, so Excel reads it as UTF-8, unless told not to", async () => {
    const sheet = { columns: [{ label: "Name" }], rows: [["Zoë"]] };
    expect((await buildCsv(CMP, sheet)).charCodeAt(0)).toBe(0xfeff);
    expect(await buildCsv(CMP, sheet, { byteOrderMark: false })).toBe("Name\r\nZoë");
  });

  it("reads object rows through each column's fieldName", async () => {
    expect(
      await linesOf({
        columns: [
          { label: "Name", fieldName: "name" },
          { label: "Size", fieldName: "size" }
        ],
        rows: [{ size: 4, name: "x" }]
      })
    ).toEqual(["Name,Size", "x,4"]);
  });

  it("writes numbers plainly, percents as fractions, and booleans as words", async () => {
    expect(
      await linesOf({
        columns: [
          { label: "Amount", type: "currency" },
          { label: "Share", type: "percent" },
          { label: "Count", type: "integer" },
          { label: "Paid", type: "boolean" }
        ],
        rows: [[1234567.5, 0.125, 12000, true], [-2, 0, 0, "false"]]
      })
    ).toEqual(["Amount,Share,Count,Paid", "1234567.5,0.125,12000,true", "-2,0,0,false"]);
  });

  it("writes dates as YYYY-MM-DD and date-times in the zone given", async () => {
    const sheet = {
      columns: [
        { label: "Day", type: "date" },
        { label: "When", type: "datetime" }
      ],
      rows: [["2026-11-06", "2026-07-01T12:00:00.000Z"]]
    };
    expect(await linesOf(sheet, { timeZone: "America/New_York" })).toEqual([
      "Day,When",
      "2026-11-06,2026-07-01 08:00:00"
    ]);
    expect((await linesOf(sheet, { timeZone: "UTC" }))[1]).toBe(
      "2026-11-06,2026-07-01 12:00:00"
    );
  });

  it("quotes values holding commas, quotes or line breaks", async () => {
    expect(
      await linesOf({
        columns: [{ label: "Note" }, { label: "Say, what" }],
        rows: [['He said "hi"', "a,b"], ["line1\nline2", "plain"]]
      })
    ).toEqual(['Note,"Say, what"', '"He said ""hi""","a,b"', '"line1\nline2",plain']);
  });

  it("stops text a spreadsheet would run as a formula", async () => {
    const [, row] = await linesOf({
      columns: [
        { label: "A" },
        { label: "B" },
        { label: "C" },
        { label: "D" },
        { label: "Amount", type: "number" }
      ],
      rows: [['=HYPERLINK("http://x")', "+1", "-cmd", "@SUM(A1)", -5]]
    });
    // Text gets a leading apostrophe (and PapaParse quotes it); a real negative number is left alone.
    expect(row).toBe(`"'=HYPERLINK(""http://x"")","'+1","'-cmd","'@SUM(A1)",-5`);
  });

  it("writes empty values as empty fields", async () => {
    expect(
      await linesOf({
        columns: [{ label: "A" }, { label: "B", type: "number" }, { label: "C" }],
        rows: [[null, undefined, ""]]
      })
    ).toEqual(["A,B,C", ",,"]);
  });

  it("uses another delimiter when asked", async () => {
    expect(
      await linesOf(
        { columns: [{ label: "A" }, { label: "B" }], rows: [["1;2", "3"]] },
        { delimiter: ";" }
      )
    ).toEqual(["A;B", '"1;2";3']);
  });

  it("writes just the header for a sheet with no rows", async () => {
    // PapaParse ends a header-only file with a line break.
    expect(await linesOf({ columns: [{ label: "A" }], rows: [] })).toEqual(["A", ""]);
  });
});
