const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const { test } = require("node:test");
const { openPlayer, startAssembly, startBrowser } = require("./support.cjs");

test("UI09 rejected and unconfirmed deliveries retain their saved outcomes after reload", { timeout: 120_000 }, async (t) => {
  const { url, database } = await startAssembly(t, { telegram: true });
  const browser = await startBrowser(t);
  const page = await openPlayer(browser, url, "Maya Reyes");
  const deliveries = [
    { body: "Telegram rejected this fixture message.", label: "Failed", status: "failed" },
    { body: "Telegram did not confirm this fixture message.", label: "Delivery unconfirmed", status: "unknown" }
  ];

  for (const delivery of deliveries) {
    await page.getByRole("textbox", { name: "Message body", exact: true }).fill(delivery.body);
    await page.getByRole("button", { name: "Send message", exact: true }).click();
    const row = page.locator("[data-assembly-message-id]:visible").filter({ hasText: delivery.body });
    await assertDelivery(row, delivery.label);
    delivery.id = await row.getAttribute("data-assembly-message-id");
    assert.match(delivery.id, /^[a-f0-9-]+$/);
    assert.equal(sqlite(database, `
      SELECT status FROM assembly_chat_outbox
      WHERE local_message_id = '${delivery.id}' AND account_id = 'fixture:browser:telegram'
    `), delivery.status);
    assert.equal(sqlite(database, `
      SELECT COUNT(*) FROM assembly_chat_links
      WHERE local_message_id = '${delivery.id}' AND account_id = 'fixture:browser:telegram'
    `), "0");
  }

  await page.reload();
  for (const delivery of deliveries) {
    const row = page.locator(`[data-assembly-message-id="${delivery.id}"]:visible`);
    await assertDelivery(row, delivery.label);
  }
});

async function assertDelivery(row, label) {
  const status = row.getByRole("status", { name: "Telegram delivery", exact: true });
  await status.filter({ hasText: label }).waitFor();
  assert.equal(await status.count(), 1);
  assert.doesNotMatch(await status.textContent(), /\bDelivered\b/);
}

function sqlite(database, query) {
  return execFileSync("sqlite3", ["-readonly", "-cmd", ".timeout 2000", database, query], { encoding: "utf8" }).trim();
}
