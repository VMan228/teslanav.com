import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  globalIgnores([
    // Next.js build output
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
    // Python sidecar — not JS, and .venv contains thousands of Playwright JS files
    "services/**",
    // Non-app scripts and generated files
    "scripts/**",
    "public/sw.js",
  ]),
  {
    rules: {
      // Both are react-hooks v5 rules that flag valid, documented React patterns:
      // set-state-in-effect: setState in useEffect body is fine for UI init state
      // immutability: ref.current mutations in effects are the recommended pattern
      "react-hooks/set-state-in-effect": "off",
      "react-hooks/immutability": "off",
      // Ignore _-prefixed args/vars (intentionally unused)
      "@typescript-eslint/no-unused-vars": [
        "warn",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
      ],
    },
  },
]);

export default eslintConfig;
