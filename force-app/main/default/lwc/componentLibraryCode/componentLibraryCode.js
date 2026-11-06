import { LightningElement, api } from "lwc";
import { logError } from "c/utils";

/** How long the copy button shows its result before going back to the copy icon. */
const FEEDBACK_MS = 2000;

/**
 * Source viewer for the component library: one tab per file, with a copy button.
 *
 *   <c-component-library-code files={files}></c-component-library-code>
 *
 * files: [{ name, language, source }] — the shape componentLibrary/snippets.js holds.
 */
export default class ComponentLibraryCode extends LightningElement {
  @api files = [];

  _copied; // { name, ok } for the file whose copy button is showing a result
  _timer;

  disconnectedCallback() {
    clearTimeout(this._timer);
  }

  get hasFiles() {
    return Array.isArray(this.files) && this.files.length > 0;
  }

  get fileViews() {
    return (this.files || []).map((file) => {
      const result =
        this._copied && this._copied.name === file.name ? this._copied : null;
      let copyLabel = `Copy ${file.name}`;
      let copyIcon = "utility:copy";
      if (result) {
        copyLabel = result.ok ? "Copied" : "Copy failed — select the code to copy it";
        copyIcon = result.ok ? "utility:check" : "utility:error";
      }
      return { ...file, copyLabel, copyIcon };
    });
  }

  async handleCopy(event) {
    const name = event.currentTarget.dataset.name;
    const file = (this.files || []).find((f) => f.name === name);
    if (!file) return;

    let ok = false;
    try {
      // The Clipboard API is missing outside a secure context and can be refused by the
      // browser, so a failure is reported on the button rather than thrown.
      await navigator.clipboard.writeText(file.source);
      ok = true;
    } catch (e) {
      logError("componentLibraryCode.copy", e);
    }

    this._copied = { name, ok };
    clearTimeout(this._timer);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this._timer = setTimeout(() => {
      this._copied = undefined;
    }, FEEDBACK_MS);
  }
}
