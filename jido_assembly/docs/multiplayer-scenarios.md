# Assembly integration scenario catalog

Each row defines one acceptance case. All rows are implementation targets.
The [current test inventory](multiplayer-acceptance.md) identifies existing
evidence and the opt-in failures. See the [implementation plan](plans/assembly-integration-showcase.md)
for the test environments, fixtures, and delivery order.
The [verification log](multiplayer-verification.md) gives the repeatable
command and verified boundary for each completed scenario.

Use a release room with Maya (release lead), Eli (reviewer), Triage, Bridge,
and Runbook. Use a second room for unrelated work and a third player for access
tests. Provider accounts represent external participants. Assertions use
canonical IDs, durable records, and visible state. Use one case per ID.

## Chat and participation

| ID | Test | Pass condition |
| --- | --- | --- |
| CH01 | Send a channel post | Both player views show the same ID, body, and timestamp. Only the sender sees the post as their own. |
| CH02 | Deliver a mention | A post with `@eli` sets the mention flag for Eli and leaves it clear for Maya. |
| CH03 | Reject a blank post | The composer shows a validation error. Room history and published messages stay unchanged. |
| CH04 | Send to an inactive room | The second player gets one unread item. The message appears when they select that room. |
| CH05 | Track mention unread counts | Two ordinary posts and one directed mention yield three unread items and one mention for the recipient. |
| CH06 | Mark a room read | Opening one room clears those counters for that player. The other player and a second room keep their counters. |
| CH07 | Catch up after a disconnect | An offline player returns to the room and sees missed posts once in canonical order. |
| CH08 | Track multiple sessions | Closing one of Eli’s two sessions keeps him online. Closing the last session clears his presence. |
| CH09 | Create a channel | Both players see the new room and its one initial system post. Reload keeps the same room ID. |
| CH10 | Open a DM | The two permitted players see the same DM and replies. Their channel timelines stay unchanged. |
| CH11 | Deny access to a private DM | A nonmember cannot load its deep link, search its text, post, or subscribe to its events. |
| CH12 | Search then navigate | A unique term returns the correct post. Selecting it opens its room and focuses the exact message. |

## Threads and message identity

| ID | Test | Pass condition |
| --- | --- | --- |
| TH01 | Start a thread from a channel post | The first reply stores the root and parent IDs. Both players see one reply on the root. |
| TH02 | Reply to a reply | The new record keeps the original root ID and points to the selected reply as its parent. |
| TH03 | Keep replies out of the main timeline | A reply updates the thread and root count while the room’s top-level post count stays unchanged. |
| TH04 | Update two open threads | Maya’s new reply reaches both open views. Author labels and ownership are correct in each. |
| TH05 | Separate sibling threads | Two roots with the same text have distinct replies, counters, and links. |
| TH06 | Allow concurrent replies | Two simultaneous replies save under the same root with different IDs and a stable order after reload. |
| TH07 | Open a deep link after reload | A fresh session opens the right room and thread and focuses the exact reply. |
| TH08 | Resolve a search hit in a reply | A search hit opens the associated thread and focuses the reply that contains the match. |
| TH09 | Reject a foreign thread root | A post that names a root in another room creates no reply and reveals no foreign content. |
| TH10 | Reject a parent from a sibling thread | A reply that pairs a root with an unrelated parent is rejected before a message is committed. |
| TH11 | Preserve a link across paging | Paging older history loads the matching root and reply using their IDs. The order and total reply count stay stable. |
| TH12 | Recover a lost UI notification | Reload restores a reply committed before the client missed its event. Replaying the event adds no second row. |

## Emoji and reactions

| ID | Test | Pass condition |
| --- | --- | --- |
| EM01 | Store emoji in message text | Emoji, skin-tone modifiers, and joined characters survive storage and reload without changes. |
| EM02 | Add a reaction to a root | One durable reaction points to the root and Maya. Both views receive the new count. |
| EM03 | Add a reaction to a reply | The reaction appears on the reply. The root remains unchanged. |
| EM04 | Add the same emoji from two accounts | Both views show a count of two and the two actors. |
| EM05 | Remove one actor’s reaction | Both views show one remaining reaction. Only the remaining actor sees it as their own. |
| EM06 | Add two different emoji | Removing one emoji leaves the other emoji and its count intact. |
| EM07 | Repeat an explicit add | Replaying the same add command creates one actor and emoji association. |
| EM08 | Repeat an explicit remove | Replaying the same remove command leaves an empty set and never adds the emoji again. |
| EM09 | Preserve reactions after restart | Reloading the room from SQLite restores actor IDs and counts on roots and replies. |
| EM10 | Map provider emoji | A supported provider emoji maps to the same canonical reaction key on repeat receipt. Custom emoji IDs from separate providers stay distinct. |
| EM11 | Handle an unsupported reaction | When an adapter lacks the capability, Assembly saves the local reaction and shows the outbound status. It sends no unsupported request. |
| EM12 | Keep reaction separate from approval | A rocket, check mark, or thumbs-up does not approve a version, resolve a decision, or run a publish action. |

