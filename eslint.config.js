const { defineConfig } = require("eslint/config");
const eslintJs = require("@eslint/js");
const jestPlugin = require("eslint-plugin-jest");
const auraConfig = require("@salesforce/eslint-plugin-aura");
const lwcConfig = require("@salesforce/eslint-config-lwc/recommended");
const globals = require("globals");

module.exports = defineConfig([
  // Aura configuration
  {
    files: ["**/aura/**/*.js"],
    extends: [...auraConfig.configs.recommended, ...auraConfig.configs.locker]
  },

  // LWC configuration
  {
    files: ["**/lwc/**/*.js"],
    extends: [lwcConfig]
  },

  // LWC configuration with override for LWC test files
  {
    files: ["**/lwc/**/*.test.js"],
    extends: [lwcConfig],
    rules: {
      "@lwc/lwc/no-unexpected-wire-adapter-usages": "off"
    },
    languageOptions: {
      globals: {
        ...globals.node
      }
    }
  },

  // Jest mocks configuration
  {
    files: ["**/jest-mocks/**/*.js"],
    languageOptions: {
      sourceType: "module",
      ecmaVersion: "latest",
      globals: {
        ...globals.node,
        ...globals.es2021,
        ...jestPlugin.environments.globals.globals
      }
    },
    plugins: {
      eslintJs
    },
    extends: ["eslintJs/recommended"]
  },

  // Retrieved metadata predates these rules - advisory only, so the
  // pre-commit hook blocks on defects rather than legacy style
  {
    files: ["force-app/**/{aura,lwc}/**/*.js"],
    rules: {
      "guard-for-in": "off" // Wants for...in loops wrapped in a hasOwnProperty check
    }
  },

  // Aura only. The plugin's configs pin ecmaVersion 5, so any controller using let/const
  // or arrow functions fails to parse and is silently left unlinted. no-console lives here
  // rather than in the block above because the LWC config never enables it - listing it
  // there would switch the rule on for thousands of previously unchecked LWC sites.
  {
    files: ["force-app/**/aura/**/*.js"],
    languageOptions: {
      ecmaVersion: 2021
    },
    rules: {
      "no-console": "warn" // console.log left in shipped code (could have data leaks)
    }
  }
]);
