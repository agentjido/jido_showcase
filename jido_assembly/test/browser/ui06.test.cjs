const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const { test } = require("node:test");
const { openPlayer, startAssembly, startBrowser } = require("./support.cjs");

test("UI06 a failed message or reply keeps its draft for one successful retry", { timeout: 90_000 }, async (t) => {
  const { url, database } = await startAssembly(t);
  const browser = await startBrowser(t);
  const maya = await openPlayer(browser, url, "Maya Reyes");
  const eli = await openPlayer(browser, url, "Eli Park");
  const message = "Keep this release message across a failed write.";
  const reply = "Keep the threaded follow-up across a failed write.";
  const room = "room:jido-chat-release";

  const mayaInput = maya.getByRole("textbox", { name: "Message body", exact: true });
  const mayaSend = maya.getByRole("button", { name: "Send message", exact: true });
  const delay = await holdNextCommand(maya, "persist_message");

  try {
    await mayaInput.fill(message);
    await mayaSend.click();
    await maya.getByRole("status").filter({ hasText: "Sending message…" }).waitFor();
    assert.equal(await mayaInput.inputValue(), message);
    assert.equal(await mayaSend.isDisabled(), true);

    const unrelated = "Eli posts while Maya's command is pending.";
    await eli.getByRole("textbox", { name: "Message body", exact: true }).fill(unrelated);
    await eli.getByRole("button", { name: "Send message", exact: true }).click();
    await messageIn(maya, unrelated).waitFor();
    assert.equal(await mayaSend.isDisabled(), true);

    rejectWrites(database, room);
  } finally {
    delay();
  }

  await maya.getByRole("alert").filter({ hasText: "fixture rejected" }).waitFor();
  assert.equal(await mayaInput.inputValue(), message);
  assert.equal(await messageIn(eli, message).count(), 0);
  assert.equal(await mayaSend.isEnabled(), true);
  const beforeRetry = countHistory(database, room);
  allowWrites(database);
  await mayaSend.click();
  const root = messageIn(maya, message);
  await root.waitFor();
  await messageIn(eli, message).waitFor();
  await maya.waitForFunction(() => document.querySelector('[aria-label="Message body"]').value === "");
  assert.equal(await root.count(), 1);
  assert.equal(await messageIn(eli, message).count(), 1);
  assert.equal(countHistory(database, room), beforeRetry + 1);

  await root.hover();
  await root.getByRole("button", { name: "Reply in thread", exact: true }).click();
  const thread = maya.getByRole("complementary", { name: "Thread", exact: true });
  const replyInput = thread.getByRole("textbox", { name: "Thread reply", exact: true });
  const replySend = thread.getByRole("button", { name: "Send reply", exact: true });
  rejectWrites(database, room);
  await replyInput.fill(reply);
  await replySend.click();
  await thread.getByRole("alert").filter({ hasText: "fixture rejected" }).waitFor();
  assert.equal(await replyInput.inputValue(), reply);
  assert.equal(await messageIn(thread, reply).count(), 0);
  allowWrites(database);
  await replySend.click();
  const savedReply = messageIn(thread, reply);
  await savedReply.waitFor();
  await maya.waitForFunction(() => document.querySelector('aside [aria-label="Thread reply"]').value === "");
  assert.equal(await savedReply.count(), 1);
  assert.equal(await savedReply.getAttribute("data-assembly-parent-id"), await root.getAttribute("data-assembly-message-id"));
  assert.equal(countHistory(database, room), beforeRetry + 2);
});

async function holdNextCommand(page, command) {
  const { promise, resolve } = Promise.withResolvers();
  let held = false;
  await page.route("**/hologram/command", async (route) => {
    if (!held && route.request().postData()?.includes("a" + command)) {
      held = true;
      await promise;
    }
    await route.continue();
  });
  return resolve;
}

function messageIn(container, text) {
  return container.locator("[data-assembly-message-id]:visible").filter({ hasText: text });
}

function rejectWrites(database, room) {
  sqlite(database, `
    CREATE TRIGGER reject_browser_history BEFORE INSERT ON assembly_chat_history
    WHEN NEW.room_id = '${room}'
    BEGIN
      SELECT RAISE(ABORT, 'fixture rejected the history write');
    END
  `);
}

function allowWrites(database) {
  sqlite(database, "DROP TRIGGER reject_browser_history");
}

function countHistory(database, room) {
  return Number(sqlite(database, `SELECT COUNT(*) FROM assembly_chat_history WHERE room_id = '${room}'`));
}

function sqlite(database, query) {
  return execFileSync("sqlite3", ["-cmd", ".timeout 2000", database, query], { encoding: "utf8" });
}
