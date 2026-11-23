const { mkdir, mkdtemp, writeFile } = require("node:fs/promises");
const { tmpdir } = require("node:os");
const path = require("node:path");

async function saveFailureEvidence(t, browser) {
  const scenario = /^UI\d{2}\b/.exec(t.name)?.[0];
  const pages = browser.contexts().flatMap((context) => context.pages());
  if (!scenario || pages.length === 0) return;

  const root = process.env.ASSEMBLY_BROWSER_ARTIFACTS || path.join(tmpdir(), "assembly-browser-evidence");
  await mkdir(root, { recursive: true });
  const directory = await mkdtemp(path.join(root, scenario + "-"));
  const events = [
    { event: "scenario_failed", scenario },
    ...(await Promise.all(pages.map((page, index) => capturePage(page, directory, index + 1, scenario))))
  ];
  await writeFile(path.join(directory, "events.jsonl"), events.map((event) => JSON.stringify(event)).join("\n") + "\n");
  t.diagnostic("Browser failure evidence saved in " + directory);
}

async function capturePage(page, directory, index, scenario) {
  const ids = await page.evaluate(() => {
    function visible(selector) {
      return Array.from(document.querySelectorAll(selector)).filter((element) => element.getClientRects().length);
    }

    return {
      message_id: visible('[data-assembly-focus-target="true"]')[0]?.dataset.assemblyMessageId,
      thread_id: visible("[data-assembly-thread-root]")[0]?.dataset.assemblyThreadRoot,
      run_ids: visible("[data-assembly-run-id]").map((element) => element.dataset.assemblyRunId)
    };
  }).catch(() => ({}));
  const screenshot = `page-${index}.png`;
  const saved = await page.screenshot({ path: path.join(directory, screenshot), timeout: 5_000 })
    .then(() => screenshot, () => undefined);

  return {
    event: "browser_snapshot",
    scenario,
    page: index,
    message_id: evidenceId(ids.message_id),
    thread_id: evidenceId(ids.thread_id),
    run_ids: [...new Set((ids.run_ids ?? []).map(evidenceId).filter(Boolean))],
    screenshot: saved
  };
}

function evidenceId(value) {
  return typeof value === "string" && /^[A-Za-z0-9:_-]{1,256}$/.test(value) ? value : undefined;
}

module.exports = { saveFailureEvidence };
