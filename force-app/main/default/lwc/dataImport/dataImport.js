import { LightningElement, api, track } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { saveFile } from "c/utils"; // @https://github.com/daltonwilt/salesforce-component-library
import getTemplates from "@salesforce/apex/DataImportJob.getTemplates";
import getTemplate from "@salesforce/apex/DataImportJob.getTemplate";
import startJob from "@salesforce/apex/DataImportJob.start";
import stageChunk from "@salesforce/apex/DataImportJob.stage";
import runJob from "@salesforce/apex/DataImportJob.run";
import jobStatus from "@salesforce/apex/DataImportJob.status";
import getRejectRows from "@salesforce/apex/DataImportJob.getRejectRows";
import { sliceFile } from "./csvStream";

/**
 * Loads a CSV into any object, from any template, with no ceiling on the number of rows.
 *
 *   <c-g_-data-importer
 *     template="SLFRF_Equipment"
 *     bindings={bindings}
 *     onimported={handleImported}>
 *   </c-g_-data-importer>
 *
 * The file is read HERE and never reaches Apex whole. That is the single decision the whole design
 * rests on: `VersionData.toString()` on the server puts the file in a 12 MB heap alongside the rows
 * parsed from it and the records built from those, which caps an import at roughly 25,000 rows.
 * Slicing in the browser makes every chunk cost the same, so ten chunks and ten thousand chunks are
 * the same problem.
 *
 * Two checks also happen here rather than in Apex, and for the same kind of reason — see
 * ./csvStream.js. Section boundaries, because Batch Apex does not promise to process chunks in
 * order. Duplicate keys, because that needs whole-file state.
 */

/** How often to ask the server how the batch is getting on. */
const POLL_MS = 3000;

/** Give up watching after this long. A batch that has not finished by now is stuck, not slow. */
const POLL_TIMEOUT_MS = 20 * 60 * 1000;

/** Statuses the job will not move on from. */
const TERMINAL = ["Completed", "Failed", "Aborted", "Cancelled"];

export default class DataImport extends NavigationMixin(LightningElement) {
  /* ── Public API ─────────────────────────────────────────────────────────────────────────── */

  /**
   * Fix the component to one template. Omit to let the user pick.
   *
   * NOT named `template`: that is LightningElement's own property for the shadow root, and an @api
   * of the same name shadows it — `this.template.querySelector` then fails with "is not a
   * function" the moment a host passes a value in.
   */
  @api templateName;

  /** Values the template's `$placeholder` defaults resolve against, e.g. { reportId: '...' }. */
  @api bindings = {};

  /** Heading above the picker. */
  @api label = "Import Data";

  /* ── State ──────────────────────────────────────────────────────────────────────────────── */

  @track templates = [];
  @track selectedTemplate;
  @track spec;

  @track phase = "idle"; // idle | reading | staging | running | done
  @track fileName;
  @track progress = 0;
  @track message;
  @track job;
  @track blockingErrors = []; // found before the job exists — nothing has been sent yet
  @track loadedTemplates = false;
  @track buildingDownload = false;

  pollId;

  /* ── Lifecycle ──────────────────────────────────────────────────────────────────────────── */

  connectedCallback() {
    if (this.templateName) {
      this.selectedTemplate = this.templateName;
      this.loadSpec();
    } else {
      getTemplates()
        .then((rows) => {
          this.templates = rows || [];
          this.loadedTemplates = true;
        })
        .catch((e) => {
          this.loadedTemplates = true;
          this.fail(e);
        });
    }
  }

  disconnectedCallback() {
    this.stopPolling();
  }

  /* ── Presentation ───────────────────────────────────────────────────────────────────────── */

  get templateOptions() {
    return this.templates.map((t) => ({ label: t.label, value: t.name }));
  }

  get showPicker() {
    return !this.templateName && this.templates.length > 0;
  }

  get canChooseFile() {
    return !!this.selectedTemplate && !this.busy;
  }

  get busy() {
    return (
      this.phase === "reading" ||
      this.phase === "staging" ||
      this.phase === "running"
    );
  }

  get statusLabel() {
    if (this.phase === "reading") return "Reading your file…";
    if (this.phase === "staging") return `Uploading… ${this.progress}%`;
    if (this.phase === "running")
      return this.job ? this.runningLabel : "Importing…";
    return null;
  }

