# salesforce-etl-tool

A Salesforce DX project.

## Prerequisites

- [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli)
- [Node.js](https://nodejs.org/) (version in `.nvmrc`)
- [VS Code](https://code.visualstudio.com/) with the [Salesforce Extension Pack](https://developer.salesforce.com/docs/platform/sfvscode-extensions/guide/install.html)
- A Salesforce org: a free [Developer Edition](https://developer.salesforce.com/signup) org, or a Dev Hub for scratch orgs

## Getting Started

```sh
git clone https://github.com/daltonwilt/salesforce-etl-tool.git
cd salesforce-etl-tool
npm install
```

### Deploy to an org

```sh
sf org login web --alias my-org
sf project deploy start --target-org my-org
```

### Or use a scratch org

```sh
sf org login web --set-default-dev-hub --alias devhub
sf org create scratch --definition-file config/project-scratch-def.json --alias scratch --set-default
sf project deploy start
sf org open
```

### Grant access

Deploying gives no one access to the import and export components, admins included. Assign the permission sets to each user who needs them:

```sh
sf org assign permset --name Data_Import_User --name Data_Export_User --target-org my-org
```

| Permission set | Grants |
| --- | --- |
| `Data_Import_User` | `DataImportJob`, the import templates, and the `Data_Import_Job__c` and `Data_Import_Chunk__c` records and fields |
| `Data_Export_User` | `DataExport` and the export configuration |

Both read and write records as the user, so users also need access to the objects and fields being imported or exported.

## Project Structure

| Path                              | Contents                     |
| --------------------------------- | ---------------------------- |
| `force-app/main/default/`         | Metadata source              |
| `config/project-scratch-def.json` | Scratch org definition       |
| `manifest/package.xml`            | Metadata manifest            |
| `scripts/`                        | Sample Apex and SOQL scripts |
| `jest-mocks/`                     | Jest mocks for base modules  |

## Data Export

`c-data-export` is a button that downloads Salesforce records as styled Excel workbooks or CSV files. Users pick the format from its menu. Each export is configured in custom metadata:

- **`Data_Export__mdt`**: one export, the value passed as `export-name`. An optional `Zip File Name` bundles several files into one download, and `Styles` (JSON) styles every Excel sheet.
- **`Data_Export_Sheet__mdt`**: one table. Set the object, its `Fields` (`Name, Owner.Name AS Owner`), an optional SOQL `Filter` (`:recordId` and `:userId` are available), `Order By` and `Row Limit`. Sheets with the same `File Name` share an Excel workbook. In CSV, every sheet is its own file.

```html
<c-data-export export-name="Example_Account_Overview" record-id={recordId}></c-data-export>
```

The component can also be placed on record, app and home pages from Lightning App Builder. Records are read as the running user (with sharing, in user mode), and the files are built in the browser. `Example_Account_Overview` is a sample export of accounts, contacts and open opportunities.

| Bundle | Role |
| --- | --- |
| `dataExport` | The button: fetches each sheet from `DataExport`, then builds and downloads the files |
| `xlsx` | Excel workbooks and styling, with ExcelJS |
| `csv` | CSV files, with PapaParse |
| `export` | What both formats share: library loading, value and time zone conversion, zipping (JSZip) |
| `utils` | Shared LWC helpers (error messages, logging, file downloads, toasts), copied from salesforce-component-library |

ExcelJS, PapaParse and JSZip are static resources copied from `node_modules`. Their versions are pinned in `package.json`. To upgrade one, change its version, run `npm install`, then `npm run vendor`. The Jest suite fails if the static resources fall out of step.

## Development

| Command                      | Description                              |
| ---------------------------- | ---------------------------------------- |
| `npm run lint`               | Lint Aura and LWC JavaScript with ESLint |
| `npm test`                   | Run LWC Jest unit tests                  |
| `npm run test:unit:watch`    | Run Jest tests in watch mode             |
| `npm run test:unit:coverage` | Run Jest tests with a coverage report    |
| `npm run vendor`             | Copy pinned libraries into static resources |

A pre-commit hook (Husky + lint-staged) lints and tests staged LWC files automatically.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to get started, and please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Security

Please do not report security vulnerabilities through public issues. See [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
