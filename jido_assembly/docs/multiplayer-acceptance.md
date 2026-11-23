# Multiplayer acceptance tests

The [132-scenario catalog](multiplayer-scenarios.md) expands these cases.
The [implementation plan](plans/assembly-integration-showcase.md) describes
how to bring the prototype into the main workspace and run the suites.

Use the Assembly workspace as the test surface. Jido Chat supplies the room,
message, thread, participant, reaction, and provider records. Test agent turns
through Jido when the scenario depends on scheduling, delegation, tools, or
recovery. Replace model and provider I/O with controlled responses for CI.

Use two independent player sessions. Use Maya for the requester and Eli for the
reviewer in the release demo. The general chat tests use the standard room
members You and Maggie. Add a third player with no access for permission tests.
Create a new room or run for each case. Compare durable IDs across views and
events. Use signals or explicit barriers to synchronize tests.

**Passing** identifies an existing automated check and its current boundary.
**Target test** runs against the current app on demand. **Specification** gives
acceptance criteria for behavior that needs a test entry point or fixture.

## 1. Human chat

| ID | Test | Pass condition | Status |
| --- | --- | --- | --- |
| C01 | Send a channel message that mentions the other player | Both views receive the same committed message ID. Only the sender sees it as their own post. Only the recipient sees the mention flag. | Passing at the Hologram action and command boundary |
| C02 | Reply and reopen the thread | Both open threads show the same reply and author. The reply increases the root count by one and stays out of the timeline. A fresh read returns the same parent ID. | Passing at the Hologram action and command boundary |
| C03 | React from both sessions | Both players add the same reaction. When one removes theirs, both views show a count of one, and only the remaining player sees it as their reaction. | Passing at the Assembly Chat boundary |
| C04 | Switch rooms, disconnect, and reconnect | In two browsers, the active room updates without a reload. The other room shows the correct unread and mention counts. A reconnect fetches missed messages in order without duplicates. Presence clears after the player's last session disconnects. | Specification, two browsers |
| C05 | Keep a private room private | A nonmember cannot open a deep link, search for the text, post, or receive room events. A direct mention cannot give an agent access to that room. | Specification, requires authenticated sessions |

## 2. In-thread agents

| ID | Test | Pass condition | Status |
| --- | --- | --- | --- |
| A01 | Reply to the exact triggering message | The Triage answer is a durable assistant reply with the request as its parent. Both players find it in that thread. A second request by the same player has its own thread and answer. | Target test for one explicit round. Automatic mention routing and two requests are specifications. |
| A02 | Scope agent input to the selected thread | The agent sees the request and an authorized reply. The input excludes a sibling thread and its replies. | Target test |
| A03 | Reject a trigger from another room | A foreign message ID causes an error before the responder receives any context. The room gains no assistant message. | Target test |
| A04 | Pass findings between agents | In a bounded round, Bridge sees Triage's contribution. Runbook sees both prior contributions. The three replies carry their own author IDs and the same request ID. | Passing with a deterministic responder at the Assembly Agents boundary |
| A05 | Route an ordinary `@triage` post once | A normal mention starts one Triage run. Replaying the committed message event produces no second run or answer. An unmentioned message and an agent's mention leave the run count unchanged. | Specification, real Jido agent with a model fixture |

## 3. Human and agent handoff

| ID | Test | Pass condition | Status |
| --- | --- | --- | --- |
| H01 | Pause for a decision and resume from the thread | Triage asks Maya a specific question. **Needs you** and **Board** link to that decision. Only Maya can answer. The accepted choice produces v1 in the original thread. | Passing for the scripted release route. Same behavior in the main chat with a Jido turn is a specification. |
| H02 | Review a revised artifact | Eli's inbox links to v1. Eli creates v2 and Maya's inbox links to v2. The board links to the current version. An old approval cannot close v2. Maya's approval points to the exact version and clears her assignment. | Passing for the scripted release route |
| H03 | Handle concurrent decisions and independent runs | Two sessions for the assignee submit different choices for the same request. Exactly one choice wins and one continuation runs. A second release request proceeds independently. | Specification, concurrent commands |
| H04 | Resume after an application restart | Restart with a pending decision or review in SQLite. Open the same deep link in a new session. The assignee and version match the pre-restart values. Acting resumes the original run once and leaves its earlier history intact. | Specification for an automated restart test and real Jido continuation |

## 4. Delegation, tools, and recovery

| ID | Test | Pass condition | Status |
| --- | --- | --- | --- |
| J01 | Delegate with typed results | Triage gives delivery and rollout checks to Bridge and Runbook in separate Jido turns. Both report typed results to the original run, even if they finish out of order. Triage produces one synthesis with links to both results. | Specification, Jido supervision and correlation |
| J02 | Gate a Jido Action on approval | A read-only check returns source evidence. A proposed publish action shows the exact target and artifact version. No write occurs before the assigned human approves that proposal. Repeated approval causes one write. | Specification, tool and destination fixtures |
| J03 | Recover a failed worker and enforce a budget | Fail one worker after another has finished. Retry the failed work and continue pending work within the run's limit. Preserve the committed result and show a partial or failed outcome when the budget expires. A cancel stops further work and produces one final status. | Target test for resuming a partial round. Budget and cancellation are specifications. |
| J04 | Use an external participant in the same workflow | A fixture provider supplies a request and a thread reply. Jido Chat maps them to one Assembly thread with source attribution. Exact links resolve to the canonical IDs. Each intended outbound result is delivered once. Echo and repeated inbound events create no new run. | Specification. Existing bridge tests cover fixture relay in both directions. |

## Run the current tests

```sh
mix test test/jido_assembly/multiplayer_test.exs
mix test test/jido_assembly_web/controllers/release_notes_controller_test.exs
mix test test/jido_assembly/multiplayer_test.exs --only assembly_target
```

The third command opts into the rebuild targets. The standard suite excludes
them until the app meets their assertions. Remove the tag from each passing
case so it becomes part of the standard suite.

The current suite also checks compound emoji in a stored reply (EM01),
the root and parent of a nested reply (TH02), and reaction isolation on
replies (EM03). The scripted release test checks that reactions leave the
decision and review pending (EM12). The BR10 test delivers the same Telegram
event twice, sends the request to Discord once, and runs Triage once through
Jido with scripted inference. The run and its exact thread reply remain in
SQLite after the worker restart and provider replay.
The agent suite also starts Triage through Jido with controlled inference,
checks the model input, and reads the assistant response from room history.
The exact thread anchor for that response remains a target under AT02.

Start the rebuild with A01 through A05 in the main chat. Then bring the scripted
H01 and H02 flow into it. Use J01 through J04 to test the behavior that depends
on Jido orchestration and real runtime boundaries.