  get runningLabel() {
    const done = this.job.Chunks_Processed__c || 0;
    const total = this.job.Total_Chunks__c || 0;
    const rows = this.job.Rows_Read__c || 0;
    return total
      ? `Importing… ${done} of ${total} batches · ${rows} rows read`
      : "Importing…";
  }

  /** A failure before the job finished. Without this the component just stops, saying nothing. */
  get showProblem() {
    return (
      !!this.message &&
      !this.busy &&
      this.phase !== "done" &&
      !this.hasBlockingErrors
    );
  }

  get noTemplates() {
    return (
      !this.templateName && this.loadedTemplates && this.templates.length === 0
    );
  }

  get hasBlockingErrors() {
    return this.blockingErrors.length > 0;
  }

  get finished() {
    return this.phase === "done" && !!this.job;
  }

  get succeeded() {
    return this.finished && this.job.Status__c === "Completed";
  }

  get errorLines() {
    if (!this.job || !this.job.Errors__c) return [];
    return this.job.Errors__c.split("\n").map((text, i) => ({
      key: `e${i}`,
      text
    }));
  }

  get hasRejects() {
    return this.finished && (this.job.Rows_Failed__c || 0) > 0;
  }

  /**
   * Assemble the rejected rows into a download, here in the browser.
   *
   * Fetched a page at a time and joined as they arrive, the same way the upload was sliced. Apex
   * never holds the whole thing, so a file with a hundred thousand rejected rows costs no more per
   * request than one with ten — and none of it touches Salesforce Files, which a portal user cannot
   * publish to.
   */
  async handleDownloadRejects() {
    if (this.buildingDownload) return;
    this.buildingDownload = true;
    try {
      const bySection = new Map();
      let fileName = this.fileName || "import";
      let header = "";
      let after = null;

      for (;;) {
        // eslint-disable-next-line no-await-in-loop
        const page = await getRejectRows({
          jobId: this.job.Id,
          afterSequence: after
        });
        if (page.fileName) fileName = page.fileName;
        if (page.header) header = page.header;

        (page.rows || []).forEach(({ section, body }) => {
          const key = section || "";
          if (!bySection.has(key)) bySection.set(key, []);
          bySection.get(key).push(body);
        });

        if (!page.hasMore) break;
        after = page.lastSequence;
      }

      const base = fileName.toLowerCase().endsWith(".csv")
        ? fileName.slice(0, -4)
        : fileName;

      bySection.forEach((bodies, section) => {
        const head = header ? `${header},,Import Error\n` : "";
        this.download(
          head + bodies.join("\n"),
          `${base}${section ? `-${section}` : ""}-rows-to-fix.csv`
        );
      });
    } catch (e) {
      this.fail(e);
    } finally {
      this.buildingDownload = false;
    }
  }

  /**
   * Hands the assembled CSV to the browser through an anchor already in the template.
   *
   * The mechanics - the text/plain wrapper that dodges LWS's MIME restriction, the deferred
   * revoke, the anchor - live in saveFile(), which learned them here. A reject file is text and
   * rarely large, so the data-URL fallback is worth having when createObjectURL is blocked
   * outright; the type named there is the real one, since a data URL is read by its own type
   * rather than by the download attribute.
   */
  download(content, name) {
    saveFile(content, name, {
      anchor: this.template.querySelector("a.reject-download"),
      fallbackType: "text/csv;charset=utf-8",
      source: "g_DataImporter.download"
    });
  }

  /**
   * Open the job record, where the errors are listed.
   *
   * The error list tells the user what is wrong; the reject file — the template back again with
   * only the failed rows in it — is what saves them finding those rows among forty thousand.
   */
  handleOpenJob() {
    if (!this.job) return;
    this[NavigationMixin.Navigate]({
      type: "standard__recordPage",
      attributes: {
        recordId: this.job.Id,
        objectApiName: "Data_Import_Job__c",
        actionName: "view"
      }
    });
  }

  /* ── Template ───────────────────────────────────────────────────────────────────────────── */

  handleTemplateChange(event) {
    this.selectedTemplate = event.detail.value;
    this.reset();
    this.loadSpec();
  }

