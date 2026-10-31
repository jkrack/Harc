import assert from "node:assert/strict";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";

// Execute the unchanged checker against disposable source fixtures. Never mutate
// the real relay configuration or contact a deployed Worker/account.
const config = JSON.parse(readFileSync(new URL("../wrangler.jsonc", import.meta.url), "utf8"));
const packageJSON = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));

function check(mutate = () => {}) {
  const root = mkdtempSync(join(tmpdir(), "harc-relay-privacy-"));
  try {
    mkdirSync(join(root, "scripts"));
    copyFileSync(new URL("./check-production-privacy.mjs", import.meta.url), join(root, "scripts/check-production-privacy.mjs"));
    const fixture = { config: structuredClone(config), packageJSON: structuredClone(packageJSON) };
    mutate(fixture);
    writeFileSync(join(root, "wrangler.jsonc"), JSON.stringify(fixture.config));
    writeFileSync(join(root, "package.json"), JSON.stringify(fixture.packageJSON));
    const result = spawnSync(process.execPath, [join(root, "scripts/check-production-privacy.mjs")], {
      encoding: "utf8", timeout: 5000,
    });
    assert.ifError(result.error);
    return result;
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test("current production/staging policy passes", () => {
  const result = check();
  assert.equal(result.status, 0, result.stderr);
});

const violations = [
  ["send_metrics", true],
  ["logpush", true],
  ["observability.enabled", true],
  ["observability.logs.enabled", true],
  ["observability.logs.invocation_logs", true],
  ["observability.traces.enabled", true],
  ["tail_consumers", [{ service: "synthetic-tail" }]],
  ["streaming_tail_consumers", [{ service: "synthetic-tail" }]],
  ["analytics_engine_datasets", []],
  ["logfwdr", {}],
];
for (const surface of ["production", "staging"]) {
  for (const [path, value] of violations) {
    test(`${surface} rejects ${path}`, () => {
      const result = check(({ config }) => {
        let target = surface === "production" ? config : config.env.staging;
        const keys = path.split(".");
        for (const key of keys.slice(0, -1)) target = target[key];
        target[keys.at(-1)] = value;
      });
      assert.equal(result.status, 1, result.stderr);
      assert.match(result.stderr, /Production relay privacy check failed:/);
      assert.ok(result.stderr.includes(`${surface}.${path}`), result.stderr);
    });
  }
}

test("rejects raw request tail package scripts", () => {
  const result = check(({ packageJSON }) => {
    packageJSON.scripts.synthetic = "wrangler tail";
  });
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /script synthetic must not expose raw relay request headers/);
});
