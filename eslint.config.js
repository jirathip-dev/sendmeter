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
  globalIgnores(['dist', 'ios', '.claude', '**/.build']),
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
])
