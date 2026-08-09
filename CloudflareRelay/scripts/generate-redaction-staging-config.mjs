#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import { isAbsolute, resolve, sep } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const outputPath = process.argv[2];
if (outputPath === undefined || !isAbsolute(outputPath) ||
    !outputPath.startsWith(`${resolve(tmpdir())}${sep}`)) {
  fail("output path must be an absolute file inside the system temporary directory");
}

const projectRoot = new URL("../", import.meta.url);
const sourceURL = new URL("../wrangler.jsonc", import.meta.url);
const config = JSON.parse(await readFile(sourceURL, "utf8"));
const staging = config.env?.staging;
const projectPath = fileURLToPath(projectRoot);

if (config.name !== "harc-remote-relay" || staging === undefined ||
    config.logpush !== false || config.observability?.enabled !== false ||
    staging.logpush !== false || staging.observability?.enabled !== false ||
    config.tail_consumers?.length !== 0 || staging.tail_consumers?.length !== 0) {
  fail("source relay configuration is not the expected fail-closed baseline");
}

config.$schema = resolve(projectPath,
  "node_modules/wrangler/config-schema.json");
config.main = resolve(projectPath, config.main);
staging.tail_consumers = [{ service: "harc-remote-redaction-observer" }];

await writeFile(outputPath, `${JSON.stringify(config, null, 2)}\n`, {
  encoding: "utf8",
  mode: 0o600,
});

function fail(message) {
  console.error(`error: ${message}`);
  process.exit(1);
}
