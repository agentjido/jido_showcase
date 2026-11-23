# Assembly scenario verification

Work through the [catalog](multiplayer-scenarios.md) in order. A row here records
a passing check and its test boundary. Other catalog entries are pending.

Run an ExUnit scenario from the Assembly package with `mix test --only scenario:CH01`.
Use `mix test` for the standard suite. Keep the scenario ID on the test so the
same command can be used after a change.

Browser tests use Node.js 24, Playwright, and Chrome. Run `mix assets.build`,
then run `node --test --test-concurrency=1 test/browser/ui*.test.cjs`.
If Node cannot resolve Playwright, set `ASSEMBLY_PLAYWRIGHT_MODULE` to the
path of an installed Playwright package.
The browser test starts a local Assembly server with a temporary SQLite
database and scripted behavior. It removes the database when the test ends.
UI06 and UI09 also use the `sqlite3` command to test and check storage behavior.
After a browser test fails, the test prints the path to a screenshot and an
event log. Set `ASSEMBLY_BROWSER_ARTIFACTS` to keep these files in a specific
folder. The default is `assembly-browser-evidence` under the system temporary folder.
The CI browser job uses Playwright Chromium and uploads this evidence when
a scenario fails.

| Scenario | Repeatable evidence | Boundary |
| --- | --- | --- |
| CH01 | `mix test --only scenario:CH01` | Hologram composer and two page states, Jido Chat history and committed event |
| CH02 | `mix test --only scenario:CH02` | Two release-room player views and stored mention metadata |
| CH03 | `mix test --only scenario:CH03` | Composer, direct command, unchanged Jido Chat history, and no committed message event |
| CH04 | `mix test --only scenario:CH04` | Two page states, inactive room navigation, and replay of a committed message |
| CH05 | `mix test --only scenario:CH05` | Three committed posts, two player views, and mention counts |
| CH06 | `mix test --only scenario:CH06` | Room selection and the unread state of two player views |
| CH07 | `mix test --only scenario:CH07` | Room re-entry from a stale page, durable catch-up, and overlapping live delivery |
| CH08 | `mix test --only scenario:CH08` | Presence session close API and last-session signals |
| CH09 | `mix test --only scenario:CH09` | Channel creation, two player views, and fresh Jido Chat history. Maya and Eli each post through the composer and have active Room membership |
| CH10 | `mix test --only scenario:CH10` | Both DM participants, stored thread reply, and channel timeline isolation |
| CH11 | `mix test --only scenario:CH11` | Server-bound identity, private history and search, forged writes, and Hologram subscription scope |
| CH12 | `mix test --only scenario:CH12` | Stored search result, room selection, and exact focus target in page state |
| TH01 | `mix test --only scenario:TH01` | Durable first reply IDs and root counts in two player views |
| TH02 | `mix test --only scenario:TH02` | Durable root and parent IDs for a nested reply |
| TH03 | `mix test --only scenario:TH03` | Stored reply plus unchanged timeline count |
| TH04 | `mix test --only scenario:TH04` | Hologram reply command and both open thread views |
| TH05 | `mix test --only scenario:TH05` | Identical sibling roots, distinct links, and exact reply counts |
| TH06 | `mix test --only scenario:TH06` | Concurrent writes and two fresh views in stored sequence order |
| TH07 | `mix test --only scenario:TH07` | Fresh session resolves the exact nested reply and retains focus through refresh |
| TH08 | `mix test --only scenario:TH08` | Search hit opens the exact reply when it is absent from the page cache |
| TH09 | `mix test --only scenario:TH09` | Hologram rejects a foreign root and leaves both room histories intact |
| TH10 | `mix test --only scenario:TH10` | Chat command rejects a parent in a sibling thread before a write |
| TH11 | `mix test --only scenario:TH11` | Old reply link, bounded history paging, stable order and counts, and page replay |
| TH12 | `mix test --only scenario:TH12` | Fresh history restores a missed reply and replay keeps one row |
| EM01 | `mix test --only scenario:EM01` | Fresh thread and message reads preserve a compound Unicode string |
| EM02 | `mix test --only scenario:EM02` | Maya's root reaction, durable actor ID, and personalized state for two players |
| EM03 | `mix test --only scenario:EM03` | Open thread and stored reply show the reaction on the selected reply |
| EM04 | `mix test --only scenario:EM04` | Two player commands produce one emoji count with both actors |
| EM05 | `mix test --only scenario:EM05` | One removal leaves the remaining actor and correct ownership in both views |
| EM06 | `mix test --only scenario:EM06` | Removing one emoji preserves the other emoji and both of its actors |
| EM07 | `mix test --only scenario:EM07` | Repeated add preserves a single stored revision and sends one room broadcast |
| EM08 | `mix test --only scenario:EM08` | Repeated remove preserves a single stored removal and sends one room broadcast |
| EM09 | `mix test --only scenario:EM09` | Restarted SQLite worker restores root and reply reactions to a fresh page |
| EM10 | `mix test --only scenario:EM10` | Telegram and Discord normalization, account-scoped actors, canonical add and remove, and separated custom emoji keys |
| EM11 | `mix test --only scenario:EM11` | Linked X fixture, durable local reaction, rendered unsupported status, and unchanged outbox |
| EM12 | `mix test --only scenario:EM12` | Scripted release decision and version review remain pending after three reactions |
| BR01 | `mix test --only scenario:BR01` | Telegram fixture ingress, one Discord transport call, stored links on both accounts, and replay |
| BR02 | `mix test --only scenario:BR02` | Discord fixture ingress, one Telegram transport call, and stored links on both accounts |
| BR03 | `mix test --only scenario:BR03` | One Assembly post, two transport calls, and independent completed outbox records and mappings |
| BR04 | `mix test --only scenario:BR04` | Slack event callback, mapped author, and one reply with the original Slack thread timestamp |
| BR05 | `mix test --only scenario:BR05` | Two Slack accounts with identical external IDs retain separate message links and authors |
| BR06 | `mix test --only scenario:BR06` | Inbound-only Telegram binding saves an imported post and does not relay a local post |
| BR07 | `mix test --only scenario:BR07` | Outbound-only Telegram binding sends a local post and rejects provider ingress |
| BR08 | `mix test --only scenario:BR08` | One enabled Telegram target receives a post while disabled and unknown targets reject ingress |
| BR09 | `mix test --only scenario:BR09` | Rendered Telegram badge and distinct local and external identities with the same display name |
| BR10 | `mix test --only scenario:BR10` | Repeated Telegram ingress, one Discord request relay, one SQLite run across worker restart, and one Jido inference call with a thread reply |
| BR11 | `mix test --only scenario:BR11` | Telegram and Discord echoes without self markers leave the original message and delivery links intact |
| BR12 | `mix test --only scenario:BR12` | Invalid replacement leaves the original target enabled. A confirmed change sends new posts to the replacement and preserves old receipts |
| BD01 | `mix test --only scenario:BD01` | Slack callback reply keeps the mapped root and parent in SQLite and appears only in the thread |
| BD02 | `mix test --only scenario:BD02` | Telegram reply chain preserves the original root and each exact parent in history |
| BD03 | `mix test --only scenario:BD03` | Assembly sends the exact Telegram parent reference in the request and stores the delivery receipt |
| BD04 | `mix test --only scenario:BD04` | A duplicate Telegram reply waits in SQLite across restart and attaches once when its exact parent arrives |
| BD05 | `mix test --only scenario:BD05` | Linked X fixture sends a room fallback while the Assembly reply keeps its root and parent and shows the recorded fallback |
| BD06 | `mix test --only scenario:BD06` | Telegram file fixture receives the exact bytes and filename. Assembly shows the stored MIME type, size, and completed delivery |
| BD07 | `mix test --only scenario:BD07` | Telegram delivers the file while X records a skipped delivery and sends no command. The file stays on the canonical post |
| BD08 | `mix test --only scenario:BD08` | Discord payload preserves the original text and disables mention expansion. Assembly renders the link, code, and line breaks and resolves only the intended user |
| BD09 | `mix test --only scenario:BD09` | Slack markup renders as text. A real Triage turn with scripted inference has no tools and cannot advance Maya's pending decision |
| BD10 | `mix test --only scenario:BD10` | A failed Discord delivery gets a new durable attempt. The original failure and the successful Telegram receipt remain intact |
| BD11 | `mix test --only scenario:BD11` | A Discord rate limit preserves the reported delay across SQLite and retry worker restarts. The bridge sends one retry after the deadline and stops after three attempts when the provider keeps rejecting it |
| BD12 | `mix test --only scenario:BD12` | After an account and SQLite restart, the bridge submits one pending attempt and preserves the completed work and its exact provider link |
| AT01 | `mix test --only scenario:AT01` | The normal channel composer commits a human mention and one SQLite run tied to its exact request. Controlled inference runs once |
| AT02 | `mix test --only scenario:AT02` | A real Jido Triage turn with controlled inference saves the assistant, run, and parent IDs. A fresh Hologram thread shows the reply after SQLite restarts |
| AT03 | `mix test --only scenario:AT03` | A player invokes Triage from a thread reply. The answer stays under the original root and points to the triggering reply |
| AT04 | `mix test --only scenario:AT04` | Controlled inference receives the marked request and thread evidence. A sibling request, its replies, and another room are absent |
| AT05 | `mix test --only scenario:AT05` | Both agent entry points reject a request from another room. The inference client receives no call, and both histories have no assistant output |
| AT06 | `mix test --only scenario:AT06` | Plain text, inline code, and fenced code leave the run table empty. A regular mention in the same room starts one inference call |
| AT07 | `mix test --only scenario:AT07` | The normal write path replays one message before and after completion. SQLite keeps the original request, run, and reply IDs, and inference runs once |
| AT08 | `mix test --only scenario:AT08` | Two posts with identical text retain separate request and run IDs. Each answer stays attached to its own request |
| AT09 | `mix test --only scenario:AT09` | An assistant answer contains a Triage mention and reaches Telegram. Its provider echo preserves the single run and reply without another send |
| AT10 | `mix test --only scenario:AT10` | Two case variants resolve to one registered Triage mention and one run. An unknown alias produces no run |
| AT11 | `mix test --only scenario:AT11` | Triage lacks membership in a private DM. The mention stays in chat, creates no run, and never reaches inference. The regular channel request still runs |
| AT12 | `mix test --only scenario:AT12` | A long thread keeps the root, exact trigger, and latest human evidence. The test verifies the message count, UTF-8 byte cap, and exclusion of other rooms |
| HF01 | `mix test --only scenario:HF01` | A committed request survives a SQLite and workflow restart. The main composer also starts the same workflow and renders Triage's stored decision, Maya's assignment, and both choices |
| HF02 | `mix test --only scenario:HF02` | Maya's queue refreshes from the committed decision. Its link opens the canonical message in the main thread. Eli's queue omits it |
| HF03 | `mix test --only scenario:HF03` | The main Board opens the canonical decision. The same card moves to review and opens v1 under the original root, using Eli's queue link |
| HF04 | `mix test --only scenario:HF04` | Eli opens Maya's exact link in main chat and the reference route. Both surfaces use the session actor, hide answer controls, and leave history unchanged after a forged submission |
| HF05 | `mix test --only scenario:HF05` | Maya's answer commits with her identity and exact decision ID. After SQLite and the worker restart, Triage writes one v1 under the same root and points it to her answer |
| HF06 | `mix test --only scenario:HF06` | Eli's queue opens v1 with its stored evidence and source links. The decision clears from Maya's queue |
| HF07 | `mix test --only scenario:HF07` | Eli submits v2 from the main thread. It points to v1, retains the source evidence, leaves v1 readable, and assigns Maya the exact v2 |
| HF08 | `mix test --only scenario:HF08` | Main chat rejects an approval of v1 and records Maya's approval of v2 with its exact ID. Board retains the v2 link and Maya's queue clears |
| HF09 | `mix test --only scenario:HF09` | Two Maya sessions submit different choices together. One choice and one draft commit. The other session receives a stale result |
| HF10 | `mix test --only scenario:HF10` | Two Eli sessions submit competing edits to v1. Only one v2 commits, and the rejected session reloads its thread and queue |
| HF11 | `mix test --only scenario:HF11` | Maya and Eli have separate pending requests. Completing Maya's leaves Eli's decision, queue link, and thread history intact |
| HF12 | `mix test --only scenario:HF12` | Maya's pending v2 survives a SQLite and workflow restart beyond the latest chat page. Its exact link opens and accepts one approval |
| JA01 | `mix test --only scenario:JA01` | The main composer queues Triage. After a worker restart, the two delegated Jido turns use distinct scopes and the same parent ID. A second SQLite connection reads the same runs, and all replies use the original thread |
| JA02 | `mix test --only scenario:JA02` | Bridge requests a strict structured result. SQLite and the chat reply retain its outcome, summary, and exact source IDs. Runbook receives that result, and the Hologram evidence link opens the cited thread reply |
| JA03 | `mix test --only scenario:JA03` | Bridge rejects an incorrect field type and a valid ID from another thread. Each request records a visible Bridge failure and Runbook stop. Neither calls the Runbook model, and a worker restart preserves one notice per failed run |
| JA04 | `mix test --only scenario:JA04` | Each completion order starts two real Jido turns with controlled inference. Triage waits after the first commit. The second result survives a worker restart before publication and yields one synthesis with both exact reply links |
| JA05 | `mix test --only scenario:JA05` | Two requests in one room each wait after a finding commits. Finishing Eli's request leaves Maya waiting. Each synthesis prompt and stored reply cite only findings from its own thread |
| JA06 | `mix test --only scenario:JA06` | Actual model inputs show the human request in all three turns. Bridge receives Triage's plan. Runbook receives the plan and then the typed Bridge finding. An unassigned agent reply is excluded |
| JA07 | `mix test --only scenario:JA07` | The request stores peer context off before the host default changes. All three initial model inputs contain the request and omit peer replies. The Runbook input still omits them after both peer replies exist |
| JA08 | `mix test --only scenario:JA08` | A Jido turn invokes `read_release_evidence`. The tool response contains the exact stored fixture record. The Triage reply saves the action name and an evidence link. The source record remains intact |
| JA09 | `mix test --only scenario:JA09` | Jido rejects two model requests for an undeclared publish tool. The repair prompt confirms the allowlist decision. The thread records the final model call limit and zero tool calls, and no tool response or delivery is created |
| JA10 | `mix test --only scenario:JA10` | Maya prepares one durable proposal for v2. Eli cannot prepare it as Maya. Its card shows the exact artifact link, destination, approver, and action. A replay returns the same proposal, and the destination history stays identical through artifact review |
| JA11 | `mix test --only scenario:JA11` | Eli approves the exact reviewed version in Hologram. An early submission and a submission from Maya fail. Jido telemetry records one publish action. The single destination post has the exact approved body, and its thread receipt links to it. Replaying both the command and the worker step preserves that receipt and destination history |
| JA12 | `mix test --only scenario:JA12` | A v2 revision blocks replay of the v1 proposal. Maya revokes the reviewed v2 proposal through Hologram, and the revoked status survives a worker restart. Replayed approvals produce no approval, receipt, or destination write |
| RE01 | `mix test --only scenario:RE01` | Bridge's failed model call queues one retry in SQLite under the original run ID. A second SQLite connection sees it while the worker is stopped. The restarted worker resumes Bridge, Runbook, and synthesis. Triage's original plan and record remain intact |
| RE02 | `mix test --only scenario:RE02` | Bridge makes two model calls and exhausts its retry. Triage's stored stop notice identifies the required finding and links Bridge's exact failure. A fresh Hologram thread renders the notice after a restart. Runbook and synthesis make no model call, and the destination and outbox stay unchanged |
| RE03 | `mix test --only scenario:RE03` | A request saves the optional rollout policy. Runbook fails first and the parent waits for Bridge. After a restart, Triage uses the saved Bridge result, links its exact reply, and displays the missing optional finding in a fresh thread |
| RE04 | `mix test --only scenario:RE04` | The inference fixture ignores its deadline. Assembly cancels the exact Jido turn and observes the inference process exit. The thread shows one timeout notice and SQLite records one failed run. No delegated model call starts |
| RE05 | `mix test --only scenario:RE05` | Repeated requests for the allowed evidence tool reach the model call limit in one run and the tool call limit in another. Jido telemetry confirms one tool execution per run. SQLite and the Hologram thread record the exact limit and call counts |
| RE06 | `mix test --only scenario:RE06` | The requester cancels a pending publish approval in Hologram. SQLite retains one cancellation and the Board links to it. After a worker restart, Eli's old approval cannot start a publish action or write to the destination |
| RE07 | `mix test --only scenario:RE07` | A valid late Bridge result reaches the worker, which reports that it discarded the result. SQLite rejects its reply, old commands cannot change the assignment or publish, and another mention in the thread starts no agent run |
| RE08 | `mix test --only scenario:RE08` | SQLite preserves Maya's choice when she sends a conflicting answer with the worker stopped. The restarted worker writes one matching draft and one chat event. A second restart and an explicit replay return the same draft without emitting another event |
| RE09 | `mix test --only scenario:RE09` | After a restart, the worker matches the existing destination post by ID, approval, version, and body and adds one linked receipt. A different body at that ID produces a durable uncertainty notice. Neither path sends another destination post or event |
| RE10 | `mix test --only scenario:RE10` | Fresh Maya and Eli pages rebuild identical Board lanes after SQLite and the workflow restart. Needs you retains the visible counts, newest-first order, and exact decision and review links |
| RE11 | `mix test --only scenario:RE11` | A SQLite trigger aborts the agent queue write after the chat history write. The transaction rolls back with no UI event, outbox row, Discord fixture send, or model call. The same command succeeds after the trigger is removed |
| RE12 | `mix test --only scenario:RE12` | Both player views receive old snapshots and repeated revision events in different orders. SQLite history, both threads, Needs you, and Board agree on v2. Each timeline has one root and no duplicate replies |
| UI01 | `node --test test/browser/ui01.test.cjs` | Independent Chrome sessions keep their Maya and Eli identities. Maya starts the request and answers the exact decision. Eli opens v1 from Needs you and submits v2. Maya opens and approves v2, and both Boards link to the same reviewed version |
| UI02 | `node --test test/browser/ui02.test.cjs` | The fixture receives the outbound Telegram request and replies to its provider message ID. Both Chrome sessions show one reply with the same canonical ID, the Telegram source, and the original request as its parent. The players then complete the v2 review |
| UI03 | `node --test test/browser/ui03.test.cjs` | At 390 pixels wide, the message control opens the matching thread. Closing returns focus to that control. The saved reply link reopens the same thread, focuses the exact reply, and returns focus to the message control on close |
| UI04 | `node --test test/browser/ui04.test.cjs` | Tab, Enter, and Space reach the desktop controls. Maya posts, opens the exact thread, reacts, opens the exact decision from Needs you, and submits the choice to produce v1 |
| UI05 | `node --test test/browser/ui05.test.cjs` | Chrome reads the names and roles of Maya, the external participant, and Triage. Text identifies Telegram delivery and the delayed agent run's Running, Completed, and Failed states |
| UI06 | `node --test test/browser/ui06.test.cjs` | Maya sees the send in progress while Eli posts in the same room. A rejected SQLite write shows an alert and keeps the message or reply draft. Each retry clears its composer and adds one history record. The reply retains its exact thread parent |
| UI07 | `node --test test/browser/ui07.test.cjs` | The note links to the exact saved request. Chrome focuses that message for Eli. A missing record and an existing private message show the same unavailable alert. The private message ID and text stay out of Eli's view |
| UI08 | `node --test test/browser/ui08.test.cjs` | A fresh thread links the request, decision, v1, publish proposal, approval, and receipt. Each completed agent run links its saved reply. Bridge, Runbook, and synthesis show the same parent run ID. The receipt opens the exact published record in the release log |
| UI09 | `node --test test/browser/ui09.test.cjs` | The Telegram fixture rejects one send and returns an unknown outcome for another. SQLite saves failed and unknown work with no provider link. Chrome shows Failed and Delivery unconfirmed before and after reload |
| UI10 | `node --test test/browser/ui10.test.cjs` | Eli opens the saved v1 URL after submitting v2. The page focuses v1 and still shows its original body. The old note has no edit, review, or publish controls. Its replacement link opens exact v2, which Maya can review |
| UI11 | `node --test test/browser/ui11.test.cjs` | Two independent Chrome sessions get the same 24 unique Telegram reply IDs under the same request. The local run took 2,601 ms against a 10-second budget |
| UI12 | `node --test test/browser/ui12.test.cjs` | A child test fails on purpose after focusing a stored message. The parent test finds a valid PNG and a log with UI12 and the exact message ID. The log excludes the fixture secrets and chat body |
| LV01 | `JIDO_ASSEMBLY_OLLAMA_MODEL=lfm3:latest mix test --only scenario:LV01 --trace` | Local Ollama, Jido agent turn, and SQLite. Request `01a201d7-804e-74d0-ba5e-594a7c7c0c26` completed as run `run:triage:lPNMIjiFqWSO193OaHdT8NwVOIWdg12F4zuxDN88keA`. The saved assistant reply used the same thread and exact parent |
| LV02 | `JIDO_ASSEMBLY_OLLAMA_MODEL=qwen3.8:27b mix test --only scenario:LV02 --trace` | Local Ollama. Bridge returned a valid finding that cited request `01a201eb-9eaa-7077-8231-e2717a78b134`. Runbook saved its rollout finding. Synthesis links both saved findings under plan run `run:triage:J8yWqrZoknNIHfxWS3P3xsoWFR9_CllGYb98A9NSjQA` |
| LV03 | `JIDO_ASSEMBLY_OLLAMA_MODEL=qwen3.8:27b mix test --only scenario:LV03 --trace` | Local Ollama saved the findings for request `01a201ec-f264-70e1-a41b-d5f2fbaeaa58` with a limit of four model calls per turn. The release workflow waited for Maya's decision. Her answer advanced the same workflow. Eli reviewed the exact draft version |
| LV04 | `JIDO_ASSEMBLY_OLLAMA_MODEL=lfm3:latest mix test --only scenario:LV04 --trace` | Scripted inference supplies the plan and saved findings. Local Ollama selects the recommendation in the real synthesis turn. Two `lfm3:latest` runs used separate requests `01a201ec-671d-7ac7-a884-f0e4382bc1bf` and `01a201ec-84b2-7006-a3a6-03a7741591dc`. Each verified zero writes before approval and one test release-log write after Eli approved the exact version. The saved receipt identified the published record |
| LV05 | `JIDO_ASSEMBLY_OLLAMA_MODEL=lfm3:latest mix test --only scenario:LV05 --trace` | Local Ollama completed turn `01a201dd-c598-7868-ae73-d5a77ddbf939` in 3,012 ms. Telemetry recorded one model call, zero tool calls and retries, 137 input tokens, and 22 output tokens |
| LV12 | `mix test test/jido_assembly/live_provider_setup_test.exs --only scenario:LV12 --trace` | The guard blocks a missing credential, a missing dedicated target even when a bridge target exists, invalid target syntax, and a missing operator. No connection declaration changes and the provider operation never starts. Valid test setup gives the operation only the dedicated target |

