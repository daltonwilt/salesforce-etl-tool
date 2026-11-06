import { LightningElement, wire } from "lwc";
import { CurrentPageReference, NavigationMixin } from "lightning/navigation";
import { CATEGORIES, COMPONENTS } from "./registry";
import SNIPPETS from "./snippets";

/**
 * Reference documentation for this library, laid out like the Salesforce component reference:
 * a component list on the left and, for the selected component, Example, Documentation and
 * Specification tabs.
 *
 * Drop it on a Lightning App Page or a Lightning Component Tab. The selection is kept in the URL
 * as c__component and c__tab, so a link opens the same component on the same tab.
 *
 * The content lives in the doc*.js modules next to this file (see registry.js), and the example
 * code comes from the example* bundles through the generated snippets.js.
 */

const TABS = [
  { value: "example", label: "Example" },
  { value: "documentation", label: "Documentation" },
  { value: "specification", label: "Specification" }
];

const TAB_VALUES = new Set(TABS.map((tab) => tab.value));

/** Specification tables, in the order they are shown. Each reads the doc entry key of its name. */
const ATTRIBUTE_COLUMNS = [
  { field: "name", label: "Name", code: true },
  { field: "description", label: "Description" },
  { field: "type", label: "Type", code: true },
  { field: "default", label: "Default", code: true },
  { field: "required", label: "Required" }
];
const FUNCTION_COLUMNS = [
  { field: "name", label: "Name", code: true },
  { field: "arguments", label: "Arguments", code: true },
  { field: "returns", label: "Returns", code: true },
  { field: "description", label: "Description" }
];

const SPEC_TABLES = [
  { key: "attributes", title: "Attributes", columns: ATTRIBUTE_COLUMNS },
  {
    key: "fieldOptions",
    title: "Field options",
    columns: ATTRIBUTE_COLUMNS
  },
  {
    key: "methods",
    title: "Methods",
    columns: [
      { field: "name", label: "Name", code: true },
      { field: "returns", label: "Returns", code: true },
      { field: "description", label: "Description" }
    ]
  },
  { key: "functions", title: "Functions", columns: FUNCTION_COLUMNS },
  {
    key: "columnTypes",
    title: "Column types",
    columns: [
      { field: "name", label: "Type", code: true },
      { field: "typeAttributes", label: "Type attributes", code: true },
      { field: "description", label: "Description" }
    ]
  },
  {
    key: "events",
    title: "Events",
    columns: [
      { field: "name", label: "Name", code: true },
      { field: "detail", label: "Detail", code: true },
      { field: "description", label: "Description" }
    ]
  },
  {
    key: "stylingHooks",
    title: "Styling hooks",
    columns: [
      { field: "name", label: "Name", code: true },
      { field: "description", label: "Description" }
    ]
  }
];

const BY_NAME = new Map(COMPONENTS.map((doc) => [doc.name, doc]));

export default class ComponentLibrary extends NavigationMixin(LightningElement) {
  selectedName = COMPONENTS[0].name;
  activeTab = TABS[0].value;
  searchTerm = "";
  _pageRef;

  /**
   * Opens the component and tab the URL names. Fires again after every navigation, including
   * the ones this component makes, which is harmless: it sets what is already set.
   */
  @wire(CurrentPageReference)
  handlePageReference(pageRef) {
    this._pageRef = pageRef;
    const state = (pageRef && pageRef.state) || {};
    if (BY_NAME.has(state.c__component)) {
      this.selectedName = state.c__component;
    }
    if (TAB_VALUES.has(state.c__tab)) {
      this.activeTab = state.c__tab;
    }
  }

  /* ── Navigation ───────────────────────────────────────────────────────────────────── */

  get navSections() {
    const term = this.searchTerm.trim().toLowerCase();
    const matches = (doc) =>
      !term ||
      doc.label.toLowerCase().includes(term) ||
      doc.name.toLowerCase().includes(term) ||
      doc.description.toLowerCase().includes(term);

    return CATEGORIES.map((category) => ({
      key: category.name,
      label: category.label,
      items: COMPONENTS.filter(
        (doc) => doc.category === category.name && matches(doc)
      ).map((doc) => ({ name: doc.name, label: doc.label }))
    })).filter((section) => section.items.length > 0);
  }

