import { createElement } from "@lwc/engine-dom";
import DataImport from "c/dataImport";
import { saveFile } from "c/utils";
import getTemplates from "@salesforce/apex/DataImportJob.getTemplates";
import getTemplate from "@salesforce/apex/DataImportJob.getTemplate";
import startJob from "@salesforce/apex/DataImportJob.start";
import stageChunk from "@salesforce/apex/DataImportJob.stage";
import runJob from "@salesforce/apex/DataImportJob.run";
import jobStatus from "@salesforce/apex/DataImportJob.status";
import getRejectRows from "@salesforce/apex/DataImportJob.getRejectRows";
import { sliceFile } from "../csvStream";

/* ── Mocks ──────────────────────────────────────────────────────────────────────────────── */

jest.mock(
  "@salesforce/apex/DataImportJob.getTemplates",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DataImportJob.getTemplate",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DataImportJob.start",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DataImportJob.stage",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DataImportJob.run",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DataImportJob.status",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DataImportJob.getRejectRows",
  () => ({ default: jest.fn() }),
  { virtual: true }
);

jest.mock("c/utils", () => ({ saveFile: jest.fn() }), { virtual: true });

// The slicer has its own concerns (streaming, quoting, section boundaries); here it only needs to
// hand the component a result, and to call onChunk so staging can be observed.
jest.mock("../csvStream", () => ({ sliceFile: jest.fn() }));

// The stock stub's Navigate is a no-op with no way to see what it was asked for.
const mockNavigate = jest.fn();
jest.mock(
  "lightning/navigation",
  () => {
    const Navigate = Symbol("Navigate");
    const NavigationMixin = (Base) =>
      class extends Base {
        [Navigate](pageRef) {
          mockNavigate(pageRef);
        }
      };
    NavigationMixin.Navigate = Navigate;
    return { NavigationMixin };
  }
);

/* ── Fixtures ───────────────────────────────────────────────────────────────────────────── */

const TEMPLATES = [
  { name: "SLFRF_Equipment", label: "SLFRF Equipment and Supplies" },
  { name: "Vendors", label: "Vendor List" }
];

const SPEC = {
  label: "SLFRF Equipment and Supplies",
  sections: [{ type: "rows", sectionName: "equipment", target: "X__c" }]
};

const JOB_ID = "a0X000000000001AAA";

const SLICE_RESULT = {
  totalChunks: 2,
  sectionMap: [{ sectionName: "equipment", firstRow: 5, lastRow: null }],
  duplicates: []
};

/* ── Helpers ────────────────────────────────────────────────────────────────────────────── */

/**
 * Drain pending promise callbacks and LWC re-renders.
 *
 * Built from microtasks rather than setTimeout so it still works while timers are faked.
 */
async function flush() {
  for (let i = 0; i < 25; i++) {
    // eslint-disable-next-line no-await-in-loop
    await Promise.resolve();
  }
}

function mount(props = {}) {
  const element = createElement("c-data-import", { is: DataImport });
  Object.assign(element, props);
  document.body.appendChild(element);
  return element;
}

function chooseFile(element, file) {
  const input = element.shadowRoot.querySelector('input[type="file"]');
  Object.defineProperty(input, "files", { value: [file], configurable: true });
  input.dispatchEvent(new CustomEvent("change"));
  return input;
}

function csv(name = "equipment.csv") {
  return new File(["a,b\n1,2\n"], name, { type: "text/csv" });
}

function text(element) {
  return element.shadowRoot.textContent;
}

function buttonLabelled(element, label) {
  return Array.from(element.shadowRoot.querySelectorAll("lightning-button")).find(
    (b) => b.label === label
  );
}

/** Mount with a fixed template, pick a file, and let the import reach the polling stage. */
async function startImport(props = {}) {
  const element = mount({ templateName: "SLFRF_Equipment", ...props });
  await flush();
  chooseFile(element, csv());
  await flush();
  return element;
}

/* ── Tests ──────────────────────────────────────────────────────────────────────────────── */

