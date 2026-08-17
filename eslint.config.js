import js from '@eslint/js'
import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import tseslint from 'typescript-eslint'
import { defineConfig, globalIgnores } from 'eslint/config'

export default defineConfig([
  // .claude holds agent worktrees (full repo copies) — without the ignore,
  // `eslint .` crawls into them and dies on their out-of-root tsconfigs.
  // **/.build holds SwiftPM build output (native-plugins/*/.build/...) that
  // eslint would otherwise lint — vendored Capacitor .js artifacts that are
  // gitignored but present after any local `swift build`/`swift test`, and
  // which fail whole-repo `npm run lint` (issue #612 review F8).
  globalIgnores(['dist', 'ios', '.claude', '**/.build', 'mcp/dist']),
  {
    files: ['**/*.{js,jsx,ts,tsx}'],
    extends: [
      js.configs.recommended,
      tseslint.configs.recommended,
      reactHooks.configs.flat.recommended,
      reactRefresh.configs.vite,
    ],
    languageOptions: {
      globals: globals.browser,
      parserOptions: { ecmaFeatures: { jsx: true } },
    },
  },
  // mcp/ is a standalone Node package (server, no React, no browser) — it is
  // linted here by the root `npm run lint` (CI's quality gate), but with the
  // right language options: Node globals, no JSX, and none of the React
  // hooks/refresh rules that only apply to the web app. A lint error in
  // mcp/src fails the same gate as one in src/ (issue #644 review F2).
  {
    files: ['mcp/**/*.{js,ts}'],
    extends: [js.configs.recommended, tseslint.configs.recommended],
    languageOptions: {
      globals: globals.node,
      parserOptions: { ecmaFeatures: { jsx: false } },
    },
  },
])
