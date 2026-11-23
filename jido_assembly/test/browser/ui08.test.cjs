const assert = require("node:assert/strict");
const { test } = require("node:test");
const { openAssignment, openReleasePlayers } = require("./support.cjs");

test("UI08 a reopened thread traces the request through delegation and approved delivery", { timeout: 120_000 }, async (t) => {
  const { maya, eli, url } = await openReleasePlayers(t, { releaseDelegation: true });
  const request = "@triage prepare the release note with an auditable run trail.";
  const room = "room:jido-chat-release";
  await maya.getByRole("textbox", { name: "Message body", exact: true }).fill(request);
  await maya.getByRole("button", { name: "Send message", exact: true }).click();
  const decision = await openAssignment(maya, request);
  assert.match(decision, /^decision-/);
  const root = decision.slice("decision-".length);
  await messageRow(maya, root).getByRole("status", { name: "Triage Agent release summary", exact: true })
    .filter({ hasText: "Completed" }).waitFor();
  await maya.getByRole("button", { name: "Document the pending checks", exact: true }).click();

  const version = await openAssignment(eli, request);
  assert.equal(version, "release:draft:" + root);
  const note = messageRow(eli, version);
  await note.getByRole("button", { name: "Approve v1", exact: true }).click();
  await eli.getByText("Marked release note v1 reviewed.", { exact: true }).filter({ visible: true }).waitFor();
  await note.getByRole("button", { name: "Prepare publish proposal", exact: true }).click();

  const proposal = "release:publish:proposal:" + version;
  const approval = "release:publish:approval:" + proposal;
  const receipt = "release:publish:receipt:" + approval;
  const destination = "release:publish:post:" + approval;
  await messageRow(eli, proposal).getByRole("button", { name: "Approve and publish", exact: true }).click();
  await messageRow(maya, receipt).waitFor();
  await eli.reload();

  const trail = eli.locator('details[aria-label="Run trail"]:visible');
  await trail.getByText("Run trail", { exact: true }).click();
  await assertTarget(trail, url, "Request", room, root);
  await assertTarget(trail, url, "Decision", room, decision);
  await assertTarget(trail, url, "Release note v1", room, version);
  await assertTarget(trail, url, "Publish proposal", room, proposal);
  await assertTarget(trail, url, "Publish approval", room, approval);
  await assertTarget(trail, url, "Delivery receipt", room, receipt);

  const plan = trail.locator("[data-assembly-run-id]").filter({ hasText: "Triage Agent release plan" });
  const planId = await assertRun(plan, url, room);
  for (const label of ["Bridge Agent delivery check", "Runbook Agent rollout check", "Triage Agent release summary"]) {
    const child = trail.locator("[data-assembly-run-id]").filter({ hasText: label });
    await assertRun(child, url, room);
    assert.equal(await child.getAttribute("data-assembly-parent-run-id"), planId);
  }

  const published = await assertTarget(trail, url, "Published message", "room:release-log", destination);
  await published.click();
  await messageRow(eli, destination).and(eli.locator('[data-assembly-focus-target="true"]')).waitFor();
});

function messageRow(page, id) {
  return page.locator(`[data-assembly-message-id="${id}"]:visible`);
}

async function assertRun(row, url, room) {
  await row.getByText("Completed", { exact: true }).waitFor();
  const id = await row.getAttribute("data-assembly-run-id");
  assert.ok(id?.startsWith("run:"));
  await assertTarget(row, url, "Run result", room, id + ":reply");
  return id;
}

async function assertTarget(container, url, label, room, id) {
  const link = container.getByRole("link", { name: label, exact: true });
  const href = new URL(await link.getAttribute("href"), url);
  assert.equal(href.searchParams.get("room"), room);
  assert.equal(href.searchParams.get("message"), id);
  return link;
}
