const assert = require("node:assert/strict");
const { execFile } = require("node:child_process");
const { mkdtemp, readFile, readdir, rm } = require("node:fs/promises");
const { tmpdir } = require("node:os");
const path = require("node:path");
const { promisify } = require("node:util");
const { test } = require("node:test");

test("UI12 a failing scenario saves a screenshot and redacted correlation log", { timeout: 120_000 }, async (t) => {
  const artifacts = await mkdtemp(path.join(tmpdir(), "assembly-ui12-"));
  t.after(() => rm(artifacts, { recursive: true, force: true }));
  const env = { ...process.env, ASSEMBLY_BROWSER_ARTIFACTS: artifacts };
  delete env.NODE_TEST_CONTEXT;

  await assert.rejects(
    promisify(execFile)(process.execPath, ["--test", path.join(__dirname, "fixtures", "failure.cjs")], {
      env,
      timeout: 110_000
    }),
    (error) => {
      assert.equal(error.code, 1);
      assert.match(error.stdout, /UI12 intentional failure/);
      return true;
    }
  );

  const entries = await readdir(artifacts);
  assert.equal(entries.length, 1);
  const directory = path.join(artifacts, entries[0]);
  const log = await readFile(path.join(directory, "events.jsonl"), "utf8");
  assert.doesNotMatch(log, /fixture-url-secret|fixture-error-secret|EU checkout latency/);
  const [failed, snapshot] = log.trim().split("\n").map((line) => JSON.parse(line));
  assert.deepEqual(failed, { event: "scenario_failed", scenario: "UI12" });
  assert.deepEqual(snapshot, {
    event: "browser_snapshot",
    scenario: "UI12",
    page: 1,
    message_id: "msg:ops-telegram-symptom",
    run_ids: [],
    screenshot: "page-1.png"
  });
  const screenshot = await readFile(path.join(directory, snapshot.screenshot));
  assert.ok(screenshot.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])));
});
