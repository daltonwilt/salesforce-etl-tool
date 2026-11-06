export default {
  name: "dataImport",
  label: "Data Import",
  category: "import",
  description:
    "Loads a CSV into any object from a configured template, with no limit on the number of rows. Bad rows come back in a file to fix and re-import.",
  example: "exampleDataImport",
  exampleNote:
    "This example creates or updates real Accounts, numbered DEMO-001 to DEMO-004, using the Example_Accounts template. Importing the file again updates the same records instead of duplicating them.",
  documentation: [
    {
      heading: "Overview",
      body: [
        "`c-data-import` is a file picker that loads a CSV into Salesforce records. A `Data_Import_Template__mdt` record decides where each column goes. The file is read and sliced in the browser and never reaches Apex whole, so a large file costs no more per row than a small one.",
        {
          code: '<c-data-import\n  template-name="Example_Accounts"\n  bindings={bindings}\n  onimported={handleImported}\n></c-data-import>'
        },
        "Without `template-name`, the user picks from the active templates."
      ]
    },
    {
      heading: "What happens to a file",
      body: [
        {
          list: [
            "The browser reads the file, checks its section boundaries and duplicate keys, and stages it in slices on a `Data_Import_Job__c` record.",
            "Apex checks the headings and the user's access to every mapped field, then a batch job writes the rows.",
            "The component polls the job and shows its progress. When the job ends it fires `imported` and offers the import record."
          ]
        },
        "Rows that fail come back as a CSV of just those rows, each with its reason, ready to fix and import again."
      ]
    },
    {
      heading: "Templates",
      body: [
        "A template's `Definition__c` is JSON. Columns are named by spreadsheet letter, not by heading, because headings are the part that gets reworded between versions of a form. Rows are numbered from one.",
        {
          code: '{\n  "label": "Example Accounts",\n  "mode": "Partial Success",\n  "sections": [\n    {\n      "type": "rows",\n      "target": "Account",\n      "headerRow": 1,\n      "firstDataRow": 2,\n      "expectHeader": { "A": "Account Name" },\n      "columns": { "A": "Name", "B": "AccountNumber" },\n      "matchOn": { "column": "B", "field": "AccountNumber" }\n    }\n  ]\n}'
        },
        {
          list: [
            "`mode`: `All or Nothing` (the default) writes nothing unless every row is valid. `Partial Success` keeps the good rows and hands back the rest.",
            "`expectHeader`: headings the file must have. A file with moved columns is refused before any row is written.",
            "`matchOn`: updates the record whose field matches the key column, and inserts when none does.",
            "`defaults`: values stamped on every record. `$name` reads from `bindings`.",
            "A `cells` section reads fixed addresses, such as a reporting period at the top of a form, and stamps them on every record."
          ]
        },
        "A template can hold several `rows` sections, each with its own target object and row range, for a file with more than one table."
      ]
    },
    {
      heading: "Access",
      body: [
        "Rows are written as the running user. Users need the `Data_Import_User` permission set, which grants `DataImportJob`, the templates, and the import job records, along with access to the objects and fields their templates write."
      ]
    }
  ],
  attributes: [
    {
      name: "template-name",
      type: "string",
      description: "Developer name of the Data_Import_Template__mdt to use. Leave blank to let the user choose."
    },
    {
      name: "bindings",
      type: "object",
      default: "{}",
      description: "Values the template's $name defaults resolve against, e.g. { reportId: recordId }."
    },
    {
      name: "label",
      type: "string",
      default: '"Import Data"',
      description: "Heading above the picker."
    }
  ],
  events: [
    {
      name: "imported",
      detail: "{ jobId, status, committed, failed }",
      description:
        "The import job finished. status is Completed, Failed, Aborted or Cancelled, and failed counts the rows handed back."
    }
  ]
};
