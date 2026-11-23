const assert = require("node:assert/strict");
const { test } = require("node:test");
const { openReleasePlayers } = require("./support.cjs");

test("UI11 two live sessions receive the same unique replies within the burst budget", { timeout: 120_000 }, async (t) => {
  const request = "Start the Telegram fixture reply burst.";
  const evidence = "Fixture burst reply";
  const replyCount = 24;
  const budgetMs = 10_000;
  const { maya, eli } = await openReleasePlayers(t, { request, evidence, replyCount });

  await maya.getByRole("textbox", { name: "Message body", exact: true }).fill(request);
  const started = performance.now();
  await maya.getByRole("button", { name: "Send message", exact: true }).click();
  const [first, second] = await Promise.all([receive(maya), receive(eli)]);

  const elapsed = Math.round(performance.now() - started);
  assert.ok(elapsed <= budgetMs, `Both views received the burst in ${elapsed} ms. Budget ${budgetMs} ms.`);
  assert.equal(first.root, second.root);
  assert.deepEqual(first.ids.sort(), second.ids.sort());
  t.diagnostic(`${replyCount} replies reached both Chrome sessions in ${elapsed} ms.`);

  async function receive(page) {
    const root = page.locator("[data-assembly-message-id]:visible").filter({ hasText: request });
    await root.hover();
    const rootId = await root.getAttribute("data-assembly-message-id");
    assert.ok(rootId);
    await root.getByRole("button", { name: "Reply in thread", exact: true }).click();
    const thread = page.getByRole("complementary", { name: "Thread", exact: true });
    const rows = thread.locator("[data-assembly-message-id]").filter({ hasText: evidence });
    await thread.getByText(`${evidence} ${replyCount}`, { exact: true }).waitFor({ timeout: budgetMs });
    assert.equal(await rows.count(), replyCount);

    const identities = await rows.evaluateAll((messages) => messages.map((message) => ({
      id: message.dataset.assemblyMessageId,
      parent: message.dataset.assemblyParentId
    })));
    assert.ok(identities.every(({ id, parent }) => id && parent === rootId));
    const ids = identities.map(({ id }) => id);
    assert.equal(new Set(ids).size, replyCount);
    return { root: rootId, ids };
  }
});
