const assert = require("node:assert/strict");
const { test } = require("node:test");
const { openAssignment, openPage, openPlayer, startAssembly, startBrowser, waitForPlayer } = require("./support.cjs");

test("UI07 a release note opens its exact source and unavailable messages give the same alert", { timeout: 90_000 }, async (t) => {
  const request = "@triage write a note that links its original release request.";
  const { url } = await startAssembly(t);
  const browser = await startBrowser(t);
  const maya = await openPlayer(browser, url, "Maya Reyes");
  const eli = await openPlayer(browser, url, "Eli Park");

  await maya.getByRole("textbox", { name: "Message body", exact: true }).fill(request);
  await maya.getByRole("button", { name: "Send message", exact: true }).click();
  const decision = await openAssignment(maya, request);
  const rootId = decision.replace(/^decision-/, "");
  assert.equal(decision, "decision-" + rootId);
  await maya.getByRole("button", { name: "Document the pending checks", exact: true }).click();

  const draft = await openAssignment(eli, request);
  assert.equal(draft, "release:draft:" + rootId);
  const draftMessage = eli.locator(`[data-assembly-message-id="${draft}"]:visible`);
  const artifact = draftMessage.getByRole("region", { name: "Release note", exact: true });
  await artifact.getByText("Sources", { exact: true }).click();
  const source = artifact.getByRole("link", { name: "Original release request", exact: true });
  const href = new URL(await source.getAttribute("href"), url);
  assert.equal(href.searchParams.get("room"), "room:jido-chat-release");
  assert.equal(href.searchParams.get("message"), rootId);
  await source.click();
  const focus = eli.locator(`[data-assembly-message-id="${rootId}"][data-assembly-focus-target="true"]:visible`);
  await focus.waitFor();
  await focus.getByText(request, { exact: true }).waitFor();
  await eli.waitForFunction((id) => document.activeElement?.dataset.assemblyMessageId === id, rootId);

  const missing = new URL(href);
  missing.searchParams.set("message", "fixture:missing-source");
  await eli.goto(missing.href);
  const unavailable = eli.getByRole("alert").filter({ hasText: "This message is unavailable." });
  await unavailable.waitFor();
  assert.equal(await eli.locator('[data-assembly-focus-target="true"]:visible').count(), 0);

  const owner = await openPage(browser, url);
  const privateRoom = new URL("/", url);
  privateRoom.searchParams.set("room", "dm:maggie");
  await owner.goto(privateRoom.href);
  const privateBody = "The ops room should prove the bridge path without turning into admin CRUD.";
  const privateMessage = owner.locator("[data-assembly-message-id]:visible").filter({ hasText: privateBody });
  await privateMessage.waitFor();
  const privateId = await privateMessage.getAttribute("data-assembly-message-id");
  assert.ok(privateId);
  privateRoom.searchParams.set("message", privateId);
  await eli.goto(privateRoom.href);
  await unavailable.waitFor();
  assert.equal(await eli.getByText(privateBody, { exact: true }).count(), 0);
  assert.equal(await eli.locator(`[data-assembly-message-id="${privateId}"]:visible`).count(), 0);
  await waitForPlayer(eli, "Eli Park");
});
