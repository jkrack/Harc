import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.redaction-observer.jsonc" },
    }),
  ],
  test: {
    include: ["test/redaction-observer-do.integration.ts"],
    sequence: { concurrent: false },
  },
});
