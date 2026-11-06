import {
  fire,
  toast,
  toastError,
  notify,
  notifyError,
  toastRelay,
  errorMessage,
  errorMessages,
  debounce,
  setDebug,
  isDebug,
  debug,
  debugFor,
  logError,
  decodeBase64,
  saveFile
} from "c/utils";

const component = (extra = {}) => ({ dispatchEvent: jest.fn(), ...extra });
const dispatched = (cmp) => cmp.dispatchEvent.mock.calls.map(([e]) => e);

beforeEach(() => {
  jest.spyOn(console, "error").mockImplementation(() => {});
  jest.spyOn(console, "log").mockImplementation(() => {});
});

afterEach(() => {
  jest.restoreAllMocks();
  jest.useRealTimers();
  setDebug(false);
});

describe("fire", () => {
  it("dispatches a non-bubbling CustomEvent by default", () => {
    const cmp = component();
    const event = fire(cmp, "change", { value: 1 });

    expect(dispatched(cmp)).toEqual([event]);
    expect(event).toBeInstanceOf(CustomEvent);
    expect(event).toMatchObject({
      type: "change",
      detail: { value: 1 },
      bubbles: false,
      composed: false
    });
  });

  it("passes bubbles and composed through", () => {
    const event = fire(component(), "select", null, {
      bubbles: true,
      composed: true
    });
    expect(event).toMatchObject({ bubbles: true, composed: true });
  });
});

describe("toast", () => {
  it.each([
    [
      "an info, dismissable toast by default",
      ["Saved"],
      { variant: "info", mode: "dismissable" }
    ],
    [
      "a sticky error toast",
      ["Oops", "Failed", "error"],
      { variant: "error", mode: "sticky" }
    ],
    [
      "the mode it is given",
      ["Hi", "Msg", "warning", "pester"],
      { variant: "warning", mode: "pester" }
    ]
  ])("shows %s", (_, args, expected) => {
    const cmp = component();
    toast(cmp, ...args);

    const [event] = dispatched(cmp);
    expect(event.type).toBe("lightning__showtoast");
    expect(event.detail).toMatchObject({ title: args[0], ...expected });
  });

  it("logs instead of throwing when the dispatch fails", () => {
    const cmp = component({
      dispatchEvent: () => {
        throw new Error("blocked");
      }
    });

    expect(() => toast(cmp, "Saved")).not.toThrow();
    expect(console.error).toHaveBeenCalledWith(
      "[utils.toast] blocked",
      expect.any(Error)
    );
  });

  it("toastError shows a sticky error toast with the error's message", () => {
    const cmp = component();
    toastError(cmp, { body: { message: "Insufficient access" } });

    expect(dispatched(cmp)[0].detail).toEqual({
      title: "Error",
      message: "Insufficient access",
      variant: "error",
      mode: "sticky"
    });
  });

  it("toastError falls back when the error has no message", () => {
    const cmp = component();
    toastError(cmp, {}, "Could not save", "Save failed");

    expect(dispatched(cmp)[0].detail).toMatchObject({
      title: "Save failed",
      message: "Could not save"
    });
  });
});

describe("notify", () => {
  it("uses the opener's relay when there is one", () => {
    const cmp = component({ notifyOpener: jest.fn() });
    notify(cmp, "Saved", "Item added.", "success");

    expect(cmp.notifyOpener).toHaveBeenCalledWith({
      title: "Saved",
      message: "Item added.",
      variant: "success"
    });
    expect(cmp.dispatchEvent).not.toHaveBeenCalled();
  });

  it("toasts when there is no relay", () => {
    const cmp = component();
    notify(cmp, "Saved");

    expect(dispatched(cmp)[0].detail).toMatchObject({
      title: "Saved",
      variant: "info"
    });
    expect(console.error).not.toHaveBeenCalled();
  });

  it("warns, then toasts, from a modal with no relay", () => {
    const cmp = component({ close: jest.fn() });
    notify(cmp, "Saved");

    expect(console.error).toHaveBeenCalledWith(
      expect.stringContaining("no notifyOpener relay"),
      expect.anything()
    );
    expect(cmp.dispatchEvent).toHaveBeenCalledTimes(1);
  });

  it("notifyError relays the error's message as an error", () => {
    const cmp = component({ notifyOpener: jest.fn() });
    notifyError(cmp, new Error("Timed out"));

    expect(cmp.notifyOpener).toHaveBeenCalledWith({
      title: "Error",
      message: "Timed out",
      variant: "error"
    });
  });

  it("toastRelay toasts from the opener", () => {
    const opener = component();
    toastRelay(opener)({ title: "Saved", message: "Done", variant: "success" });

    expect(dispatched(opener)[0].detail).toMatchObject({
      title: "Saved",
      message: "Done",
      variant: "success"
    });
  });
});

