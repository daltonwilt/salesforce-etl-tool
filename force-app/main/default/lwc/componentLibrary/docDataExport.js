export default {
  name: "dataExport",
  label: "Data Export",
  category: "export",
  description:
    "A button that downloads Salesforce data as styled Excel workbooks or CSV files, laid out by custom metadata or by the host's own rows.",
  example: "exampleDataExport",
  exampleNote:
    "The first button reads real accounts, contacts and open opportunities as you. The second builds its workbook from rows in the example itself and calls no Apex.",
  documentation: [
    {
      heading: "Overview",
      body: [
        "`c-data-export` is a button that downloads data as Excel (`.xlsx`) or CSV. The user picks the format from its menu, or `formats` offers one. The files are built in the browser, so nothing is left behind in the org.",
        {
          code: '<c-data-export export-name="Example_Account_Overview" record-id={recordId}></c-data-export>'
        }
      ]
    },
    {
      heading: "Configuring an export",
      body: [
        "`export-name` is the developer name of a `Data_Export__mdt` record. Each of its `Data_Export_Sheet__mdt` records is one table:",
        {
          list: [
            "`Object_API_Name__c`: the object the sheet lists.",
            "`Fields__c`: the columns, in order. Paths through lookups work, and `AS` sets a header: `Name, Owner.Name AS Owner`.",
            "`Filter__c`: a SOQL `WHERE` clause without the word `WHERE`. `:recordId` is the record the component is on, and `:userId` is the running user.",
            "`Order_By__c` and `Row_Limit__c`: the row limit defaults to 10,000 and can be raised to 50,000. A sheet that hits its limit stops there, and the user is told.",
            "`File_Name__c` and `Sort_Order__c`: sheets with the same file name share one Excel workbook, in sort order. As CSV, every sheet is its own file."
          ]
        },
        "On the export, `Zip_File_Name__c` bundles several files into one download. `{date}` in it becomes today's date."
      ]
    },
    {
      heading: "Exporting the page's own data",
      body: [
        "With no `export-name`, the button downloads `workbooks` instead: columns and rows in the shape `lightning-datatable` takes. No configuration or Apex is involved.",
        {
          code: 'workbooks = [\n  {\n    name: "Invoices",\n    sheets: [{ name: "Open", columns, rows, style: { tabColor: "FF0B5CAB" } }]\n  }\n];'
        },
        "For data that only exists once the user asks for it, call `downloadWorkbooks()` from script instead."
      ]
    },
    {
      heading: "Styling Excel files",
      body: [
        "A style object sets the header and body cells, banded rows, column widths, conditional formatting, frozen headers, filters and tab colour. Cell styles are ExcelJS style objects. Styles merge in order, later winning: the defaults, then the export's `Styles__c` (or `downloadWorkbooks()`'s `style` option), then the workbook's, then the sheet's.",
        {
          code: '{\n  "header": { "fill": { "type": "pattern", "pattern": "solid", "fgColor": { "argb": "FF032D60" } } },\n  "alternateRows": null,\n  "columns": { "Amount": { "width": 14, "numFmt": "#,##0.00" } }\n}'
        },
        "CSV files have no styling, so styles are ignored there."
      ]
    },
    {
      heading: "Access",
      body: [
        "Records are read as the running user, with sharing and in user mode, so a user can export only what they can already see. Users need the `Data_Export_User` permission set, which grants the `DataExport` class and the export configuration, along with access to the objects and fields being exported."
      ]
    },
    {
      heading: "Messages",
      body: [
        "Progress and the result are shown next to the button and fired as `exported` and `exporterror` events, not raised as toasts. This means the component also works inside a modal, where a toast never reaches the screen."
      ]
    }
  ],
  attributes: [
    {
      name: "export-name",
      type: "string",
      description:
        "Developer name of the Data_Export__mdt to download. Leave blank to download workbooks instead."
    },
    {
      name: "record-id",
      type: "string",
      description: "Bound as :recordId in each sheet's filter. Set automatically on a record page."
    },
    {
      name: "formats",
      type: "string",
      default: '"both"',
      description: 'both shows a menu of Excel and CSV. "excel" or "csv" shows a single button for that format.'
    },
    {
      name: "label",
      type: "string",
      default: '"Export"',
      description: 'The button label. With a single format it defaults to "Export to Excel" or "Export to CSV".'
    },
    {
      name: "variant",
      type: "string",
      default: '"neutral"',
      description: "lightning-button variant of the single-format button. The format menu is always neutral."
    },
    {
      name: "disabled",
      type: "boolean",
      default: "false",
      description: "Disables the button."
    },
    {
      name: "workbooks",
      type: "object[]",
      description: "The host's own data, downloaded when there is no export-name."
    },
    {
      name: "zip-file-name",
      type: "string",
      description: "With workbooks: bundles several files into one zip with this name."
    }
  ],
  methods: [
    {
      name: "download(format)",
      returns: "Promise<object | null>",
      description:
        "Downloads the configured export, or workbooks when there is no export-name. Resolves with what was downloaded, or null on failure, which is shown and fired as exporterror."
    },
    {
      name: "downloadWorkbooks(workbooks, options)",
      returns: "Promise<object | null>",
      description:
        "Downloads workbooks built from data the host already has. options: format, zipFileName and style."
    }
  ],
  events: [
    {
      name: "exported",
      detail: "{ format, files, zipped, sheets, rows, truncated }",
      description: "The files were downloaded. truncated lists the sheets that stopped at their row limit."
    },
    {
      name: "exporterror",
      detail: "{ message }",
      description: "The export failed. Nothing was downloaded."
    }
  ]
};
