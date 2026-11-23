const assert = require("node:assert/strict");
const { test } = require("node:test");
const { completeRelease, openReleasePlayers } = require("./support.cjs");

test("UI01 Maya and Eli complete one release in separate browser sessions", { timeout: 90_000 }, async (t) => {
  const players = await openReleasePlayers(t);
  const layout = await players.maya.evaluate(() => {
    const style = (selector) => getComputedStyle(document.querySelector(selector));
    return {
      header: style(".assembly-topbar").backgroundColor,
      sidebar: style(".assembly-sidebar").backgroundColor,
      shell: style(".assembly-shell").gridTemplateColumns,
      conversation: style(".assembly-conversation-grid").gridTemplateColumns
    };
  });
  assert.deepEqual(layout, {
    header: "rgb(34, 45, 73)",
    sidebar: "rgb(238, 242, 248)",
    shell: "232px 1208px",
    conversation: "930px 278px"
  });

  await players.maya.getByRole("button", { name: "@ Ask Triage", exact: true }).click();
  await players.maya.waitForFunction(() => {
    const field = document.querySelector('[aria-label="Message body"]');
    return field.value === "@triage " && document.activeElement === field;
  });

  await completeRelease(players, "@triage prepare the browser release note for UI01.", async ({ maya, rootId }) => {
    const root = maya.locator(`[data-assembly-room-message][data-assembly-message-id="${rootId}"]`);
    const precedingId = await maya.getByRole("complementary", { name: "Thread", exact: true })
      .evaluate((element) => element.previousElementSibling.dataset.assemblyMessageId);
    assert.equal(precedingId, await root.getAttribute("data-assembly-message-id"));
  });
});
