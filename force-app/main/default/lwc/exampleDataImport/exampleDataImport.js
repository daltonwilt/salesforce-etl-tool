import { LightningElement } from "lwc";
import { saveFile } from "c/utils";

// Account numbers match existing records, so importing the file again updates them.
const SAMPLE_CSV = [
  "Account Name,Account Number,Industry,Employees,Website",
  "Example Robotics,DEMO-001,Technology,120,https://example.com",
  "Example Foods,DEMO-002,Food & Beverage,45,",
  "Example Freight,DEMO-003,Transportation,lots,",
  "Example Clinic,DEMO-004,Healthcare,18,"
].join("\r\n");

export default class ExampleDataImport extends LightningElement {
  result;

  handleDownloadSample() {
    saveFile(SAMPLE_CSV, "example-accounts.csv", {
      anchor: this.template.querySelector("a.sample-download"),
      fallbackType: "text/csv;charset=utf-8",
      source: "exampleDataImport"
    });
  }

  handleImported(event) {
    this.result = event.detail;
  }
}
