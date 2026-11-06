/**
 * Copies the browser builds of third-party libraries from node_modules into static resources, so
 * the versions running in the org are exactly the ones pinned in package.json.
 *
 *   npm run vendor              rewrite the static resources
 *   npm run vendor -- --check   exit 1 if a static resource differs from node_modules
 *
 * To upgrade a library: change its version in package.json, `npm install`, `npm run vendor`.
 * The xlsx Jest suite runs the same comparison, so a bump without the copy fails the tests.
 */
const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const RESOURCES = path.join(ROOT, "force-app", "main", "default", "staticresources");

const LIBRARIES = [
  {
    resource: "exceljs",
    source: "node_modules/exceljs/dist/exceljs.min.js",
    description: "ExcelJS browser build, used by c/xlsx to write styled .xlsx workbooks."
  },
  {
    resource: "papaparse",
    source: "node_modules/papaparse/papaparse.min.js",
    description: "PapaParse browser build, used by c/csv to write CSV exports."
  },
  {
    resource: "jszip",
    source: "node_modules/jszip/dist/jszip.min.js",
    description: "JSZip browser build, used by c/export to bundle several export files into one zip."
  }
];

function versionOf(library) {
  const pkg = path.join(ROOT, "node_modules", library.resource, "package.json");
  return JSON.parse(fs.readFileSync(pkg, "utf8")).version;
}

function metaXml(library) {
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<StaticResource xmlns="http://soap.sforce.com/2006/04/metadata">',
    "    <cacheControl>Public</cacheControl>",
    "    <contentType>application/javascript</contentType>",
    `    <description>${library.description} Version ${versionOf(library)}, copied by scripts/vendor-libraries.js - do not edit.</description>`,
    "</StaticResource>",
    ""
  ].join("\n");
}

/** Each file a library needs in staticresources, with the content it should have. */
function expectedFiles() {
  return LIBRARIES.flatMap((library) => [
    {
      file: path.join(RESOURCES, `${library.resource}.js`),
      content: fs.readFileSync(path.join(ROOT, library.source))
    },
    {
      file: path.join(RESOURCES, `${library.resource}.resource-meta.xml`),
      content: Buffer.from(metaXml(library))
    }
  ]);
}

/** Paths, relative to the repo, of static resources that differ from node_modules. */
function staleFiles() {
  return expectedFiles()
    .filter(({ file, content }) => !fs.existsSync(file) || !fs.readFileSync(file).equals(content))
    .map(({ file }) => path.relative(ROOT, file));
}

function main() {
  if (process.argv.includes("--check")) {
    const stale = staleFiles();
    if (stale.length) {
      console.error(`Out of date: ${stale.join(", ")}. Run \`npm run vendor\`.`);
      process.exit(1);
    }
    return;
  }
  fs.mkdirSync(RESOURCES, { recursive: true });
  for (const { file, content } of expectedFiles()) {
    fs.writeFileSync(file, content);
    console.log("Wrote " + path.relative(ROOT, file));
  }
}

if (require.main === module) {
  main();
}

module.exports = { staleFiles, LIBRARIES };
