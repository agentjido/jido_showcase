# Build Assembly as a Jido Chat integration showcase

Assembly has two jobs. It gives people a working team chat with agents, and it
exercises the same Jido Chat paths that an application uses in production.
Use the [132 acceptance scenarios](../multiplayer-scenarios.md) to check both.

## The demo

Maya posts `@triage Draft the Jido Chat release note` in the release channel.
Eli and a provider participant add evidence in that thread. Bridge checks the
provider delivery results. Runbook checks the rollout and approval steps.
Triage asks Maya how to report pending checks, then drafts v1. Eli opens v1
from **Needs you**, saves v2, and sends it back to Maya. Maya opens and
reviews v2. **Board** and the thread show the same review state and exact
links. An optional publish action requires its own approval for that version
and destination. Emoji reactions support discussion and have no approval effect.

Use this workflow in the main Hologram workspace. Port the HTML/JS
prototype’s thread, run status, decision card, source links, version review,
**Needs you**, and **Board**. Use the existing room and player controls.
Keep the current scripted release route as a reference until the main chat
passes the same handoff tests. Give browser tests separate player sessions
with a test-only identity fixture. A session switcher serves the demo. Room
access tests need authenticated identity and server-side membership checks.

## Where behavior belongs

| Area | Responsibility |
| --- | --- |
| Jido Chat | Canonical rooms, participants, history, message and thread references, reactions, connection bindings, provider normalization, and delivery evidence. Use its public commands and Runtime facts from the showcase. Add a focused Jido Chat regression when an underlying contract is missing. |
| Jido and Jido AI | Agent lifecycle, turn execution, model calls, delegated work, correlation, and execution limits. Use supervised agents in the integration suites. |
| Jido Action | Typed read and write actions. Return source references, action results, and destination receipts. |
| Assembly | Release workflow policy, allowed actions, human assignments, artifact versions, exact links, and Hologram projections. Keep SQLite as the host store. |
| Test fixtures | Model responses, provider endpoints, clocks or deadlines, external event payloads, failure injection, and fake publish destinations. |

Persist the request before routing its committed event. Use the triggering
message ID and agent identity to deduplicate starts. Record the room ID,
thread root ID, trigger ID, and run ID so a request from a reply can still
use the correct parent. Store pending decisions, worker results, assigned
versions, and action proposals as durable run state. Keep accepted choices
and reviews visible in the thread. Make state transitions conditional on
the current decision or version. Derive **Needs you** and **Board** from the
same state. Use a durable action key across retries. Reconcile an uncertain
destination result before sending again.

The current Assembly round accepts a scripted responder. This is useful for
fast assertions about orchestration input and output. It bypasses agent turn
execution. The new `ScriptedInference` fixture runs through a real Jido
agent and supplies a fixed model response through `Jido.AI.InferenceClient`.
The smoke test records the model input, checks that one call occurred, and
finds the assistant message in Jido Chat history. Extend this fixture with
structured tool calls, delayed results, and model errors as those scenarios
come online.

## Test environments

| Suite | What runs | When |
| --- | --- | --- |
| Scripted | Hologram action and command tests, Assembly workflow transitions, Jido Chat Rooms, Runtime facts, SQLite, and deterministic responder input. | Every commit on the existing Elixir/OTP matrix. |
| Integration | Start real Jido agents. Supply fixed model responses and provider events. Exercise Jido turns, typed tool calls, provider adapters, bridge bindings, and persistence. Use temporary SQLite and fresh namespaces. | Every pull request. Run reboot and failure cases with explicit barriers and controlled timeouts. |
| Browser | Two independent browser contexts against a built Assembly app. Use the same model and provider fixtures. Follow exact links and assert visible state alongside durable IDs. | A dedicated CI job on one supported runtime. Keep traces and screenshots on failure. |
| Live model | Use the same workflow and output schemas with a configured model. Test structure, citations, decisions, budgets, and state transitions. Assert no exact prose. Use a fixture publish destination. | Manual or scheduled with a time and token limit. |
| Live providers | Use dedicated test targets and the real adapters. Check transport-specific capabilities, receipts, and cleanup. Start with Telegram and Discord. Add Slack after its binding and fixtures are ready. | Manual or scheduled with explicitly configured credentials and targets. Report absent setup as blocked. |

Keep the 120 offline scenarios free of provider and model credentials. The live
group has 12 scenarios, including the missing-setup check. Use the same scenario
IDs in ExUnit tags, browser tests, logs, and reports. Report pass, failure,
blocked, and unsupported with the provider and feature. Use expected
capabilities as the test input so an unexpected loss of support fails the
case. Provider fixtures must record calls and payloads at the transport
boundary. Let production code decide routes, map IDs, and suppress echoes.

Run isolated suites against the committed dependency pins. Add a compatibility
job when Assembly can also run against a Jido Chat release candidate. Keep the
standard CI job deterministic. Promote a scenario into it once the behavior
passes with fixtures. Preserve the opt-in tests for unresolved behavior.

## Build order and exit checks

1. **Chat and thread foundation.** Close the four opt-in Assembly gaps. Add
   exact message and reply links to Hologram. Prove channel, reply, and
   reaction delivery with two browser sessions. Use CH, TH, EM, AT, and RE01.
2. **Main-chat release flow.** Move the prototype’s decision, review, and
   version controls into the thread. Connect **Needs you** and **Board** to
   canonical IDs. Add independent runs, stale review, and restart cases.
   Pass HF01–HF12 and UI01.
3. **Bridge the same flow.** Extend the existing Telegram and Discord
   fixture relay. Verify routing direction, deduplication, mapped threads,
   and delivery recovery. Add Slack as an external participant after the
   first two providers pass. Pass BR, BD, and UI02 at the declared capability
   level.
4. **Run real Jido turns with controlled inference.** Run Triage, Bridge,
   and Runbook across the same request. Add typed results, budget and
   cancellation tests, and the approved fixture publish action. Pass JA and
   the remaining RE cases.
5. **Run the release rehearsal.** Run the live model with the fixture
   destination, then the configured live provider cases. Record the IDs and
   delivery receipts from the mixed-provider demo. Keep blocked cases in the
   release report until somebody supplies the required setup.

The first demonstration is the full Maya → Eli → Maya handoff in two
independent sessions. The final demonstration adds provider participants and
real model delegation to that same workflow. Each demonstration uses the
same chat records and link targets as its integration tests.