## Live checks

The live checks are opt-in. ExUnit prints `LIVE <scenario> blocked` with
the missing setup when a check skips. For LV01 through LV05, set
`ANTHROPIC_API_KEY` or set `JIDO_ASSEMBLY_OLLAMA_MODEL` to a model already
installed on the local Ollama service. Export the listed variables in
the shell that runs Mix. The test configuration reads the shell
environment. Use only the dedicated chat test targets listed below.

Run the steps that do not need an operator with
`mix test test/jido_assembly/live_provider_acceptance_test.exs --only provider_probe:LV06 --trace`.
Select the ID for one of LV06 through LV11. Each probe removes its own
provider message. The `PROBE` result records only the steps that ran.

- LV06 stays pending. Run `mix test test/jido_assembly/live_provider_acceptance_test.exs --only scenario:LV06 --trace`
  with `TELEGRAM_BOT_TOKEN`, `TELEGRAM_TEST_CHAT_ID`, and
  `ASSEMBLY_LIVE_OPERATOR=1`. Use a dedicated bot and chat with polling
  available. The authenticated `getChat` read matched the dedicated test
  chat. The relay requires an operator reply. The adapter fixture passed
  the exact root, reply, and receipt checks for Maya and Eli. The live probe
  saved receipt `1900` for root `01a201f0-3221-74e3-b05f-ae30e6dd2575`
  and confirmed deletion.
