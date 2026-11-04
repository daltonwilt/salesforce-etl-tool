# sfdx-project-template

A Salesforce DX project.

<!-- template:start -->

## Using This Template

This repository is a GitHub template for new Salesforce DX projects. It includes linting, formatting, Jest tests, CI, Dependabot, issue and pull request templates, and community health files.

GitHub templates copy files only, so `scripts/setup-repo.sh` applies the repository settings and personalizes the project names.

1. Create a new repository from this template:

   ```sh
   gh repo create my-project --template daltonwilt/sfdx-project-template --public --clone
   cd my-project
   ```

   Or click **Use this template** on GitHub and clone the new repository.

2. Install dependencies and run the setup script:

   ```sh
   npm install
   scripts/setup-repo.sh
   ```

   The script:
   - Replaces the template name with your repository name in `package.json`, `sfdx-project.json`, the scratch org definition, and the docs
   - Points `CODEOWNERS` at the repository owner
   - Removes this section from the README
   - Configures GitHub: squash-only merging, auto-deleted branches, wiki off, Dependabot alerts and security updates, secret scanning with push protection, private vulnerability reporting, CodeQL, read-only workflow tokens, approval for first-time contributors' workflows, and a `main` ruleset requiring the **Lint** and **Unit tests** checks

   Run `scripts/setup-repo.sh --help` for options. The script is safe to re-run.

3. Replace `[INSERT CONTACT METHOD]` in `CODE_OF_CONDUCT.md`, update this README's description, then commit and push.

<!-- template:end -->

## Prerequisites

- [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli)
- [Node.js](https://nodejs.org/) (version in `.nvmrc`)
- [VS Code](https://code.visualstudio.com/) with the [Salesforce Extension Pack](https://developer.salesforce.com/docs/platform/sfvscode-extensions/guide/install.html)
- A Salesforce org: a free [Developer Edition](https://developer.salesforce.com/signup) org, or a Dev Hub for scratch orgs

## Getting Started

```sh
git clone https://github.com/daltonwilt/sfdx-project-template.git
cd sfdx-project-template
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

## Project Structure

| Path                              | Contents                     |
| --------------------------------- | ---------------------------- |
| `force-app/main/default/`         | Metadata source              |
| `config/project-scratch-def.json` | Scratch org definition       |
| `manifest/package.xml`            | Metadata manifest            |
| `scripts/`                        | Sample Apex and SOQL scripts |
| `jest-mocks/`                     | Jest mocks for base modules  |

## Development

| Command                      | Description                              |
| ---------------------------- | ---------------------------------------- |
| `npm run lint`               | Lint Aura and LWC JavaScript with ESLint |
| `npm test`                   | Run LWC Jest unit tests                  |
| `npm run test:unit:watch`    | Run Jest tests in watch mode             |
| `npm run test:unit:coverage` | Run Jest tests with a coverage report    |

A pre-commit hook (Husky + lint-staged) lints and tests staged LWC files automatically.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to get started, and please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Security

Please do not report security vulnerabilities through public issues. See [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