describe("errorMessages", () => {
  it.each([
    ["a string", "Plain", ["Plain"]],
    ["a JS error", new Error("Boom"), ["Boom"]],
    ["an Apex error", { body: { message: "Apex failed" } }, ["Apex failed"]],
    [
      "LDS page-level errors",
      { body: [{ message: "First" }, { message: "Second" }] },
      ["First", "Second"]
    ],
    [
      "record-edit DML errors",
      {
        body: {
          output: {
            errors: [{ message: "Duplicate" }],
            fieldErrors: { Name: [{ message: "Name is required" }] }
          }
        }
      },
      ["Duplicate", "Name is required"]
    ],
    [
      "record UI page and field errors",
      {
        body: {
          pageErrors: [{ message: "Locked" }],
          fieldErrors: { Email: [{ message: "Invalid email" }] }
        }
      },
      ["Locked", "Invalid email"]
    ],
    ["an HTTP status", { statusText: "Not Found" }, ["Not Found"]],
    [
      "an array of errors, de-duplicated",
      ["Same", "Same", "Other"],
      ["Same", "Other"]
    ],
    ["nothing", null, []],
    ["an object with no message", {}, []]
  ])("reads %s", (_, error, expected) => {
    expect(errorMessages(error)).toEqual(expected);
  });

  it("prefers body.message over the outer message", () => {
    expect(
      errorMessages({ message: "Outer", body: { message: "Inner" } })
    ).toEqual(["Inner"]);
  });
});

describe("errorMessage", () => {
  it("joins every message", () => {
    expect(errorMessage(["One", "Two"])).toBe("One, Two");
  });

  it.each([
    ["the default", undefined, "Unexpected error"],
    ["a given", "Custom fallback", "Custom fallback"]
  ])("falls back to %s message", (_, fallback, expected) => {
    expect(errorMessage({}, fallback)).toBe(expected);
  });
});

describe("debounce", () => {
  beforeEach(() => jest.useFakeTimers());

  it("runs once, after the wait, with the last call's args and context", () => {
    const fn = jest.fn();
    const target = { search: debounce(fn, 400) };

    target.search("a");
    jest.advanceTimersByTime(399);
    target.search("ab");
    jest.advanceTimersByTime(399);
    expect(fn).not.toHaveBeenCalled();

    jest.advanceTimersByTime(1);
    expect(fn).toHaveBeenCalledTimes(1);
    expect(fn).toHaveBeenCalledWith("ab");
    expect(fn.mock.contexts[0]).toBe(target);
  });

  it("waits 300ms by default", () => {
    const fn = jest.fn();
    debounce(fn)();

    jest.advanceTimersByTime(299);
    expect(fn).not.toHaveBeenCalled();
    jest.advanceTimersByTime(1);
    expect(fn).toHaveBeenCalled();
  });

  it("cancel drops the pending call", () => {
    const fn = jest.fn();
    const debounced = debounce(fn);

    debounced();
    debounced.cancel();
    jest.runAllTimers();

    expect(fn).not.toHaveBeenCalled();
  });

  it("flush runs the pending call now, and only once", () => {
    const fn = jest.fn();
    const debounced = debounce(fn);

    debounced.flush();
    expect(fn).not.toHaveBeenCalled();

    debounced("now");
    debounced.flush();
    jest.runAllTimers();

    expect(fn).toHaveBeenCalledTimes(1);
    expect(fn).toHaveBeenCalledWith("now");
  });
});

