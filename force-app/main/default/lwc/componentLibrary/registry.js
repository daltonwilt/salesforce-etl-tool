import dataExport from "./docDataExport";
import dataImport from "./docDataImport";

/**
 * Everything the component library documents. To add a component:
 *
 *   1. Build a runnable demo as its own bundle named example<Component>.
 *   2. Add a branch for it in componentLibraryExample.
 *   3. Write a doc<Component>.js here and list it below.
 *   4. Run `npm run snippets` so the Example tab shows the demo's source.
 *
 * A doc entry has:
 *   name, label, category, description, example, exampleNote?, module?, extends?
 *   documentation: [{ heading, body: [paragraph | { code } | { list: [...] }] }]
 *     Text in `backticks` renders as inline code.
 *   Specification tables, each optional: attributes, fieldOptions, methods, functions, events,
 *   columnTypes, stylingHooks.
 */

export const CATEGORIES = [
  { name: "import", label: "Import" },
  { name: "export", label: "Export" }
];

export const COMPONENTS = [dataImport, dataExport];