## Bridge routing and identity

| ID | Test | Pass condition |
| --- | --- | --- |
| BR01 | Receive Telegram and relay to Discord | One Telegram post produces one canonical message and one Discord send. The origin receives no echo. |
| BR02 | Receive Discord and relay to Telegram | One Discord post produces one canonical message and one Telegram send. The origin receives no echo. |
| BR03 | Fan out an Assembly post | One local message reaches both eligible external destinations. Each delivery has its own status and mapping. |
| BR04 | Map Slack as an external participant | A Slack fixture becomes one post from the mapped external author. A supported response returns to the configured target. |
| BR05 | Isolate provider accounts | The same external message ID on two accounts is stored as two distinct canonical messages. |
| BR06 | Apply inbound-only routing | Imported posts appear in the room. Local posts do not leave over that binding. |
| BR07 | Apply outbound-only routing | Local posts reach the bound target. Inbound events through the binding create no room message. |
| BR08 | Handle a disabled or unknown binding | No message is sent through a disabled binding. An event from an unbound external room creates no canonical post. |
| BR09 | Preserve provider attribution | The UI shows provider and external author. A matching display name does not merge that actor with a local player. |
| BR10 | Deduplicate repeated ingress | Deliver the same provider event twice. Room history, outbound relay, and agent run counts each increase once. |
| BR11 | Drop provider echoes | Ingest the provider’s echo of a relayed local message. It creates no second canonical post and no new outbound send. |
| BR12 | Rebind a destination | After a confirmed binding change, new sends use the new target. Existing records retain their original delivery target. |

## Bridge threads, capabilities, and delivery

| ID | Test | Pass condition |
| --- | --- | --- |
| BD01 | Import a threaded Discord or Slack reply | The canonical root and parent match the mapped external root and parent. The reply appears in that thread. |
| BD02 | Import a Telegram reply | An external reply to a mapped message lands in the correct canonical conversation. |
| BD03 | Send an Assembly thread reply | The provider payload uses the mapped external thread or reply reference. It reaches the same conversation. |
| BD04 | Receive a reply before its parent | Assembly reports or holds the unresolved reply. It attaches to the correct parent when the mapping becomes available and never attaches to an unrelated root. |
| BD05 | Use an explicit thread fallback | For a destination without the required thread operation, the configured fallback appears in delivery evidence. The canonical reply keeps its root and parent. |
| BD06 | Relay a supported attachment | MIME type, filename, size, and message association match the fixture. The UI shows the destination’s delivery result. |
| BD07 | Handle an unsupported attachment | The canonical post keeps the attachment. The unsupported destination has a clear status and receives no invalid upload. |
| BD08 | Preserve supported formatting | Mentions, links, code, and multiline content remain readable without changing the intended recipients. |
| BD09 | Treat external text as data | Markup renders as safe text or supported formatting. External text cannot grant agent permissions or approve a tool call. |
| BD10 | Recover partial fanout | One destination succeeds and another fails. A retry targets only the failed delivery and preserves the successful receipt. |
| BD11 | Handle a provider rate limit | A fixture rate limit delays retry according to policy, records the attempt, and avoids duplicate sends. |
| BD12 | Recover a pending bridge delivery | Restart with one pending delivery and one completed delivery. The worker resumes only the pending work and preserves the mappings. |

## Agent triggers and context

