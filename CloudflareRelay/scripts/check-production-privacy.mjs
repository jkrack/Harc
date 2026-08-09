import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const configURL = new URL("../wrangler.jsonc", import.meta.url);
const config = JSON.parse(readFileSync(fileURLToPath(configURL), "utf8"));
const packageURL = new URL("../package.json", import.meta.url);
const packageJSON = JSON.parse(readFileSync(fileURLToPath(packageURL), "utf8"));
const failures = [];

function requireValue(actual, expected, path) {
  if (actual !== expected) {
    failures.push(`${path} must be ${JSON.stringify(expected)}; found ${JSON.stringify(actual)}`);
  }
}

function requireAbsent(value, path, surface) {
  if (value !== undefined) {
    failures.push(`${surface}.${path} must be absent from the relay configuration`);
  }
}

function checkSurface(surface, label) {
  requireValue(surface.send_metrics, false, `${label}.send_metrics`);
  requireValue(surface.logpush, false, `${label}.logpush`);
  requireValue(surface.observability?.enabled, false, `${label}.observability.enabled`);
  requireValue(
    surface.observability?.logs?.enabled,
    false,
    `${label}.observability.logs.enabled`,
  );
  requireValue(
    surface.observability?.logs?.invocation_logs,
    false,
    `${label}.observability.logs.invocation_logs`,
  );
  requireValue(
    surface.observability?.traces?.enabled,
    false,
    `${label}.observability.traces.enabled`,
  );
  requireValue(surface.tail_consumers?.length, 0, `${label}.tail_consumers.length`);
  requireValue(
    surface.streaming_tail_consumers?.length,
    0,
    `${label}.streaming_tail_consumers.length`,
  );
  requireAbsent(surface.analytics_engine_datasets, "analytics_engine_datasets", label);
  requireAbsent(surface.logfwdr, "logfwdr", label);
}

checkSurface(config, "production");
checkSurface({ ...config, ...config.env?.staging }, "staging");

for (const [name, command] of Object.entries(packageJSON.scripts ?? {})) {
  if (typeof command === "string" && /\bwrangler\s+tail\b/u.test(command)) {
    failures.push(`package.json script ${name} must not expose raw relay request headers through wrangler tail`);
  }
}

if (failures.length > 0) {
  console.error("Production relay privacy check failed:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log("Production and staging relay privacy configurations are fail-closed.");
