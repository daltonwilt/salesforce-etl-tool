const { jestConfig } = require("@salesforce/sfdx-lwc-jest/config");

module.exports = {
  ...jestConfig,
  modulePathIgnorePatterns: ["<rootDir>/.localdevserver"],
  moduleNameMapper: {
    ...jestConfig.moduleNameMapper,
    // sfdx-lwc-jest stubs modalHeader/modalBody/modalFooter but not the LightningModal base
    // class, so components extending it cannot resolve without this mapping.
    "^lightning/modal$": "<rootDir>/jest-mocks/lightning/modal"
  }
};
