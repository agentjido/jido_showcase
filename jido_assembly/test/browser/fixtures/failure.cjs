const assert = require("node:assert/strict");
const { test } = require("node:test");
const { openPage, startAssembly, startBrowser } = require("../support.cjs");

test("UI12 force a browser failure after opening a stored message", { timeout: 90_000 }, async (t) => {
  const { url } = await startAssembly(t);
  const browser = await startBrowser(t);
  const page = await openPage(browser, url);
  const message = "msg:ops-telegram-symptom";
  const location = new URL("/", url);
  location.search = new URLSearchParams({
    room: "room:ops-workflow",
    message,
    irrelevant: "fixture-url-secret"
  });
  await page.goto(location.href);
  await page.locator(`[data-assembly-message-id="${message}"][data-assembly-focus-target="true"]:visible`).waitFor();
  assert.fail("UI12 intentional failure with fixture-error-secret");
});