| ID | Test | Pass condition |
| --- | --- | --- |
| AT01 | Start Triage from a normal mention | A human channel post with `@triage` creates one run tied to that exact request. |
| AT02 | Store a real assistant reply | The answer appears in the triggering message’s thread with the Triage actor, run ID, and parent ID. |
| AT03 | Invoke from an existing reply | The run stores the reply as its trigger. Its answer stays in the original thread and points to the trigger reply. |
| AT04 | Use the selected thread context | The model input contains the request and its permitted replies. Sibling content is absent. |
| AT05 | Reject a cross-room trigger | An anchor from another room produces no model request and no assistant output. |
| AT06 | Ignore ordinary text and code literals | A plain post and a literal mention inside a code span cause no agent run. |
| AT07 | Deduplicate a replayed trigger | Two deliveries of the same committed message yield one run with the original correlation ID. |
| AT08 | Separate two human requests | Two distinct posts by the same player create independent runs and answers, even when the input text matches. |
| AT09 | Prevent agent loops | An agent reply that mentions Triage and a provider echo of that reply start no new human-triggered run. |
| AT10 | Resolve aliases to the right agent | Repeated casing variants for one registered mention start one run. An unknown alias starts none. |
| AT11 | Enforce agent room permissions | A mention outside the agent’s allowed rooms does not resolve private context or start an agent that can read it. |
| AT12 | Bound the context window | A long thread retains its trigger and selected evidence, stays within the configured budget, and excludes other rooms. |

## Needs you, Board, and versions

| ID | Test | Pass condition |
| --- | --- | --- |
| HF01 | Ask Maya a decision | Triage records a pending decision in the thread, with Maya as assignee and allowed choices defined. |
| HF02 | Open the exact decision from Needs you | Maya’s queue opens the specific decision in its thread. Eli’s queue omits it. |
| HF03 | Open the exact request from Board | The board link opens the pending decision or exact artifact version with the same canonical IDs. |
| HF04 | Reject an unauthorized answer | Eli cannot answer Maya’s decision by opening its URL or submitting its target ID. |
| HF05 | Continue the same run after a decision | Maya’s valid answer records its actor and choice. The same run resumes and saves v1 in the original thread. |
| HF06 | Send the v1 review to Eli | Eli’s queue points to v1 and shows its sources. Maya’s decision clears from her queue. |
| HF07 | Save Eli’s revision as v2 | v1 and v2 remain readable. v2 points to v1 and assigns review to Maya. |
| HF08 | Approve the exact version | Maya approves v2. An attempted approval of v1 does not alter v2. The board and queue agree on the current state. |
| HF09 | Race two decisions for one target | Two sessions submit different valid answers at once. One answer commits and one receives a stale result. One continuation runs. |
| HF10 | Revise while a review is pending | Two valid but competing changes based on the same note cannot both advance the version. The losing view can refresh to the current note. |
| HF11 | Keep parallel handoffs independent | Two release requests wait on different people. Completing one updates only that thread and its assignment. |
| HF12 | Restore an open handoff | Restart from SQLite with Maya’s v2 assignment pending. Its exact link works and can complete the original run once. |

## Delegation and Jido Actions

| ID | Test | Pass condition |
| --- | --- | --- |
| JA01 | Hand off impact and delivery checks | Triage starts Bridge and Runbook work with explicit scope and parent run IDs. |
| JA02 | Pass a typed result between agents | Bridge produces a structured delivery result. Runbook receives the required fields and source references. |
| JA03 | Reject a malformed handoff | Invalid structured output produces a bounded correction or visible failure. No downstream action receives invalid arguments. |
| JA04 | Join results that finish out of order | The parent waits for required findings. Reversing completion order produces one synthesis with both references. |
| JA05 | Exclude unrelated work from synthesis | Results from a parallel request cannot satisfy this request’s delegated task. |
| JA06 | Pass prior agent contributions in order | Bridge can see the permitted Triage contribution. Runbook can see both contributions when chaining is enabled. |
| JA07 | Disable agent peer context | The same round runs with peer context off. Each agent receives the human request without prior agent replies. |
| JA08 | Use a read-only Jido Action | The agent invokes the declared action, obtains fixture evidence, and cites the returned record in its note. |
| JA09 | Deny an undeclared action | A model request for an unavailable tool yields a refusal or controlled failure. No tool side effect occurs. |
| JA10 | Propose an exact publish operation | The proposal shows the destination, artifact version, approver, and action before any write. |
| JA11 | Approve and invoke an action once | The named approver accepts the current proposal. One write occurs and its receipt is linked in the originating thread. |
| JA12 | Reject a stale or revoked publish proposal | Revision or revocation invalidates the old proposal. A replayed approval cannot execute it. |

## Recovery and concurrency

