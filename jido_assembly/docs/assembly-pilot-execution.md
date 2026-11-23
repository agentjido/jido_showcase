# Assembly pilot execution

The [pilot plan](plans/2026-11-22-0944-assembly-pilot-plan.md) sets the scope.
The [pilot guide](assembly-pilot.md) gives the commands for users and operators.

## The 30 rounds

The rounds share verification runs. Each row records the condition that was
checked and the change or evidence from that round.

| Round | Plan and iteration | Verification result |
| --- | --- | --- |
| 01 | Measure the starting suite before changing the app. | `mix test --seed 0` reported 159 passing tests and 18 exclusions. |
| 02 | Check the existing changes before applying the pilot patch. | Scoped Git inspection identified existing UI and suite work. The pilot was added on top of it. |
| 03 | Define a one-team pilot and identify later release decisions. | The plan has 30 checks, six implementation units, and links to current Assembly evidence. |
| 04 | Add a named roster for real user identities. | The roster test reads a validated account. Startup uses the roster for sign-in and membership. |
| 05 | Require stable IDs and usable display names. | The roster tests reject missing namespaces, agent IDs, malformed IDs, and empty names. |
| 06 | Read a credential digest for each person. | The roster test rejects raw access keys in the digest field and checks valid and invalid login credentials. |
| 07 | Prevent two accounts from sharing one ID or key. | The roster test rejects duplicate IDs and key digests. |
| 08 | Reject empty and malformed rosters and keep keys out of request logs. | The roster tests reject bad input. The controller test confirms that Phoenix filters the access key. |
| 09 | Require a dedicated pilot database. | Runtime config rejected a start with the demo database path before the app started. The browser pilot started on a temporary file. |
| 10 | Bind each database to its workspace mode. | The storage tests reopen the same mode and reject reuse in the other mode. |
| 11 | Prepare an empty shared channel. | The pilot rehearsal confirmed that a fresh store has one room and no chat history. |
| 12 | Put roster names on messages and in the workspace. | The rehearsal checked the projected profile. The browser showed Ada and Lee by name. |
| 13 | Reconcile shared memberships after a roster change. | The first restore found that membership changes could run before the Room Agent was active. A startup reconciliation check fixed the order. The new member joined a restored channel. |
| 14 | Serve a pilot sign-in page and health response. | The controller suite and internal browser rendered sign-in on a fresh visit. The pilot health route returned `ok`. |
| 15 | Put the session gate before both web routers. | The controller suite denied anonymous page, command, identity, stream, and handshake access. |
| 16 | Require CSRF on credential submission. | A POST without the browser token returned HTTP 403. |
| 17 | Renew identity after successful login. | The controller test got a new session ID and confirmed that the prior ID failed validation. |
| 18 | Expire sessions and their streams. | The session test used a short lifetime and observed stream termination and denied subsequent access. |
| 19 | Revoke one session at sign-out. | The session test closed that session's stream. A second session stayed valid. The controller denied requests with the former cookie. |
| 20 | Verify the supported live transport boundary. | The anonymous stream and legacy socket tests passed. The browser received live messages through the pilot connection. |
| 21 | Hide demo account switching and review controls in pilot mode. | The restored pilot showed the named user and sign-out with the demo switcher and review routes unavailable. |
| 22 | Attribute Presence to the authenticated viewer. | The Hologram test sent a different ID in the command. Only the session user appeared online. |
| 23 | Separate demo review and provider effects from pilot agent mentions. | The pilot rehearsal reported provider setup disabled and no queued run when agents were off. A scripted Jido turn then replied to the exact trigger with agents enabled. |
| 24 | Check native shared-channel chat across two accounts. | The rehearsal checked posting, reacting, and searching. The browser showed the same post and reaction for both users. |
| 25 | Preserve exact thread links through sign-in and reject arbitrary redirects. | The controller preserved only room and message parameters. The browser reopened the exact reply after a restart and a new login. |
| 26 | Document pilot setup, membership changes, and operator recovery. | The guide gives the tested startup and rehearsal commands and keeps credentials out of Git. |
| 27 | Rehearse an offline SQLite backup and restore. | The restored store kept both message IDs, the thread parent, and the reaction. A prior session failed after restart. |
| 28 | Add a paced SQLite and Runtime workload and run both room layouts. | Each 60-second run acknowledged 600 posts. All 1,200 IDs were unique within their run and present in ordered history. |
| 29 | Exercise the actual Hologram page in two internal browser sessions. | Ada sent a live post. Lee reacted and replied. Ada opened the saved reply after restart and was asked to sign in when she opened it after sign-out. |
| 30 | Run final Assembly and dependency gates. | A concurrent fixture had assumed model response order. Its test now checks both responses and their exact run and message IDs without assuming dispatch order. The default suite passed and the dependency audits found no vulnerabilities. |

## Load results

Run with Elixir 1.19.5 and OTP 28 on the local development machine. Each profile
used 25 simulated senders, 10 posts per second, and one SQLite database.
The measurement covers the local send call through storage acknowledgment.
It provides a local baseline for that workload.

| Workload | Posts | p95 | p99 | Maximum send scheduling delay |
| --- | ---: | ---: | ---: | ---: |
| One busy room | 600 | 68.33 ms | 194.04 ms | 5 ms |
| Five rooms | 600 | 79.34 ms | 83.63 ms | 6 ms |

```sh
ASSEMBLY_PILOT_LOAD_SECONDS=60 MIX_ENV=test mix run --no-start scripts/pilot_rehearsal.exs --load
```

## Final checks

- `mix test --seed 0` reported 176 passing tests and 18 exclusions.
- Formatting, warnings-as-errors compilation, the Hologram build, assets,
  and the unused lock-entry check passed.
- `mix hex.audit` and `mix deps.audit --ignore-file .mix_audit.ignore` passed.
  Hex reported that a pre-existing advisory exception has no match.
- The internal browser exercised two local accounts. The workspace and
  access controls received a self-check.
- The load harness measures the Runtime and SQLite path. Browser latency
  under load, deployed HTTPS behavior, and configured live providers and
  inference are open checks.
