# Contributing

Thanks for your interest in contributing! This document explains how to propose changes to this project.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Reporting Bugs and Requesting Features

- Search [existing issues](https://github.com/daltonwilt/sfdx-project-template/issues) first to avoid duplicates.
- Use the **Bug report** or **Feature request** template when opening a new issue.
- For security vulnerabilities, follow [SECURITY.md](SECURITY.md) instead of opening an issue.

## Development Setup

1. Fork the repository and clone your fork.
2. Install dependencies:

   ```sh
   npm install
   ```

3. Authorize a Dev Hub and create a scratch org:

   ```sh
   sf org login web --set-default-dev-hub --alias devhub
   sf org create scratch --definition-file config/project-scratch-def.json --alias scl-scratch --set-default
   sf project deploy start
   ```

## Making Changes

1. Create a branch from `main`:

   ```sh
   git checkout -b feature/short-description
   ```

   Use a prefix such as `feature/`, `fix/`, `docs/`, or `chore/`.

2. Make your changes. Keep pull requests focused on a single change.
3. Add or update Jest tests for any LWC changes, and Apex tests for any Apex changes.
4. Run the checks locally before pushing:

   ```sh
   npm run lint
   npm test
   ```

5. Write clear commit messages in the imperative mood, for example `Add datatable pagination`.

## Coding Guidelines

- Follow the existing ESLint configuration; do not disable rules without a reason.
- Components should be reusable: expose configuration through `@api` properties instead of hard-coding values.
- Respect CRUD, FLS, and sharing in Apex (for example, use `WITH USER_MODE` or `Security.stripInaccessible`).
- Never commit org credentials, auth URLs, or `.env` files.

## Submitting a Pull Request

1. Push your branch to your fork and open a pull request against `main`.
2. Fill in the pull request template.
3. Make sure all status checks pass.
4. A maintainer will review your pull request. Pull requests are squash-merged.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
