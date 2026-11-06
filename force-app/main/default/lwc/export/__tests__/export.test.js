import { loadScript } from "lightning/platformResourceLoader";
import {
  cellReader,
  dateConverter,
  normalizeType,
  typedValue,
  COLUMN_TYPES
} from "c/export";

const fs = require("fs");
const path = require("path");
const JSZip = require("../../../staticresources/jszip.js");
const { staleFiles } = require("../../../../../../scripts/vendor-libraries");

jest.mock("lightning/platformResourceLoader", () => ({ loadScript: jest.fn() }));

const CMP = {};
const LWC_DIR = path.join(__dirname, "..", "..");

/** A fresh copy of the module, with nothing loaded yet and no JSZip global. */
function freshModule() {
  delete globalThis.JSZip;
  let fresh;
  jest.isolateModules(() => {
    fresh = require("c/export");
  });
  return fresh;
}

function provideJSZip() {
  loadScript.mockImplementation(() => {
    globalThis.JSZip = JSZip;
    return Promise.resolve();
  });
}

describe("c/export", () => {
  afterEach(() => {
    jest.clearAllMocks();
  });

  describe("source", () => {
    it("has static resources in step with the versions in package.json", () => {
      expect(staleFiles()).toEqual([]);
    });

    it("keeps every component free of characters Salesforce refuses to store", () => {
      // A literal U+FFFE or U+FFFF fails the deploy with "Invalid field value for field
      // LightningComponentResource.Source", and a literal byte order mark is invisible in review.
      // Source that means them must use escapes.
      const offenders = [];
      for (const bundle of fs.readdirSync(LWC_DIR)) {
        const dir = path.join(LWC_DIR, bundle);
        if (!fs.statSync(dir).isDirectory()) continue;
        for (const file of fs.readdirSync(dir)) {
          if (!/\.(js|html|css)$/.test(file)) continue;
          if (/[\ufeff\ufffe\uffff]/.test(fs.readFileSync(path.join(dir, file), "utf8"))) {
            offenders.push(`${bundle}/${file}`);
          }
        }
      }
      expect(offenders).toEqual([]);
    });
  });

  describe("loadLibrary", () => {
    it("loads a library once and reuses it", async () => {
      provideJSZip();
      const common = freshModule();
      await common.zip(CMP, [{ name: "a.txt", data: "a" }]);
      await common.zip(CMP, [{ name: "b.txt", data: "b" }]);

      expect(loadScript).toHaveBeenCalledTimes(1);
      expect(loadScript.mock.calls[0][0]).toBe(CMP);
    });

    it("says so when a library will not load, and tries again next time", async () => {
      provideJSZip();
      const common = freshModule();
      loadScript.mockRejectedValueOnce(new Error("blocked"));
      await expect(common.zip(CMP, [])).rejects.toThrow("The JSZip library could not be loaded.");

      await expect(common.zip(CMP, [])).resolves.toBeInstanceOf(Uint8Array);
      expect(loadScript).toHaveBeenCalledTimes(2);
    });

    it("says so when the script loads but defines nothing", async () => {
      loadScript.mockResolvedValue();
      const common = freshModule();
      await expect(common.zip(CMP, [])).rejects.toThrow("could not be loaded");
    });
  });

  describe("zip", () => {
    it("bundles the files given under their names", async () => {
      provideJSZip();
      const common = freshModule();
      const bytes = await common.zip(CMP, [
        { name: "a.txt", data: "hello" },
        { name: "résumé.bin", data: new Uint8Array([104, 105]) }
      ]);
      const archive = await JSZip.loadAsync(bytes);

      expect(bytes).toBeInstanceOf(Uint8Array);
      expect(await archive.file("a.txt").async("string")).toBe("hello");
      expect(await archive.file("résumé.bin").async("string")).toBe("hi");
    });
  });

  describe("values", () => {
    const toDate = dateConverter("UTC");

    it("reads array rows by position and object rows by fieldName", () => {
      const read = cellReader({ fieldName: "size" }, 1);
      expect(read(["x", 4])).toBe(4);
      expect(read({ size: 5 })).toBe(5);
      expect(read(null)).toBeNull();
      expect(cellReader({}, 0)({ size: 5 })).toBeUndefined();
    });

    it("treats a missing or unknown type as text", () => {
      expect(normalizeType()).toBe("text");
      expect(normalizeType("Currency")).toBe("currency");
      expect(normalizeType("rating")).toBe("text");
      expect(COLUMN_TYPES).toContain("datetime");
    });

    it("types numbers, booleans and dates, and keeps misfits as text", () => {
      expect(typedValue("12.5", "number", toDate)).toBe(12.5);
      expect(typedValue("n/a", "currency", toDate)).toBe("n/a");
      expect(typedValue("TRUE", "boolean", toDate)).toBe(true);
      expect(typedValue(0, "boolean", toDate)).toBe(false);
      expect(typedValue("maybe", "boolean", toDate)).toBe("maybe");
      expect(typedValue("2026-11-06", "date", toDate).toISOString()).toBe(
        "2026-11-06T00:00:00.000Z"
      );
      expect(typedValue("soon", "date", toDate)).toBe("soon");
      expect(typedValue("a\r\nb\rc", "text", toDate)).toBe("a\nb\nc");
    });

    it("leaves empty values empty", () => {
      for (const empty of [null, undefined, ""]) {
        expect(typedValue(empty, "text", toDate)).toBeNull();
      }
    });

    it("holds a date-time's wall-clock time in its UTC fields", () => {
      const newYork = dateConverter("America/New_York");
      // Noon UTC is 08:00 in New York in July (EDT, UTC-4).
      expect(newYork("2026-07-01T12:00:00.000Z", "datetime").toISOString()).toBe(
        "2026-07-01T08:00:00.000Z"
      );
      // A date is never shifted, even where the zone is a day ahead.
      expect(dateConverter("Pacific/Kiritimati")("2026-11-06", "date").toISOString()).toBe(
        "2026-11-06T00:00:00.000Z"
      );
    });

    it("needs an offset to read a date-time string, and falls back for an unknown zone", () => {
      expect(toDate("2026-07-01 12:00", "datetime")).toBeNull();
      expect(toDate(Date.UTC(2026, 6, 1, 18), "datetime").toISOString()).toBe(
        "2026-07-01T18:00:00.000Z"
      );
      expect(dateConverter("Not/AZone")("2026-07-01T12:00:00Z", "datetime")).toBeInstanceOf(Date);
    });
  });
});
