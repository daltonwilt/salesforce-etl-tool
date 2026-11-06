import { ShowToastEvent } from "lightning/platformShowToastEvent";

/**
 * Shared helpers for LWCs.
 *
 * A service module, not a component — there is no template and nothing renders. Import only the
 * functions a component needs:
 *
 *   import { toast, toastError, fire, debounce, errorMessage } from "c/utils";
 *
 * Every helper that dispatches an event takes the component as its first argument, because
 * dispatchEvent only exists on the element. Inside a component that reads as:
 *
 *   toast(this, "Saved", "Request submitted.", "success");
 *
 * This replaces the per-component `toast()` / `msg()` helpers that were being copied between
 * components. It intentionally does NOT extend LightningElement: extending a base class forces a
 * component to give up its own base class (LightningModal, NavigationMixin), while imports
 * compose with anything.
 */

const DEFAULT_DEBOUNCE_MS = 300;
const DEFAULT_ERROR = "Unexpected error";

let debugEnabled = false;

/* ── Events ─────────────────────────────────────────────────────────────────────────────────── */

/**
 * Dispatch a CustomEvent from a component.
 *
 * @param {object} cmp     the component — usually `this`
 * @param {string} name    event name; keep it lowercase, since HTML attribute names in a parent's
 *                         template are case-insensitive (`onitemselected`, not `onitemSelected`)
 * @param {*} [detail]     payload; the receiver reads it as `event.detail`
 * @param {object} [options] `{ bubbles, composed }` — needed only when the event must cross a
 *                         shadow boundary rather than be handled by the immediate parent
 */
export function fire(cmp, name, detail, options = {}) {
  const event = new CustomEvent(name, {
    detail,
    bubbles: !!options.bubbles,
    composed: !!options.composed
  });
  cmp.dispatchEvent(event);
  return event;
}

/* ── Toasts ─────────────────────────────────────────────────────────────────────────────────── */

/**
 * Show a toast notification.
 *
 * Never throws. From inside a lightning/modal on an Experience Cloud page the dispatch raises
 * instead of showing anything, and that used to take the rest of the calling handler with it — the
 * reload after a save, the close after a submit. Failures are logged and swallowed, so callers must
 * not treat a toast as delivered.
 *
 * @param {object} cmp        the component — usually `this`
 * @param {string} title
 * @param {string} [message]
 * @param {string} [variant]  info | success | warning | error
 * @param {string} [mode]     dismissable | pester | sticky
 */
export function toast(cmp, title, message, variant = "info", mode) {
  try {
    cmp.dispatchEvent(
      new ShowToastEvent({
        title,
        message,
        variant,
        // Errors stay until dismissed — they usually carry text worth reading.
        mode: mode || (variant === "error" ? "sticky" : "dismissable")
      })
    );
  } catch (e) {
    logError("utils.toast", e);
  }
}

/**
 * Show an error toast for whatever a catch block — or a component's error event — was handed.
 * Saves every caller from unpacking the error shape itself:
 *
 *   } catch (error) {
 *     toastError(this, error);
 *   }
 *
 * @param {object} cmp
 * @param {*} error
 * @param {string} [fallback]  shown when the error carries no readable message; worth passing
 *                             whenever the calling context can say something more useful than
 *                             "Unexpected error"
 * @param {string} [title]
 */
export function toastError(
  cmp,
  error,
  fallback = DEFAULT_ERROR,
  title = "Error"
) {
  toast(cmp, title, errorMessage(error, fallback), "error");
}

/* ── Messages from inside a modal ───────────────────────────────────────────────────────────── */

/**
 * Raise a message from a component that may be running inside a lightning/modal.
 *
 * A toast dispatched from inside a modal never reaches a handler: the framework renders the modal in
 * its overlay container, outside the opener's place in the DOM. The way through is for the opener to
 * pass a relay in (see toastRelay) and for the modal to expose it as `@api notifyOpener` — this then
 * prefers the relay and falls back to a plain toast when there is none, so the same component works
 * opened as a modal or dropped straight on a page.
 *
 *   // opener:  Modal.open({ ..., notifyOpener: toastRelay(this) })
 *   // modal:   @api notifyOpener;  ...  notify(this, "Saved", "Item added.", "success")
 *
 * @param {object} cmp        the component — usually `this`
 * @param {string} title
 * @param {string} [message]
 * @param {string} [variant]  info | success | warning | error
 */