| ID | Test | Pass condition |
| --- | --- | --- |
| RE01 | Recover partial agent work | After Triage commits and Bridge fails, retry Bridge and continue pending work. Triage’s first result remains the only Triage result. |
| RE02 | Fail a required delegated task | After bounded retries, the parent displays the missing result and stops the dependent action. |
| RE03 | Fail an optional delegated task | The parent continues with available evidence and identifies the missing optional result. |
| RE04 | Bound a slow model call | An injected timeout leads to a visible retry or failed state within the configured deadline. |
| RE05 | Bound model and tool calls | A fixture repeatedly requests more work. The run stops at its configured budget and records the reason. |
| RE06 | Cancel before a side effect | A cancellation while awaiting approval prevents further tool work and produces one final cancelled state. |
| RE07 | Handle late work after cancellation | A late result cannot reopen the run, change the assignment, or publish. |
| RE08 | Recover after persisting the decision | Stop after committing Maya’s choice and before resuming the agent. Restart resumes from that choice once. |
| RE09 | Recover after a tool invocation | Stop between a destination write and recording its receipt. Reconcile using the destination or idempotency key. If the outcome cannot be determined, show it as uncertain without a blind resend. |
| RE10 | Rebuild the queue and board | Recompute projections after restart. Pending counts, assignment IDs, and ordering agree with durable state. |
| RE11 | Reject a failed commit | Inject a store write failure. No committed UI event, provider send, or follow-on agent turn is emitted for that transition. |
| RE12 | Converge after concurrent reads and writes | A browser snapshot and event stream overlap a revision. Both players settle on one current version without duplicate timeline rows. |

## Browser and evidence

| ID | Test | Pass condition |
| --- | --- | --- |
| UI01 | Complete the human workflow in two browsers | Maya starts and answers the run. Eli opens v1 and revises it. Maya receives v2 and approves it without switching identities. |
| UI02 | Complete the same flow with an external player | An external participant supplies evidence through a fixture bridge. Both browsers see the source and thread relationship. |
| UI03 | Open a thread on a narrow screen | The exact target opens in the thread panel. Closing it returns focus to the control that opened it. |
| UI04 | Use the workflow by keyboard | A player can post, open a thread, react, open an assignment, and submit a decision by keyboard. |
| UI05 | Distinguish participants and agent states | Actor names, roles, agent run status, and delivery status have accessible labels. Color alone conveys no required state. |
| UI06 | Show drafts and failures clearly | A pending send shows its status. A failed send keeps the draft available and a successful retry creates one post. |
| UI07 | Link evidence from a note | A source link opens the exact allowed record. A missing or inaccessible source has a clear state. |
| UI08 | Show the run trail | The operator can trace request, run, delegation, decision, version, and delivery using matching IDs. |
| UI09 | Show uncertain delivery | A failed or uncertain destination does not appear delivered. The displayed status matches durable evidence. |
| UI10 | Show an outdated assignment | Opening an old review URL still shows that version. Actions for the old approval remain unavailable. |
| UI11 | Keep two sessions responsive under activity | A fixed fixture burst reaches both browsers within the agreed test budget. Each view has the same unique message IDs. |
| UI12 | Produce useful failure evidence | A forced test failure yields a browser trace or screenshot plus a redacted event log with the scenario and correlation IDs. |

## Live service checks

| ID | Test | Pass condition |
| --- | --- | --- |
| LV01 | Run a real model on an anchored request | A configured model returns a valid result. Assembly stores the run and an assistant reply at the exact anchor. |
| LV02 | Run real structured delegation | Real model output validates for both handoffs. The synthesis cites the returned evidence and carries both result IDs. |
| LV03 | Pause a real-model run for a human | The assignee’s reply resumes the same run. Review is tied to the stored note version. |
| LV04 | Use live inference with a fixture publish destination | A real model proposes a permitted action. Only a human approval invokes the instrumented destination. |
| LV05 | Validate a constrained live-model run | The run meets its configured elapsed time and call limits. Evidence records model, usage, and outcome. |
| LV06 | Relay a live Telegram message and reply | The dedicated test chat and both Assembly sessions show the expected canonical root, reply, and external receipt. |
| LV07 | Relay a live Discord message and reply | The dedicated test channel and both Assembly sessions show matching thread references and receipts. |
| LV08 | Relay a live Slack message and reply | The dedicated channel and both Assembly sessions show matching thread references and receipts for the configured binding. |
| LV09 | Exercise live reactions and attachments | Test supported emoji and file operations on configured providers. Verify provider receipts and clean up test files. |
| LV10 | Run the mixed-provider release demo | One provider participant starts a release thread. Another provides evidence. Assembly players decide and review before one approved outbound result. |
| LV11 | Verify a provider’s explicit fallback | Use a configured provider that lacks the selected operation. Its outcome matches the declared fallback and the canonical record remains intact. |
| LV12 | Stop cleanly when live setup is absent | A missing test target or credential produces an explicit blocked result and no outbound operation. The run does not count as a live pass. |
