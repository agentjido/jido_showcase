const assert = require("node:assert/strict");
const { test } = require("node:test");
const { openPage, startAssembly, startBrowser, waitForPlayer } = require("./support.cjs");

test("UI04 a player posts, reacts, and completes an assignment with the keyboard", { timeout: 120_000 }, async (t) => {
  const { url } = await startAssembly(t);
  const browser = await startBrowser(t);
  const page = await openPage(browser, url);
  const viewer = page.getByRole("combobox", { name: "View as", exact: true });
  await tabTo(page, viewer);
  await viewer.selectOption({ label: "Maya Reyes" });
  await waitForPlayer(page, "Maya Reyes");

  const request = "@triage prepare the keyboard release note.";
  const composer = page.getByRole("textbox", { name: "Message body", exact: true });
  await tabTo(page, composer);
  await page.keyboard.insertText(request);
  await page.keyboard.press("Enter");

  const root = page.locator("[data-assembly-message-id]:visible").filter({ hasText: request });
  await root.waitFor();
  const rootId = await root.getAttribute("data-assembly-message-id");
  assert.ok(rootId);

  const opener = root.getByRole("button", { name: "Reply in thread", exact: true });
  await pressWhenFocused(page, opener, "Enter");
  const thread = page.getByRole("complementary", { name: "Thread", exact: true });
  await thread.waitFor();
  assert.equal(await thread.getAttribute("data-assembly-thread-root"), rootId);

  const agree = thread.getByRole("button", { name: "Agree", exact: true });
  await pressWhenFocused(page, agree, "Space");
  await thread.getByRole("button", { name: "Agree", exact: true, pressed: true }).waitFor();

  await pressWhenFocused(page, page.getByRole("button", { name: /^Needs you/ }), "Enter");
  const assignment = page.locator(`[data-assembly-release-target="decision-${rootId}"]`);
  await pressWhenFocused(page, assignment, "Enter");
  await thread.locator(`[data-assembly-message-id="decision-${rootId}"][data-assembly-focus-target="true"]`).waitFor();

  const choice = thread.getByRole("button", { name: "Document the pending checks", exact: true });
  await pressWhenFocused(page, choice, "Space");
  const draft = thread.locator(`[data-assembly-message-id="release:draft:${rootId}"]`);
  await draft.getByText("Release note · v1", { exact: true }).waitFor();
});

async function pressWhenFocused(page, target, key) {
  await tabTo(page, target);
  await page.keyboard.press(key);
}

async function tabTo(page, target) {
  for (let step = 0; step < 100; step++) {
    if (await target.evaluateAll((controls) => controls.includes(document.activeElement))) return;
    await page.keyboard.press("Tab");
  }
  assert.fail("Tab did not reach " + target);
}