export function notify(cmp, title, message, variant = "info") {
  if (cmp && typeof cmp.notifyOpener === "function") {
    cmp.notifyOpener({ title, message, variant });
    return;
  }
  // The relay is a property lookup by name, so a modal that spells it differently, or forgets the
  // @api, falls through to a toast that will never be seen. Complain rather than swallow it: a
  // component that can close itself is a lightning/modal, which is exactly where a toast goes
  // nowhere. Still toast afterwards — in an internal Lightning app it may well show.
  if (cmp && typeof cmp.close === "function") {
    logError(
      "utils.notify",
      `"${title}" was raised from a modal with no notifyOpener relay and will not be visible. ` +
        "Declare `@api notifyOpener` on the modal, and pass `notifyOpener: toastRelay(this)` when opening it."
    );
  }
  toast(cmp, title, message, variant);
}

/**
 * notify() for a caught error — the modal-safe counterpart of toastError.
 *
 * @param {object} cmp
 * @param {*} error
 * @param {string} [fallback]  shown when the error carries no readable message
 * @param {string} [title]
 */
export function notifyError(
  cmp,
  error,
  fallback = DEFAULT_ERROR,
  title = "Error"
) {
  notify(cmp, title, errorMessage(error, fallback), "error");
}

/**
 * Builds the callback a modal-opening component hands to notifyOpener. The returned function toasts
 * from `cmp`, which is on the page, so the message actually shows.
 *
 * @param {object} cmp  the opening component — usually `this`
 * @returns {function}  ({ title, message, variant }) => void
 */
export function toastRelay(cmp) {
  return ({ title, message, variant }) => toast(cmp, title, message, variant);
}

/* ── Errors ─────────────────────────────────────────────────────────────────────────────────── */

/**
 * Pull a readable message out of an error. Apex, LDS and plain JS all report failures in
 * different shapes, so callers should never reach into `.body` themselves.
 *
 * @param {*} error              a caught error, a wire adapter's `error`, or a string
 * @param {string} [fallback]    returned when nothing usable is found
 * @returns {string}
 */
export function errorMessage(error, fallback = DEFAULT_ERROR) {
  const messages = errorMessages(error);
  return messages.length ? messages.join(", ") : fallback;
}

/**
 * Every message an error carries, deduplicated. Use this instead of errorMessage() when the
 * messages are rendered as a list — a save can fail several field validations at once.
 *
 * @param {*} error
 * @returns {string[]}
 */
export function errorMessages(error) {
  const collected = [];

  const collect = (value) => {
    if (!value) return;

    if (Array.isArray(value)) {
      value.forEach(collect);
      return;
    }

    if (typeof value === "string") {
      collected.push(value);
      return;
    }

    const body = value.body || value;

    // Page-level errors from LDS come back as an array in the body.
    if (Array.isArray(body)) {
      collect(body);
      return;
    }

    // DML errors from a record-edit form: body.output.errors and body.output.fieldErrors.
    const output = body.output;
    if (output) {
      collect(output.errors);
      Object.values(output.fieldErrors || {}).forEach(collect);
    }

    // Record UI page/field errors.
    collect(body.pageErrors);
    Object.values(body.fieldErrors || {}).forEach(collect);

    // AuraHandledException and friends, then the raw JS error as a last resort.
    if (body.message) collected.push(body.message);
    else if (value.message) collected.push(value.message);
    else if (value.statusText) collected.push(value.statusText);
  };

  collect(error);

  return [...new Set(collected.filter((message) => !!message))];
}

/* ── Timing ─────────────────────────────────────────────────────────────────────────────────── */

/**
 * Wrap a function so it only runs once calls stop arriving for `wait` ms. For search boxes and
 * anything else where every keystroke would otherwise hit the server:
 *
 *   handleSearch = debounce((term) => this.search(term), 400);
 *
 * Assign it to a class field (as above) or create it in the constructor — a debounced function
 * created inside a handler is a brand new timer each call and debounces nothing.
 *
 * The returned function has a `cancel()`, which a component should call from
 * disconnectedCallback() if the pending work touches the DOM or fires an event.
 *
 * @param {Function} fn
 * @param {number} [wait]  milliseconds of quiet before `fn` runs
 * @returns {Function}     the debounced function, with `.cancel()` and `.flush()`
 */
export function debounce(fn, wait = DEFAULT_DEBOUNCE_MS) {
  let timeoutId;
  let pending;

  const debounced = function (...args) {
    pending = { context: this, args };
    clearTimeout(timeoutId);
    // Debouncing is the whole point of this helper, so the LWC rule against timers cannot apply.
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    timeoutId = setTimeout(() => {
      timeoutId = undefined;
      const call = pending;
      pending = undefined;
      fn.apply(call.context, call.args);
    }, wait);
  };

  /** Drop any pending call. Safe to call when nothing is pending. */
  debounced.cancel = () => {
    clearTimeout(timeoutId);
    timeoutId = undefined;
    pending = undefined;
  };

  /** Run a pending call now rather than waiting out the delay. */
  debounced.flush = () => {
    if (!pending) return;
    const call = pending;
    debounced.cancel();
    fn.apply(call.context, call.args);
  };

  return debounced;
}

