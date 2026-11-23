const { test } = require("node:test");
const { openPlayer, startAssembly, startBrowser } = require("./support.cjs");

test("UI05 the thread names its actors, agent run states, and delivery status", { timeout: 90_000 }, async (t) => {
  const request = "Check the roles and delivery in this thread.";
  const evidence = "The Telegram fixture received the request.";
  const agentAnswer = "Triage checked the provider evidence.";
  const { url, releaseAgent } = await startAssembly(t, { request, evidence, agentAnswer });
  const browser = await startBrowser(t);
  const page = await openPlayer(browser, url, "Maya Reyes");

  await page.getByRole("textbox", { name: "Message body", exact: true }).fill(request);
  await page.getByRole("button", { name: "Send message", exact: true }).click();
  const root = page.locator("[data-assembly-message-id]:visible").filter({ hasText: request });
  await root.waitFor();
  await root.getByRole("heading", { name: "Maya Reyes, Participant", exact: true }).waitFor();
  await root.getByRole("status", { name: "Telegram delivery", exact: true })
    .filter({ hasText: "Delivered" }).waitFor();

  await root.hover();
  await root.getByRole("button", { name: "Reply in thread", exact: true }).click();
  const thread = page.getByRole("complementary", { name: "Thread", exact: true });
  const external = thread.locator("[data-assembly-message-id]").filter({ hasText: evidence });
  await external.getByRole("heading", { name: "Release QA, External participant", exact: true }).waitFor();

  const first = await sendPrompt(thread, "@triage verify the provider delivery.");
  await runStatus(first, "Running").waitFor();
  await releaseAgent();
  await runStatus(first, "Completed").waitFor();
  const assistant = thread.locator("[data-assembly-message-id]").filter({ hasText: agentAnswer });
  await assistant.getByRole("heading", { name: "Triage Agent, Agent", exact: true }).waitFor();

  const second = await sendPrompt(thread, "@triage check the retry label.");
  await runStatus(second, "Failed").waitFor();
});

async function sendPrompt(thread, body) {
  await thread.getByRole("textbox", { name: "Thread reply", exact: true }).fill(body);
  await thread.getByRole("button", { name: "Send reply", exact: true }).click();
  return thread.locator("[data-assembly-message-id]").filter({ hasText: body });
}

function runStatus(message, status) {
  return message.getByRole("status", { name: "Triage Agent run", exact: true }).filter({ hasText: status });
}
