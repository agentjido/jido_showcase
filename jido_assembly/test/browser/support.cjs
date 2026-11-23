const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const { access, mkdtemp, rm, writeFile } = require("node:fs/promises");
const { createServer } = require("node:net");
const { tmpdir } = require("node:os");
const path = require("node:path");
const { setTimeout: delay } = require("node:timers/promises");
const { chromium } = require(process.env.ASSEMBLY_PLAYWRIGHT_MODULE || "playwright");
const { saveFailureEvidence } = require("./failure_evidence.cjs");

const appDirectory = path.resolve(__dirname, "../..");
const releaseRoom = "room:jido-chat-release";

async function openReleasePlayers(t, fixture = null) {
  const { url } = await startAssembly(t, fixture);
  const browser = await startBrowser(t);
  const maya = await openPlayer(browser, url, "Maya Reyes");
  const eli = await openPlayer(browser, url, "Eli Park");
  return { maya, eli, url };
}

async function startBrowser(t) {
  const browser = await chromium.launch({ channel: process.env.ASSEMBLY_BROWSER_CHANNEL || "chrome" });
  t.after(async () => {
    try {
      if (t.error) await saveFailureEvidence(t, browser);
    } catch {
      t.diagnostic("Could not save browser failure evidence.");
    } finally {
      await browser.close();
    }
  });
  return browser;
}

async function completeRelease({ maya, eli, url }, request, checkEvidence) {
  const revision = "Approve the package release and retain the pending live checks.";

  await maya.getByRole("textbox", { name: "Message body", exact: true }).fill(request);
  await maya.getByRole("button", { name: "Send message", exact: true }).click();
  const root = maya.locator("[data-assembly-message-id]:visible").filter({ hasText: request });
  await root.waitFor();
  const rootId = await root.getAttribute("data-assembly-message-id");
  assert.ok(rootId);

  const decision = await openAssignment(maya, request);
  assert.equal(decision, "decision-" + rootId);
  await maya.getByRole("button", { name: "Document the pending checks", exact: true }).click();

  const v1 = await openAssignment(eli, request);
  assert.equal(v1, "release:draft:" + rootId);
  await checkEvidence?.({ maya, eli, rootId });
  const original = eli.locator(`[data-assembly-message-id="${v1}"]:visible`);
  await original.getByText("Suggest edit", { exact: true }).click();
  await original.getByRole("textbox", { name: "Revised release note", exact: true }).fill(revision);
  await original.getByRole("button", { name: "Send revision", exact: true }).click();

  const v2 = await openAssignment(maya, request);
  assert.equal(v2, "release:version:2:" + rootId);
  const current = maya.locator(`[data-assembly-message-id="${v2}"]:visible`);
  await current.getByText(revision, { exact: true }).filter({ visible: true }).waitFor();
  await current.getByRole("button", { name: "Approve v2", exact: true }).click();

  for (const page of [maya, eli]) {
    await page.getByText("Marked release note v2 reviewed.", { exact: true }).filter({ visible: true }).waitFor();
    await page.getByRole("button", { name: "Board", exact: true }).click();
    const board = page.getByRole("main");
    const reviewed = board.locator(`[data-assembly-release-lane="reviewed"] [data-assembly-release-target="${v2}"]`);
    await reviewed.waitFor();
    assert.equal(new URL(await reviewed.getAttribute("href"), url).searchParams.get("message"), v2);
  }

  const reviewed = maya.getByRole("main").locator(`[data-assembly-release-target="${v2}"]`);
  await reviewed.click();
  await maya.locator(`[data-assembly-message-id="${v2}"][data-assembly-focus-target="true"]:visible`).waitFor();

  await waitForPlayer(maya, "Maya Reyes");
  await waitForPlayer(eli, "Eli Park");
}

async function openPlayer(browser, url, name) {
  const page = await openPage(browser, url);
  await page.getByRole("combobox", { name: "View as", exact: true }).selectOption({ label: name });
  await waitForPlayer(page, name);
  return page;
}

async function waitForPlayer(page, name) {
  await page.waitForFunction((label) => {
    const viewer = document.getElementById("assembly-demo-users");
    return viewer.selectedOptions[0]?.textContent === label &&
      viewer.selectedOptions[0]?.value === viewer.dataset.assemblyViewer;
  }, name);
}

async function openPage(browser, url, viewport = { width: 1440, height: 960 }) {
  const context = await browser.newContext({ viewport });
  await context.route((requestUrl) => requestUrl.origin !== url, (route) => route.abort());
  const page = await context.newPage();
  page.setDefaultTimeout(12_000);
  const href = `${url}/?room=${encodeURIComponent(releaseRoom)}`;
  await Promise.all([waitForAssembly(page, href), page.goto(href)]);
  return page;
}

async function openAssignment(page, request) {
  await page.getByRole("button", { name: /^Needs you/ }).click();
  const needs = page.getByRole("main");
  const assignment = needs.locator("[data-assembly-release-target]").filter({ hasText: request });
  await assignment.waitFor();
  const id = await assignment.getAttribute("data-assembly-release-target");
  assert.ok(id);
  const href = new URL(await assignment.getAttribute("href"), page.url()).href;
  await Promise.all([waitForAssembly(page, href), assignment.click()]);
  await page.locator(`[data-assembly-message-id="${id}"][data-assembly-focus-target="true"]:visible`).waitFor();
  return id;
}

