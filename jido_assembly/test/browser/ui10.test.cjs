const assert = require("node:assert/strict");
const { test } = require("node:test");
const { openAssignment, openReleasePlayers } = require("./support.cjs");

test("UI10 an old review link opens v1 without actions and links to v2", { timeout: 120_000 }, async (t) => {
  const { url, maya, eli } = await openReleasePlayers(t);
  const request = "@triage start a release note with a new review assignment.";
  const revision = "Approve the package release after the pending checks.";

  await maya.getByRole("textbox", { name: "Message body", exact: true }).fill(request);
  await maya.getByRole("button", { name: "Send message", exact: true }).click();
  const decision = await openAssignment(maya, request);
  await maya.getByRole("button", { name: "Document the pending checks", exact: true }).click();

  const v1 = await openAssignment(eli, request);
  assert.equal(v1, "release:draft:" + decision.slice("decision-".length));
  const old = eli.locator(`[data-assembly-message-id="${v1}"]:visible`);
  const oldUrl = new URL(await old.getByRole("link", { name: "Link to reply", exact: true }).getAttribute("href"), url);
  assert.equal(oldUrl.searchParams.get("message"), v1);
  await old.getByRole("button", { name: "Approve v1", exact: true }).waitFor();
  await old.getByText("Suggest edit", { exact: true }).click();
  const editor = old.getByRole("textbox", { name: "Revised release note", exact: true });
  const originalBody = await editor.inputValue();
  assert.notEqual(originalBody, revision);
  await editor.fill(revision);
  await old.getByRole("button", { name: "Send revision", exact: true }).click();

  const v2 = await openAssignment(maya, request);
  assert.equal(v2, "release:version:2:" + decision.slice("decision-".length));
  await maya.locator(`[data-assembly-message-id="${v2}"]:visible`)
    .getByRole("button", { name: "Approve v2", exact: true }).waitFor();

  await eli.goto(oldUrl.href);
  await old.and(eli.locator('[data-assembly-focus-target="true"]')).waitFor();
  await old.getByText(originalBody, { exact: true }).waitFor();
  await old.getByText("Release note · v1", { exact: true }).waitFor();
  assert.equal(await old.getByRole("button", { name: /Approve|Prepare publish proposal/ }).count(), 0);
  assert.equal(await old.getByText("Suggest edit", { exact: true }).count(), 0);

  const next = old.getByRole("link", { name: "release note v2", exact: true });
  const newUrl = new URL(await next.getAttribute("href"), url);
  assert.equal(newUrl.searchParams.get("message"), v2);
  await next.click();
  await eli.locator(`[data-assembly-message-id="${v2}"][data-assembly-focus-target="true"]:visible`)
    .getByText(revision, { exact: true }).waitFor();
});
