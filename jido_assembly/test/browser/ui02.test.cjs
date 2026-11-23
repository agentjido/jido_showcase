const assert = require("node:assert/strict");
const { test } = require("node:test");
const { completeRelease, openReleasePlayers } = require("./support.cjs");

test("UI02 both players see Telegram evidence in the original release thread", { timeout: 120_000 }, async (t) => {
  const request = "@triage prepare the browser release note for UI02.";
  const evidence = "The provider fixture confirmed the package smoke checks.";
  const players = await openReleasePlayers(t, { request, evidence });

  await completeRelease(players, request, async ({ maya, eli, rootId }) => {
    const replyIds = [];

    for (const page of [maya, eli]) {
      const thread = page.locator(`[data-assembly-thread-root="${rootId}"]:visible`);
      const reply = thread.locator("[data-assembly-message-id]").filter({ hasText: evidence });
      await reply.waitFor();
      await reply.getByRole("heading", { name: "Release QA, External participant", exact: true }).waitFor();
      await reply.getByText("Telegram", { exact: true }).waitFor();
      assert.equal(await reply.getAttribute("data-assembly-parent-id"), rootId);

      const id = await reply.getAttribute("data-assembly-message-id");
      assert.ok(id);
      assert.equal(await page.locator(`[data-assembly-message-id="${id}"]:visible`).count(), 1);

      const link = await reply.getByRole("link", { name: "Link to reply" }).getAttribute("href");
      assert.equal(new URL(link, players.url).searchParams.get("message"), id);
      replyIds.push(id);
    }

    assert.equal(replyIds[0], replyIds[1]);
  });
});
