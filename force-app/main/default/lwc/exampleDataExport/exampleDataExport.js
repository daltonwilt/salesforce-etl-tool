import { LightningElement } from "lwc";

// Columns and rows in the shape lightning-datatable takes.
const COLUMNS = [
  { label: "Invoice", fieldName: "number" },
  { label: "Customer", fieldName: "customer" },
  { label: "Due", fieldName: "due", type: "date" },
  { label: "Amount", fieldName: "amount", type: "currency" },
  { label: "Paid", fieldName: "paid", type: "boolean" }
];

const ROWS = [
  { number: "INV-1001", customer: "Example Robotics", due: "2026-11-30", amount: 1250, paid: false },
  { number: "INV-1002", customer: "Example Foods", due: "2026-12-15", amount: 480.5, paid: true },
  { number: "INV-1003", customer: "Example Freight", due: "2026-12-31", amount: 9800, paid: false }
];

export default class ExampleDataExport extends LightningElement {
  workbooks = [
    {
      name: "Invoices",
      sheets: [
        {
          name: "Open invoices",
          columns: COLUMNS,
          rows: ROWS,
          style: { tabColor: "FF0B5CAB", columns: { amount: { width: 14 } } }
        }
      ]
    }
  ];

  summary;

  handleExported(event) {
    const { format, files, rows } = event.detail;
    this.summary = `Downloaded ${rows} rows as ${format}, in ${files} file(s).`;
  }

  handleError(event) {
    this.summary = event.detail.message;
  }
}
