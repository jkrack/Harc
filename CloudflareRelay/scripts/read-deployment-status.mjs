// Read-only Wrangler status, bounded even if a descendant retains stdout.
// Keep diagnostics fixed: a CLI error may contain account or credential data.
import { spawn } from "node:child_process";

const deadlineMilliseconds = 30_000;
const child = spawn("npx", ["--no-install", "wrangler", "deployments", "status",
  "--name", process.argv[2], "--json"], {
  detached: true,
  stdio: ["ignore", "pipe", "ignore"],
  env: { ...process.env, WRANGLER_SEND_ERROR_REPORTS: "false" },
});

function stopGroup() {
  if (child.pid !== undefined) {
    try { process.kill(-child.pid, "SIGKILL"); } catch (error) {
      if (error.code !== "ESRCH") throw error;
    }
  }
}

function fail(message, code = 1) {
  clearTimeout(deadline);
  stopGroup();
  console.error(`error: ${message}`);
  process.exit(code);
}

const deadline = setTimeout(() => {
  fail("relay deployment status exceeded its 30-second deadline", 124);
}, deadlineMilliseconds);
child.stdout.pipe(process.stdout);
child.on("error", () => fail("could not start relay deployment status"));
// 'close' waits for inherited pipes too; 'exit' alone misses orphaned children.
child.on("close", (code) => {
  if (code !== 0) fail("relay deployment status failed");
  clearTimeout(deadline);
  stopGroup();
});
process.on("SIGINT", () => fail("relay deployment status interrupted", 130));
process.on("SIGTERM", () => fail("relay deployment status interrupted", 143));