- LV07 stays pending. Run `mix test test/jido_assembly/live_provider_acceptance_test.exs --only scenario:LV07 --trace`
  with `DISCORD_BOT_TOKEN`, `DISCORD_TEST_CHANNEL_ID`, and
  `ASSEMBLY_LIVE_OPERATOR=1`. Enable Message Content for the dedicated bot
  and use Discord's Reply action in the channel. The authenticated channel
  read matched the dedicated test channel. The relay requires an operator reply.
  The live probe saved receipt `1573948036206428272` for root
  `01a201f0-479d-7c18-9c11-bed9904545d5` and confirmed deletion.
- LV08 stays pending. Run `mix test test/jido_assembly/live_provider_acceptance_test.exs --only scenario:LV08 --trace`
  with `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `SLACK_TEST_CHANNEL_ID`,
  and `ASSEMBLY_LIVE_OPERATOR=1`. Enable Socket Mode and channel message
  events for the dedicated Slack app. The authenticated `conversations.info`
  read matched the dedicated test channel. The relay requires an operator
  reply. BR04 and BD01 passed with the Slack adapter fixture.
  The live probe saved receipt `1795328860.150179` for root
  `01a201f0-5d76-7a9b-acb1-27a673ced87a` and confirmed deletion.
- LV09 stays pending. Run `mix test test/jido_assembly/live_provider_acceptance_test.exs --only scenario:LV09 --trace`
  with the Discord setup from LV07. The operator adds and removes one emoji
  on the test attachment. The test checks the downloaded bytes and deletes
  the provider message that holds the file. The live probe downloaded the
  exact 35 bytes for attachment `01a201f1-59ab-7fb3-8afb-8671494761ed`
  from receipt `1573948330567008259`. Discord acknowledged the bot's
  add and remove reaction calls and confirmed deletion. EM10 and BD06
  passed with local adapter fixtures.
- LV10 stays pending. Run `mix test test/jido_assembly/live_provider_acceptance_test.exs --only scenario:LV10 --trace`
  with the Telegram and Discord setup from LV06 and LV07. Two provider
  participants supply the request and evidence in one intake thread. Maya
  opens a release review that links both records. The test checks one Discord
  delivery after the exact version receives approval. The live probe used
  two saved Assembly fixture inputs. Discord receipt `1573949170904080535`
  returned the exact text of approved version
  `release:version:2:01a201f4-6730-7333-bf25-3d500c8ca3b3`.
  The test verified one outbound delivery and confirmed deletion.
  The local bridge and release workflow suites passed 46 tests.
- LV11 stays pending. Run `mix test test/jido_assembly/live_provider_acceptance_test.exs --only scenario:LV11 --trace`
  with `TELEGRAM_BOT_TOKEN`, `TELEGRAM_TEST_CHAT_ID`, and
  `X_TEST_RECIPIENT_ID`. Telegram delivers the test file. The configured
  X binding records the unsupported operation without making an X request.
  The X test recipient is unset. The live probe downloaded the exact 38 bytes
  for attachment `01a201f3-723d-7b99-b5f9-3c7766d71f0d` from receipt
  `1902`. Telegram confirmed deletion. BD07 passed with local adapter fixtures.

The demo switcher remains available for sessions with no authenticated user.
The host must supply authenticated identity for private use outside the demo.