describe("logging", () => {
  it("debug is silent until enabled", () => {
    debug("cmp", "hidden");
    expect(isDebug()).toBe(false);
    expect(console.log).not.toHaveBeenCalled();

    setDebug(true);
    debug("cmp", "shown", 1);
    expect(isDebug()).toBe(true);
    expect(console.log).toHaveBeenCalledWith("[cmp]", "shown", 1);
  });

  it("debugFor binds the source", () => {
    setDebug(true);
    debugFor("myCmp")("hello");
    expect(console.log).toHaveBeenCalledWith("[myCmp]", "hello");
  });

  it("logError always logs, with the readable message", () => {
    const error = { body: { message: "Apex failed" } };
    logError("cmp", error);
    expect(console.error).toHaveBeenCalledWith("[cmp] Apex failed", error);
  });
});

describe("decodeBase64", () => {
  it("decodes to the original bytes", () => {
    const bytes = new Uint8Array(decodeBase64(btoa("Hiÿ")));
    expect([...bytes]).toEqual([72, 105, 255]);
  });

  it.each([null, ""])("returns an empty buffer for %p", (encoded) => {
    expect(decodeBase64(encoded).byteLength).toBe(0);
  });
});

describe("saveFile", () => {
  let clicks;

  beforeEach(() => {
    jest.useFakeTimers();
    URL.createObjectURL = jest.fn(() => "blob:mock");
    URL.revokeObjectURL = jest.fn();
    clicks = [];
    jest
      .spyOn(HTMLAnchorElement.prototype, "click")
      .mockImplementation(function () {
        clicks.push({
          download: this.download,
          href: this.href,
          inDocument: document.body.contains(this)
        });
      });
  });

  afterEach(() => {
    delete URL.createObjectURL;
    delete URL.revokeObjectURL;
  });

  it("downloads string content as text/plain and cleans up", () => {
    saveFile("a,b", "report.csv");

    expect(URL.createObjectURL.mock.calls[0][0].type).toBe("text/plain");
    expect(clicks).toEqual([
      { download: "report.csv", href: "blob:mock", inDocument: true }
    ]);
    expect(document.body.children).toHaveLength(0);

    expect(URL.revokeObjectURL).not.toHaveBeenCalled();
    jest.runAllTimers();
    expect(URL.revokeObjectURL).toHaveBeenCalledWith("blob:mock");
  });

  it("uses the caller's anchor and keeps a Blob's own type", () => {
    const anchor = document.createElement("a");
    saveFile(new Blob(["x"], { type: "application/pdf" }), "a.pdf", {
      anchor
    });

    expect(URL.createObjectURL.mock.calls[0][0].type).toBe("application/pdf");
    expect(anchor.download).toBe("a.pdf");
    expect(clicks[0].inDocument).toBe(false);
  });

  it("falls back to a data URL when blob URLs are blocked", () => {
    URL.createObjectURL.mockImplementation(() => {
      throw new Error("Unsupported MIME type");
    });

    saveFile("a,b", "report.csv", { fallbackType: "text/csv", source: "cmp" });

    expect(clicks[0].href).toBe("data:text/csv,a%2Cb");
    expect(console.error).toHaveBeenCalledWith(
      "[cmp] Unsupported MIME type",
      expect.any(Error)
    );
    jest.runAllTimers();
    expect(URL.revokeObjectURL).not.toHaveBeenCalled();
  });

  it.each([
    ["no fallback type is set", "a,b", {}],
    ["the content is a Blob", new Blob(["x"]), { fallbackType: "text/csv" }]
  ])("rethrows when blob URLs are blocked and %s", (_, data, options) => {
    URL.createObjectURL.mockImplementation(() => {
      throw new Error("Unsupported MIME type");
    });

    expect(() => saveFile(data, "file", options)).toThrow(
      "Unsupported MIME type"
    );
    expect(clicks).toHaveLength(0);
  });
});
