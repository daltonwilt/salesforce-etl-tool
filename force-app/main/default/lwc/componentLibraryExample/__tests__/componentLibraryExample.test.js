import { createElement } from "@lwc/engine-dom";
import ComponentLibraryExample from "c/componentLibraryExample";
import { COMPONENTS } from "../../componentLibrary/registry";

function render(name) {
  const element = createElement("c-component-library-example", {
    is: ComponentLibraryExample
  });
  element.name = name;
  document.body.appendChild(element);
  return element;
}

const kebab = (name) =>
  name.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);

describe("c-component-library-example", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  // Doubles as a smoke test: each example has to construct and render to be found.
  it.each(COMPONENTS.map((doc) => [doc.name, doc.example]))(
    "renders the %s example",
    (_, example) => {
      const element = render(example);
      const tag = `c-${kebab(example)}`;
      expect(element.shadowRoot.querySelector(tag)).not.toBeNull();
      expect(element.shadowRoot.children).toHaveLength(1);
    }
  );

  it("says so when there is no example by that name", () => {
    const element = render("exampleMissing");
    expect(element.shadowRoot.textContent).toContain(
      "No example for exampleMissing."
    );
  });
});