  loadSpec() {
    getTemplate({ templateName: this.selectedTemplate })
      .then((info) => {
        this.spec = JSON.parse(info.definition);
      })
      .catch((e) => this.fail(e));
  }

  /* ── Import ─────────────────────────────────────────────────────────────────────────────── */

  handleFile(event) {
    const input = event.target;
    const file = input.files && input.files[0];
    // Clear it, or picking the SAME file again fires no change event — which is exactly what a
    // person does after fixing the rows the last run rejected.
    input.value = "";
    if (file) this.importFile(file);
  }

  /**
   * Read, check, stage, run.
   *
   * The file is read once. Everything that needs to see all of it — section boundaries, duplicate
   * keys — is worked out during that single pass, and the slices are staged as they are produced
   * rather than collected first.
   */
  async importFile(file) {
    this.reset();
    if (!this.spec) {
      this.message = "Choose what you are importing before picking a file.";
      return;
    }
    this.fileName = file.name;
    this.phase = "reading";

    try {
      // The job has to exist before a chunk can point at it, but what the file CONTAINS — how many
      // chunks, where each table sits — is only known once it has been read. So the job is created
      // empty, filled by staging, and told what it holds at the end.
      const jobId = await startJob({
        request: {
          template: this.selectedTemplate,
          fileName: file.name,
          totalChunks: 0,
          bindingsJson: JSON.stringify(this.bindings || {}),
          sectionMapJson: null
        }
      });

      this.phase = "staging";
      const outcome = await sliceFile(
        file,
        this.spec,
        (body, sequence, firstRowNumber) =>
          stageChunk({ jobId, sequence, firstRowNumber, body }),
        (read, total) => {
          this.progress = total ? Math.round((read / total) * 100) : 0;
        }
      );

      // A file that contradicts itself is stopped before anything is imported: the same key twice
      // would insert twice or update once depending on where a chunk boundary happened to fall.
      if (outcome.duplicates.length) {
        this.blockingErrors = outcome.duplicates.slice(0, 100);
        this.phase = "idle";
        this.message = `${outcome.duplicates.length} duplicate key(s) in this file. Nothing was imported.`;
        return;
      }

      this.phase = "running";
      await runJob({
        jobId,
        totalChunks: outcome.totalChunks,
        sectionMapJson: JSON.stringify(outcome.sectionMap)
      });
      this.startPolling(jobId);
    } catch (e) {
      this.fail(e);
    }
  }

  /* ── Polling ────────────────────────────────────────────────────────────────────────────── */

  /**
   * A batch over a large file runs for minutes, so its progress has to be asked for.
   *
   * The lint rule against timers guards against components that leak them; this one is cleared both
   * when the job reaches a terminal status and in disconnectedCallback, so it cannot outlive the
   * component.
   */
  startPolling(jobId) {
    this.stopPolling();
    const startedAt = Date.now();
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.pollId = setInterval(() => {
      if (Date.now() - startedAt > POLL_TIMEOUT_MS) {
        this.stopPolling();
        this.phase = "idle";
        this.message =
          "This import is taking longer than expected. Open the import record to see where it got to.";
        return;
      }
      jobStatus({ jobId })
        .then((job) => {
          this.job = job;
          if (TERMINAL.includes(job.Status__c)) {
            this.stopPolling();
            this.phase = "done";
            this.message = job.Message__c;
            this.dispatchEvent(
              new CustomEvent("imported", {
                detail: {
                  jobId: job.Id,
                  status: job.Status__c,
                  committed: job.Records_Committed__c,
                  failed: job.Rows_Failed__c
                }
              })
            );
          }
        })
        .catch((e) => {
          this.stopPolling();
          this.fail(e);
        });
    }, POLL_MS);
  }

  stopPolling() {
    if (this.pollId) {
      clearInterval(this.pollId);
      this.pollId = undefined;
    }
  }

  /* ── Support ────────────────────────────────────────────────────────────────────────────── */

  reset() {
    this.stopPolling();
    this.phase = "idle";
    this.progress = 0;
    this.message = undefined;
    this.job = undefined;
    this.blockingErrors = [];
  }

  fail(error) {
    this.phase = "idle";
    this.message =
      (error && error.body && error.body.message) ||
      (error && error.message) ||
      "The import could not be started.";
  }
}