describe("c-data-import", () => {
  beforeEach(() => {
    getTemplates.mockResolvedValue(TEMPLATES);
    getTemplate.mockResolvedValue({ definition: JSON.stringify(SPEC) });
    startJob.mockResolvedValue(JOB_ID);
    stageChunk.mockResolvedValue();
    runJob.mockResolvedValue();
    sliceFile.mockImplementation(async (file, spec, onChunk, onProgress) => {
      await onChunk("a,b\n1,2", 1, 2);
      await onChunk("3,4", 2, 3);
      if (onProgress) onProgress(10, 10);
      return SLICE_RESULT;
    });
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
    jest.useRealTimers();
  });

  describe("choosing a template", () => {
    it("lists the available templates when none is fixed", async () => {
      const element = mount();
      await flush();

      expect(getTemplates).toHaveBeenCalledTimes(1);
      expect(getTemplate).not.toHaveBeenCalled();

      const picker = element.shadowRoot.querySelector("lightning-combobox");
      expect(picker).not.toBeNull();
      expect(picker.options).toEqual([
        { label: "SLFRF Equipment and Supplies", value: "SLFRF_Equipment" },
        { label: "Vendor List", value: "Vendors" }
      ]);
    });

    it("loads the chosen template's definition", async () => {
      const element = mount();
      await flush();

      const picker = element.shadowRoot.querySelector("lightning-combobox");
      picker.dispatchEvent(
        new CustomEvent("change", { detail: { value: "Vendors" } })
      );
      await flush();

      expect(getTemplate).toHaveBeenCalledWith({ templateName: "Vendors" });
    });

    it("skips the picker and loads the template directly when one is fixed", async () => {
      const element = mount({ templateName: "SLFRF_Equipment" });
      await flush();

      expect(getTemplates).not.toHaveBeenCalled();
      expect(getTemplate).toHaveBeenCalledWith({
        templateName: "SLFRF_Equipment"
      });
      expect(element.shadowRoot.querySelector("lightning-combobox")).toBeNull();
    });

    it("says so when there are no templates to choose from", async () => {
      getTemplates.mockResolvedValue([]);
      const element = mount();
      await flush();

      expect(text(element)).toContain("No import templates are configured");
      expect(element.shadowRoot.querySelector("lightning-combobox")).toBeNull();
    });

    it("shows the server's message when templates cannot be loaded", async () => {
      getTemplates.mockRejectedValue({ body: { message: "Insufficient access" } });
      const element = mount();
      await flush();

      const alert = element.shadowRoot.querySelector(".slds-theme_error");
      expect(alert).not.toBeNull();
      expect(alert.textContent).toContain("Insufficient access");
    });

    it("renders the configured heading", async () => {
      const element = mount({ label: "Upload Equipment" });
      await flush();

      expect(element.shadowRoot.querySelector("h2").textContent).toBe(
        "Upload Equipment"
      );
    });
  });

  describe("importing a file", () => {
    it("refuses a file until a template has been chosen", async () => {
      const element = mount();
      await flush();

      chooseFile(element, csv());
      await flush();

      expect(startJob).not.toHaveBeenCalled();
      expect(text(element)).toContain(
        "Choose what you are importing before picking a file."
      );
    });

    it("creates the job, stages every slice, then runs it", async () => {
      await startImport({ bindings: { reportId: "a01000000000001" } });

      expect(startJob).toHaveBeenCalledWith({
        request: {
          template: "SLFRF_Equipment",
          fileName: "equipment.csv",
          totalChunks: 0,
          bindingsJson: JSON.stringify({ reportId: "a01000000000001" }),
          sectionMapJson: null
        }
      });

      expect(sliceFile).toHaveBeenCalledWith(
        expect.any(File),
        SPEC,
        expect.any(Function),
        expect.any(Function)
      );
      expect(stageChunk).toHaveBeenNthCalledWith(1, {
        jobId: JOB_ID,
        sequence: 1,
        firstRowNumber: 2,
        body: "a,b\n1,2"
      });
      expect(stageChunk).toHaveBeenNthCalledWith(2, {
        jobId: JOB_ID,
        sequence: 2,
        firstRowNumber: 3,
        body: "3,4"
      });

      expect(runJob).toHaveBeenCalledWith({
        jobId: JOB_ID,
        totalChunks: 2,
        sectionMapJson: JSON.stringify(SLICE_RESULT.sectionMap)
      });
    });

    it("clears the file input so the same file can be picked again", async () => {
      const element = mount({ templateName: "SLFRF_Equipment" });
      await flush();

      const input = chooseFile(element, csv());
      expect(input.value).toBe("");
    });

    it("stops before running when the file has duplicate keys", async () => {
      sliceFile.mockResolvedValue({
        ...SLICE_RESULT,
        duplicates: ["Row 7: key ABC-1 also on row 4", "Row 9: key ABC-2 also on row 5"]
      });

      const element = await startImport();

      expect(runJob).not.toHaveBeenCalled();
      const warning = element.shadowRoot.querySelector(".slds-theme_warning");
      expect(warning).not.toBeNull();
      expect(warning.textContent).toContain(
        "2 duplicate key(s) in this file. Nothing was imported."
      );
      expect(warning.querySelectorAll("li")).toHaveLength(2);
    });

    it("shows the server's message when the job cannot be started", async () => {
      startJob.mockRejectedValue({ body: { message: "Template is inactive" } });

      const element = await startImport();

      expect(sliceFile).not.toHaveBeenCalled();
      expect(
        element.shadowRoot.querySelector(".slds-theme_error").textContent
      ).toContain("Template is inactive");
    });

    it("falls back to a generic message for an error without one", async () => {
      runJob.mockRejectedValue({});

      const element = await startImport();

      expect(
        element.shadowRoot.querySelector(".slds-theme_error").textContent
      ).toContain("The import could not be started.");
    });
  });

  describe("watching the batch", () => {
    beforeEach(() => {
      jest.useFakeTimers();
    });

    it("reports progress while running, then the result when it finishes", async () => {
      jobStatus
        .mockResolvedValueOnce({
          Id: JOB_ID,
          Status__c: "Processing",
          Chunks_Processed__c: 1,
          Total_Chunks__c: 2,
          Rows_Read__c: 800
        })
        .mockResolvedValueOnce({
          Id: JOB_ID,
          Status__c: "Completed",
          Message__c: "1,600 records imported.",
          Records_Committed__c: 1600,
          Rows_Failed__c: 0
        });

      const element = await startImport();
      const imported = jest.fn();
      element.addEventListener("imported", imported);

      await jest.advanceTimersByTimeAsync(3000);
      await flush();
      expect(text(element)).toContain("Importing… 1 of 2 batches · 800 rows read");
      expect(element.shadowRoot.querySelector("lightning-spinner")).not.toBeNull();

      await jest.advanceTimersByTimeAsync(3000);
      await flush();
      expect(element.shadowRoot.querySelector("lightning-spinner")).toBeNull();
      expect(text(element)).toContain("1,600 records imported.");

      expect(imported).toHaveBeenCalledTimes(1);
      expect(imported.mock.calls[0][0].detail).toEqual({
        jobId: JOB_ID,
        status: "Completed",
        committed: 1600,
        failed: 0
      });

      // Terminal: no further polling.
      await jest.advanceTimersByTimeAsync(9000);
      expect(jobStatus).toHaveBeenCalledTimes(2);
    });

    it("lists errors and offers the reject file when rows failed", async () => {
      jobStatus.mockResolvedValue({
        Id: JOB_ID,
        Status__c: "Completed",
        Message__c: "1,598 imported, 2 failed.",
        Errors__c: "Row 12: bad date\nRow 40: bad number",
        Rows_Failed__c: 2
      });

      const element = await startImport();
      await jest.advanceTimersByTimeAsync(3000);
      await flush();

      const errors = element.shadowRoot.querySelectorAll(".slds-text-color_error");
      expect(Array.from(errors).map((li) => li.textContent.trim())).toEqual([
        "Row 12: bad date",
        "Row 40: bad number"
      ]);
      expect(buttonLabelled(element, "Download rows to fix")).toBeTruthy();
      expect(buttonLabelled(element, "Open import record")).toBeTruthy();
    });

    it("has no reject download when errors were reported but no rows failed", async () => {
      jobStatus.mockResolvedValue({
        Id: JOB_ID,
        Status__c: "Failed",
        Message__c: "Missing permission",
        Errors__c: "You cannot edit Acquired_Date__c",
        Rows_Failed__c: 0
      });

      const element = await startImport();
      await jest.advanceTimersByTimeAsync(3000);
      await flush();

      expect(buttonLabelled(element, "Download rows to fix")).toBeUndefined();
      expect(buttonLabelled(element, "Open import record")).toBeTruthy();
    });

    it("stops polling and reports an error if the status check fails", async () => {
      jobStatus.mockRejectedValue({ body: { message: "Job not found" } });

      const element = await startImport();
      await jest.advanceTimersByTimeAsync(3000);
      await flush();

      expect(text(element)).toContain("Job not found");
      await jest.advanceTimersByTimeAsync(9000);
      expect(jobStatus).toHaveBeenCalledTimes(1);
    });

    it("gives up after twenty minutes", async () => {
      jobStatus.mockResolvedValue({ Id: JOB_ID, Status__c: "Processing" });

      const element = await startImport();
      await jest.advanceTimersByTimeAsync(20 * 60 * 1000 + 3000);
      await flush();

      expect(text(element)).toContain("This import is taking longer than expected.");
      const calls = jobStatus.mock.calls.length;
      await jest.advanceTimersByTimeAsync(9000);
      expect(jobStatus).toHaveBeenCalledTimes(calls);
    });

    it("stops polling when removed from the page", async () => {
      jobStatus.mockResolvedValue({ Id: JOB_ID, Status__c: "Processing" });

      const element = await startImport();
      await jest.advanceTimersByTimeAsync(3000);
      expect(jobStatus).toHaveBeenCalledTimes(1);

      document.body.removeChild(element);
      await jest.advanceTimersByTimeAsync(9000);
      expect(jobStatus).toHaveBeenCalledTimes(1);
    });
  });

  describe("after the import", () => {
    beforeEach(() => {
      jest.useFakeTimers();
      jobStatus.mockResolvedValue({
        Id: JOB_ID,
        Status__c: "Completed",
        Message__c: "Done with errors",
        Errors__c: "Row 12: bad date",
        Rows_Failed__c: 3
      });
    });

    async function finishedImport() {
      const element = await startImport();
      await jest.advanceTimersByTimeAsync(3000);
      await flush();
      return element;
    }

    it("pages through the rejects and saves one file per section", async () => {
      getRejectRows
        .mockResolvedValueOnce({
          fileName: "equipment.csv",
          header: "Item,Cost",
          rows: [
            { section: "equipment", body: "Laptop,abc,,bad cost" },
            { section: "supplies", body: "Paper,x,,bad cost" }
          ],
          hasMore: true,
          lastSequence: 4
        })
        .mockResolvedValueOnce({
          rows: [{ section: "equipment", body: "Desk,?,,bad cost" }],
          hasMore: false
        });

      const element = await finishedImport();
      buttonLabelled(element, "Download rows to fix").dispatchEvent(
        new CustomEvent("click")
      );
      await flush();

      expect(getRejectRows).toHaveBeenNthCalledWith(1, {
        jobId: JOB_ID,
        afterSequence: null
      });
      expect(getRejectRows).toHaveBeenNthCalledWith(2, {
        jobId: JOB_ID,
        afterSequence: 4
      });

      expect(saveFile).toHaveBeenCalledTimes(2);
      expect(saveFile).toHaveBeenCalledWith(
        "Item,Cost,,Import Error\nLaptop,abc,,bad cost\nDesk,?,,bad cost",
        "equipment-equipment-rows-to-fix.csv",
        expect.objectContaining({ fallbackType: "text/csv;charset=utf-8" })
      );
      expect(saveFile).toHaveBeenCalledWith(
        "Item,Cost,,Import Error\nPaper,x,,bad cost",
        "equipment-supplies-rows-to-fix.csv",
        expect.anything()
      );

      // The anchor in the template is what the file is handed to.
      expect(saveFile.mock.calls[0][2].anchor).toBe(
        element.shadowRoot.querySelector("a.reject-download")
      );
    });

    it("names an unsectioned reject file after the upload", async () => {
      getRejectRows.mockResolvedValue({
        rows: [{ section: null, body: "1,2,,bad" }],
        hasMore: false
      });

      const element = await finishedImport();
      buttonLabelled(element, "Download rows to fix").dispatchEvent(
        new CustomEvent("click")
      );
      await flush();

      expect(saveFile).toHaveBeenCalledWith(
        "1,2,,bad",
        "equipment-rows-to-fix.csv",
        expect.anything()
      );
    });

    it("reports a failed download", async () => {
      getRejectRows.mockRejectedValue({ body: { message: "Rejects purged" } });

      const element = await finishedImport();
      buttonLabelled(element, "Download rows to fix").dispatchEvent(
        new CustomEvent("click")
      );
      await flush();

      expect(saveFile).not.toHaveBeenCalled();
      expect(
        element.shadowRoot.querySelector(".slds-theme_error").textContent
      ).toContain("Rejects purged");
    });

    it("opens the import record", async () => {
      const element = await finishedImport();
      buttonLabelled(element, "Open import record").dispatchEvent(
        new CustomEvent("click")
      );

      expect(mockNavigate).toHaveBeenCalledWith({
        type: "standard__recordPage",
        attributes: {
          recordId: JOB_ID,
          objectApiName: "Data_Import_Job__c",
          actionName: "view"
        }
      });
    });
  });
});