function waitForAssembly(page, href) {
  return page.waitForResponse((response) => {
    const request = response.request();
    return response.ok() && request.url().endsWith("/hologram/command") &&
      request.headers().referer === href && request.postData()?.includes('"atouch_presence"');
  });
}

async function startAssembly(t, fixture = null) {
  const listener = createServer();
  const port = await new Promise((resolve, reject) => {
    listener.once("error", reject);
    listener.listen(0, "127.0.0.1", () => {
      const { port } = listener.address();
      listener.close((error) => (error ? reject(error) : resolve(port)));
    });
  });

  const directory = await mkdtemp(path.join(tmpdir(), "assembly-browser-"));
  const database = path.join(directory, "assembly.sqlite3");
  const readyFile = path.join(directory, "ready");
  const agentGate = path.join(directory, "agent-release");
  const server = spawn("mix", ["run", "--no-start", "--no-halt", "-e", `
    Application.put_env(:jido_assembly, :sqlite_path, System.fetch_env!("ASSEMBLY_BROWSER_DB"))
    Application.put_env(:jido_assembly, :bridge_options,
      env_fun: fn _ -> nil end, listener_mode: :passive)

    if System.get_env("ASSEMBLY_BROWSER_AGENT_ANSWER") != "" do
      Jido.Assembly.BrowserAgent.configure!(
        System.fetch_env!("ASSEMBLY_BROWSER_AGENT_GATE"),
        System.fetch_env!("ASSEMBLY_BROWSER_AGENT_ANSWER")
      )
    end

    if System.get_env("ASSEMBLY_BROWSER_RELEASE_DELEGATION") == "1" do
      Application.put_env(:jido_assembly, :agent_trigger_options, release_delegation: true)
    end

    {:ok, _apps} = Application.ensure_all_started(:jido_assembly)

    if System.get_env("ASSEMBLY_BROWSER_TELEGRAM") == "1" do
      {:ok, _fixture} = Jido.Assembly.BrowserTelegram.start_link(%{
        request: System.fetch_env!("ASSEMBLY_BROWSER_TELEGRAM_REQUEST"),
        evidence: System.fetch_env!("ASSEMBLY_BROWSER_TELEGRAM_EVIDENCE"),
        reply_count: String.to_integer(System.fetch_env!("ASSEMBLY_BROWSER_TELEGRAM_REPLY_COUNT"))
      })
    end

    File.write!(System.fetch_env!("ASSEMBLY_BROWSER_READY"), "ready")
  `], {
    cwd: appDirectory,
    env: {
      ...process.env,
      ASSEMBLY_BROWSER_DB: database,
      ASSEMBLY_BROWSER_READY: readyFile,
      ASSEMBLY_BROWSER_AGENT_GATE: agentGate,
      ASSEMBLY_BROWSER_AGENT_ANSWER: fixture?.agentAnswer ?? "",
      ASSEMBLY_BROWSER_RELEASE_DELEGATION: fixture?.releaseDelegation ? "1" : "0",
      ASSEMBLY_BROWSER_TELEGRAM: fixture?.telegram || fixture?.request ? "1" : "0",
      ASSEMBLY_BROWSER_TELEGRAM_REQUEST: fixture?.request ?? "",
      ASSEMBLY_BROWSER_TELEGRAM_EVIDENCE: fixture?.evidence ?? "",
      ASSEMBLY_BROWSER_TELEGRAM_REPLY_COUNT: String(fixture?.replyCount ?? 1),
      HOLOGRAM_START: "1",
      JIDO_ASSEMBLY_AGENT_MODE: "scripted",
      MIX_ENV: "test",
      PHX_SERVER: "1",
      PORT: String(port)
    }
  });

  let output = "";
  for (const stream of [server.stdout, server.stderr]) {
    stream.setEncoding("utf8");
    stream.on("data", (chunk) => { output = (output + chunk).slice(-5000); });
  }

  server.on("error", (error) => { output += error.message; });
  const closed = new Promise((resolve) => server.once("close", resolve));
  t.after(async () => {
    server.kill();
    await closed;
    await rm(directory, { recursive: true, force: true });
  });

  const url = `http://127.0.0.1:${port}`;
  const deadline = Date.now() + 45_000;
  while (server.exitCode === null && Date.now() < deadline) {
    const ready = await access(readyFile).then(() => true, () => false);
    if (ready) {
      const response = await fetch(url + "/health", { signal: AbortSignal.timeout(500) }).catch(() => null);
      if (response?.ok) return { url, database, releaseAgent: () => writeFile(agentGate, "") };
    }
    await delay(150);
  }
  assert.fail("Assembly did not start.\n" + output);
}

module.exports = { completeRelease, openAssignment, openPage, openPlayer, openReleasePlayers, startAssembly, startBrowser, waitForPlayer };
