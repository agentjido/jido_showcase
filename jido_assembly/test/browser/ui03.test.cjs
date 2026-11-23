const assert = require("node:assert/strict");
const { test } = require("node:test");
const { openPage, startAssembly, startBrowser } = require("./support.cjs");

test("UI03 a narrow thread opens the exact reply and returns focus on close", { timeout: 90_000 }, async (t) => {
  const { url } = await startAssembly(t);
  const browser = await startBrowser(t);
  const page = await openPage(browser, url, { width: 390, height: 844 });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), 390);
  const request = "Check the exact root on a narrow screen.";
  const replyBody = "This is the exact reply to open.";

  await page.getByRole("textbox", { name: "Message body", exact: true }).fill(request);
  await page.getByRole("button", { name: "Send message", exact: true }).click();

  const root = page.locator("[data-assembly-message-id]:visible").filter({ hasText: request });
  await root.waitFor();
  const rootId = await root.getAttribute("data-assembly-message-id");
  const opener = root.locator("[data-assembly-thread-trigger]:visible");
  await opener.click();

  const dialog = page.getByRole("dialog", { name: "Thread", exact: true });
  await dialog.waitFor();
  assert.equal(await dialog.getAttribute("data-assembly-thread-root"), rootId);
  const close = dialog.getByRole("button", { name: "Close thread", exact: true });
  await waitForFocus(page, close);

  const composer = dialog.getByRole("textbox", { name: "Thread reply", exact: true });
  await composer.fill(replyBody);
  await dialog.getByRole("button", { name: "Send reply", exact: true }).click();
  const reply = dialog.locator("[data-assembly-message-id]").filter({ hasText: replyBody });
  await reply.waitFor();
  const replyId = await reply.getAttribute("data-assembly-message-id");
  const exactReplyLink = await reply.getByRole("link", { name: "Link to reply" }).getAttribute("href");
  assert.equal(new URL(exactReplyLink, url).searchParams.get("message"), replyId);
  assert.equal(await reply.getAttribute("data-assembly-parent-id"), rootId);

  await close.click();
  await dialog.waitFor({ state: "hidden" });
  await waitForFocus(page, opener);

  await page.goto(new URL(exactReplyLink, url).href);
  const exactReply = dialog.locator(`[data-assembly-message-id="${replyId}"][data-assembly-focus-target="true"]`);
  await exactReply.waitFor();
  assert.equal(await dialog.getAttribute("data-assembly-thread-root"), rootId);
  await waitForFocus(page, exactReply);

  await close.click();
  await dialog.waitFor({ state: "hidden" });
  await waitForFocus(page, opener);
});

async function waitForFocus(page, locator) {
  const element = await locator.elementHandle();
  await page.waitForFunction((target) => document.activeElement === target, element);
}