/* ── Logging ────────────────────────────────────────────────────────────────────────────────── */

/**
 * Turn debug() output on or off for the whole page. Off by default, so debug() calls left in a
 * component stay silent in production. Flip it on from a component (usually behind a design
 * attribute) or straight from the browser console during development.
 *
 * @param {boolean} enabled
 */
export function setDebug(enabled) {
  debugEnabled = !!enabled;
}

/** @returns {boolean} whether debug() is currently logging. */
export function isDebug() {
  return debugEnabled;
}

/**
 * Log only when debugging is enabled.
 *
 * @param {string} source  the component or function doing the logging
 * @param {...*} args      anything console.log accepts
 */
export function debug(source, ...args) {
  if (!debugEnabled) return;
  console.log(`[${source}]`, ...args);
}

/**
 * A debug() bound to one source, so a component names itself once:
 *
 *   const log = debugFor("modal");
 *   log("submitting", this.recordId);
 *
 * @param {string} source
 * @returns {Function}
 */
export function debugFor(source) {
  return (...args) => debug(source, ...args);
}

/**
 * Log an error. Unlike debug() this always logs, because a swallowed error with no trace in the
 * console is the hardest kind of bug to chase.
 *
 * @param {string} source
 * @param {*} error
 */
export function logError(source, error) {
  console.error(`[${source}] ${errorMessage(error)}`, error);
}
/* ── Downloads ──────────────────────────────────────────────────────────────────────────────── */

/**
 * Base64 back into the bytes it encodes.
 *
 * Here because Apex is the only way a browser can read Salesforce file bytes - a fetch of the
 * file's own URL is refused cross-origin - and Apex hands them over base64 encoded. Anything
 * assembling bytes client-side needs this.
 *
 * atob yields a string of character codes rather than bytes, so they are copied out one at a
 * time. An explicit loop rather than Uint8Array.from with a mapping function, which allocates
 * an intermediate per character and on a file of any size is a great deal of garbage for
 * nothing.
 *
 * @param {string} encoded base64, as Apex encoded it
 * @returns {ArrayBuffer} the decoded bytes
 */
export function decodeBase64(encoded) {
  const binary = atob(encoded || "");
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

/**
 * Hand a file to the browser to save.
 *
 * **The blob's MIME type is not the file's type.** Lightning Web Security allows
 * URL.createObjectURL for only a small set of types, and text/csv is not among them - it fails
 * outright with "Unsupported MIME type". What actually names the file, and what the operating
 * system reads the type from, is the download attribute. So string content is wrapped as
 * text/plain regardless of what it really is.
 *
 * **Revoke on a later tick, never in the same turn as the click.** Pulling the blob away
 * immediately can beat the browser to reading it - Chrome usually survives it, Firefox and Safari
 * do not reliably.
 *
 * **Prefer an anchor from the caller's own template.** Passing one keeps the download inside the
 * component's DOM, which is the arrangement proven under LWS inside a community. Creating one
 * against document.body works in the internal app and is the fallback when no anchor is given.
 *
 * @param {Blob|string} data       the file's content
 * @param {string} filename        what to call it; this is what sets the name and the type
 * @param {object} [options]
 * @param {HTMLAnchorElement} [options.anchor] an anchor already in the caller's template
 * @param {string} [options.fallbackType] MIME type for a data-URL fallback when createObjectURL is
 *                                 blocked. Only worth setting for small text content - browsers cap
 *                                 data URLs at a few megabytes, so a large blob must fail loudly
 *                                 instead. Omit to disable the fallback.
 * @param {string} [options.source] label for the log line if the fallback is taken
 * @throws whatever createObjectURL threw, when no usable fallback is configured
 */
export function saveFile(data, filename, options = {}) {
  const { anchor, fallbackType, source = "utils.saveFile" } = options;
  const blob =
    data instanceof Blob ? data : new Blob([data], { type: "text/plain" });

  let url;
  try {
    url = URL.createObjectURL(blob);
  } catch (blocked) {
    // Only text content can become a data URL, and only usefully while it is small.
    if (!fallbackType || typeof data !== "string") {
      throw blocked;
    }
    logError(source, blocked);
    url = `data:${fallbackType},${encodeURIComponent(data)}`;
  }

  const target = anchor || document.createElement("a");
  const created = !anchor;
  if (created) {
    target.style.display = "none";
    document.body.appendChild(target);
  }

  target.download = filename;
  target.href = url;
  target.click();

  if (created) {
    document.body.removeChild(target);
  }
  if (url.startsWith("blob:")) {
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    setTimeout(() => URL.revokeObjectURL(url), 0);
  }
}