  get hasNavResults() {
    return this.navSections.length > 0;
  }

  handleSearch(event) {
    this.searchTerm = event.target.value || "";
  }

  handleSelect(event) {
    const name = event.detail.name;
    if (!BY_NAME.has(name) || name === this.selectedName) {
      return;
    }
    this.selectedName = name;
    // A new component opens on its example, as the Salesforce reference does.
    this.activeTab = TABS[0].value;
    this.syncUrl();
  }

  handleTabActive(event) {
    const value = event.target.value;
    // lightning-tabset also fires `active` for the tab it opens on; only a change is news.
    if (value === this.activeTab) {
      return;
    }
    this.activeTab = value;
    this.syncUrl();
  }

  /** Writes the selection into the URL, replacing the history entry rather than adding one. */
  syncUrl() {
    if (!this._pageRef) {
      return;
    }
    this[NavigationMixin.Navigate](
      {
        ...this._pageRef,
        state: {
          ...this._pageRef.state,
          c__component: this.selectedName,
          c__tab: this.activeTab
        }
      },
      true
    );
  }

  /* ── Selected component ───────────────────────────────────────────────────────────── */

  get doc() {
    return BY_NAME.get(this.selectedName);
  }

  /** How the component is used: its tag, or its import for a service module. */
  get usage() {
    const doc = this.doc;
    return doc.module
      ? `import { … } from "c/${doc.name}";`
      : `<c-${kebabCase(doc.name)}>`;
  }

  get sourcePath() {
    return `force-app/main/default/lwc/${this.doc.name}`;
  }

  get exampleFiles() {
    return SNIPPETS[this.doc.example] || [];
  }

  get documentationSections() {
    return (this.doc.documentation || []).map((section, sectionIndex) => ({
      key: `section-${sectionIndex}`,
      heading: section.heading,
      blocks: (section.body || []).map((block, blockIndex) =>
        toBlock(block, `${sectionIndex}-${blockIndex}`)
      )
    }));
  }

  get specTables() {
    const doc = this.doc;
    return SPEC_TABLES.filter(
      (table) => Array.isArray(doc[table.key]) && doc[table.key].length > 0
    ).map((table) => ({
      key: table.key,
      title: table.title,
      columns: table.columns,
      rows: doc[table.key].map((row, rowIndex) => ({
        key: `${table.key}-${rowIndex}`,
        cells: table.columns.map((column) => {
          const value = formatCell(row[column.field]);
          return {
            key: column.field,
            value,
            isCode: !!column.code && value !== ""
          };
        })
      }))
    }));
  }

  get hasSpecTables() {
    return this.specTables.length > 0;
  }
}

/* ── Helpers ─────────────────────────────────────────────────────────────────────────── */

function kebabCase(name) {
  return name.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);
}

function formatCell(value) {
  if (value === true) return "Yes";
  if (value === false || value === undefined || value === null) return "";
  return String(value);
}

/**
 * Splits text on backticks into plain and code runs, so documentation can mark inline code
 * the way Markdown does without the page having to render HTML from a string.
 */
function toSegments(text) {
  return String(text)
    .split("`")
    .map((part, index) => ({ key: index, text: part, isCode: index % 2 === 1 }))
    .filter((segment) => segment.text !== "");
}

function toBlock(block, key) {
  if (typeof block === "string") {
    return { key, isParagraph: true, segments: toSegments(block) };
  }
  if (block.code !== undefined) {
    return { key, isCode: true, code: block.code };
  }
  if (Array.isArray(block.list)) {
    return {
      key,
      isList: true,
      items: block.list.map((item, index) => ({
        key: index,
        segments: toSegments(item)
      }))
    };
  }
  return { key, isParagraph: true, segments: [] };
}
