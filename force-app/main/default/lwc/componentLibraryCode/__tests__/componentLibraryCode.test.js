import { createElement } from "@lwc/engine-dom";
import ComponentLibraryCode from "c/componentLibraryCode";

const FILES = [
  { name: "demo.html", language: "HTML", source: "<template></template>" },
  { name: "demo.js", language: "JavaScript", source: "export default 1;" }
];

const flush = () => Promise.resolve();

function render(files = FILES) {
  const element = createElement("c-component-library-code", {
    is: ComponentLibraryCode
  });
  element.files = files;
  document.body.appendChild(element);
  return element;
}

const copyButtons = (element) => [
  ...element.shadowRoot.querySelectorAll("lightning-button-icon")
];

describe("c-component-library-code", () => {
  const originalClipboard = navigator.clipboard;

  function mockClipboard(writeText) {
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText },
      configurable: true
    });
  }

  beforeEach(() => {
    jest.useFakeTimers();
    jest.spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    Object.defineProperty(navigator, "clipboard", {
      value: originalClipboard,
      configurable: true
    });
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  it("shows one tab per file with its source", () => {
    const element = render();
    const tabs = [...element.shadowRoot.querySelectorAll("lightning-tab")];
    expect(tabs.map((tab) => tab.label)).toEqual(["demo.html", "demo.js"]);
    const sources = [...element.shadowRoot.querySelectorAll("pre code")];
    expect(sources.map((code) => code.textContent)).toEqual([
      "<template></template>",
      "export default 1;"
    ]);
  });

  it("renders nothing without files", () => {
    const element = render([]);
    expect(element.shadowRoot.querySelector("lightning-tabset")).toBeNull();
  });

  it("copies a file's source and confirms on that button only", async () => {
    const writeText = jest.fn().mockResolvedValue();
    mockClipboard(writeText);
    const element = render();

    copyButtons(element)[1].click();
    await flush();
    await flush();

    expect(writeText).toHaveBeenCalledWith("export default 1;");
    const [first, second] = copyButtons(element);
    expect(second.iconName).toBe("utility:check");
    expect(second.alternativeText).toBe("Copied");
    expect(first.iconName).toBe("utility:copy");

    jest.advanceTimersByTime(2000);
    await flush();
    expect(copyButtons(element)[1].iconName).toBe("utility:copy");
  });

  it("reports a refused copy on the button instead of throwing", async () => {
    mockClipboard(jest.fn().mockRejectedValue(new Error("denied")));
    const element = render();

    copyButtons(element)[0].click();
    await flush();
    await flush();

    expect(copyButtons(element)[0].iconName).toBe("utility:error");
  });
});
