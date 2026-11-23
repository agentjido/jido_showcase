---
title: Assembly team pilot
type: implementation-plan
date: 2026-11-22
last_reviewed: 2026-11-22
artifact_contract: kata-plan/v1
artifact_readiness: implementation-ready
domain: software
execution: code
product_contract_source: direct-request
---

# Assembly team pilot

## Goal Capsule

- Objective. Give a small team a working chat workspace on Jido Chat and keep Assembly useful as an integration showcase.
- Means. Deliver a self-hosted, single-team pilot and work through 30 bounded plan, change, and check rounds.
- Authority. Local code, documents, test databases, and test targets.
- Stop conditions. Complete the local checks, or record the exact condition that blocks a round.
- Next executor. The Assembly maintainer can rerun the commands in the execution record.

## Product Contract

### Summary

The first working release target is an authenticated team chat with durable rooms, threads, reactions, and a path to scoped agent work. The existing demo also serves as a test of Jido Chat.

### Problem Frame

The demo gives seeded identities control of the workspace. A team needs its own users, data, and sign-in before it can depend on chat history or act on agent output.

### Actors

- Team members sign in, post, reply, and react.
- An operator manages the pilot roster, configuration, and backups.
- Agents participate through the existing Jido execution path when the operator configures them.

### Requirements

| ID | Requirement |
| --- | --- |
| R1 | A person can sign in under their own identity. HTTP and Hologram requests use the same server-validated identity. |
| R2 | The pilot uses its own SQLite file and starts without sample conversations. |
| R3 | Members can use shared channels, post, reply, react, reload, and find the same messages. |
| R4 | The seeded demo retains its release review workflow and provider fixtures. |
| R5 | Keep a rerunnable check for each of 30 rounds and report the result of the complete local run. |

### Key Flows

- The operator supplies a team roster and a dedicated database path. The app starts and prepares the shared channel.
- Two people sign in, exchange a message and reply, add an emoji reaction, and reload the thread.
- A team member signs out. A later request with their former session fails.
- In demo mode Maya and Eli can exercise the seeded release workflow and follow the links from Needs you and Board.

### Acceptance Examples

- A visitor without a session cannot read the workspace, start a command, or subscribe to its live stream.
- A message from one member appears to another under the same ID. Replies keep the original parent after restart.
- A fresh pilot database contains the shared starter channel and zero sample chat messages.

### Success Criteria

Local automation proves the examples, the default integration suite passes, and a two-user browser run exercises the pilot's real entry points. The execution record identifies any unchecked or deferred behavior.

### Scope Boundaries

Target one private team and one application node first. Broader product work includes invitations, self-service accounts, private channels and new DMs, configurable approval owners, provider administration, multiple workspaces, and a hosted service.

### Key Decisions

- Treat the self-hosted pilot as a proposed first release boundary.
- Use operator-generated access keys and stable identities for the pilot. The operator can rotate a key or remove a person by changing the roster and restarting.
- Keep demo evidence in the demo workspace. The pilot can opt in to ordinary mention-triggered agent work using its own rooms and model settings.

### Rejected Alternatives

An initial multi-workspace migration would expand every room, identity, and event boundary before the first team can use the app.

### Dependencies

The existing Phoenix and Hologram embedded router, Jido Chat Runtime, and Exqlite dependencies support the pilot. A browser run also needs the local Hologram asset toolchain.

### Outstanding Questions

Select the long-term identity provider, hosting model, and first live provider after the private pilot. Actual provider validation needs configured targets.

### Sources

- [Assembly README](../../README.md)
- [Assembly roadmap](../../ROADMAP.md)
- [Integration showcase plan](assembly-integration-showcase.md)
- [Multiplayer verification](../multiplayer-verification.md)

## Planning Contract

### Product Contract Preservation

The pilot adds a work mode alongside the existing integration example. Keep stable room and thread IDs, the exact review links, and fixture behavior.

### Current System

`AssemblyPage` reads a Hologram session and can fall back to a seeded user. The endpoint invokes Hologram before the Phoenix router. `Seeds` provisions sample rooms and history on startup. `Chat` sends to Jido Chat Runtime, which persists in `ChatStorage` and emits committed facts for the Hologram notifier.

### Target System

The endpoint validates pilot sessions before Hologram handles pages, commands, or streams. The pilot roster supplies profiles and membership, and the pilot database contains the team's chat. One shared channel is available on first use.

### Key Technical Decisions

- KTD1 (R1). The endpoint owns access control before Hologram routing. The Hologram session supplies the current user to command handlers.
- KTD2 (R1). Use random access keys with a SHA-256 digest in the roster and bounded server-side sessions. A process restart ends existing sessions.
- KTD3 (R2, R3, R4). Persist the database mode and keep pilot initialization separate from demo seeding. Use Jido Chat room and history APIs in both modes.
- KTD4 (R4, R5). Reuse the default suite and fixture providers. Use a separate database and explicit runtime flags for pilot browser and load checks.

### System Boundaries and Change Surface

| Surface | Change |
| --- | --- |
| Runtime config and application supervision | Select mode, validate the roster, and start with the database for that mode. |
| Phoenix endpoint and session routes | Provide sign-in and sign-out and pass trusted identities to Hologram. |
| `Seeds`, `Chat`, and Hologram | Prepare and display pilot profiles, rooms, and chat. Keep the demo workflow in demo mode. |
| Tests and operator instructions | Cover behavior, data recovery, and rollout on the local toolchain. |

### Implementation Units

| Unit | Requirement | Depends on | Result and verification |
| --- | --- | --- | --- |
| U1 | R4, R5 | | Record baseline, current routes, and reproducible checks. The default suite provides counts. |
| U2 | R1, R2 | U1 | Load a valid roster and reject ambiguous configuration. Exercise valid, empty, duplicate, and malformed configuration. |
| U3 | R2, R3 | U2 | Start a blank team workspace and provision shared channels. Restart without reseeding messages or losing records. |
| U4 | R1 | U2 | Sign in and out with bounded server-side sessions. Check route access and the Hologram identity boundary. |
| U5 | R3, R4 | U3, U4 | Exercise the chat commands, clear demo-only controls from the pilot, and rerun the demo regression suite. |
| U6 | R3, R5 | U5 | Run browser, persistence, and load checks. Publish local instructions and the round record. |

### Work Graph

U1 → U2 → U3 and U4 → U5 → U6. U3 and U4 can proceed independently before their common browser check.

### Verification Contract

Each round starts with a behavior and a check. Update the candidate or test evidence, run the check, and write the result in [Pilot execution](../assembly-pilot-execution.md).

| Rounds | Plan | Expected evidence |
| --- | --- | --- |
| 01–03 | Check the baseline suite, preserve current work, and verify the scope and plan. | Test counts, a scoped diff, and valid plan references. |
| 04–08 | Validate user records, stable IDs, unique keys, secret handling, and invalid configuration. | Roster and credential tests. |
| 09–13 | Select a dedicated database, lock its mode, provision the general channel, display real profiles, and reconcile shared membership. | Temporary-store and chat tests. |
| 14–20 | Serve sign-in, gate routes, check CSRF, renew identity, expire sessions, revoke sessions, and verify stream and command access. | Endpoint and session tests. |
| 21–25 | Hide the demo switcher, attribute Presence to the session, separate sample workflows, check real multi-user chat, and confirm exact links after reload. | Hologram and browser tests. |
| 26–30 | Document operation, rehearse restart and backup, run a local workload, check two-user behavior in the browser, and rerun final gates. | Operator guide, recovery and load evidence, browser result, final build and test results. |

Run commands from `jido_assembly`.

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix deps.unlock --check-unused
mix hex.audit
mix deps.audit --ignore-file .mix_audit.ignore
mix assets.build
HOLOGRAM_START=1 mix compile --force
```

### Rollout and Recovery

Start the pilot with a new SQLite file. Stop the app before a file copy or restore. Keep the two mode databases separate. Rotate credentials by replacing the affected digest and restarting. Measure the local workload before setting a production latency objective.

### Risks and Assumptions

- The first team uses one node behind HTTPS. The pilot does not provide hosted tenant isolation.
- Existing demo fixtures contain sample review evidence. Keep them out of the pilot.
- Endpoint checks and the Hologram stream path need direct exercise. The test suite alone cannot prove browser reconnection.

### Open Planning Decisions

Identity-provider integration, production hosting, and live provider selection belong to the operator after local evidence. They do not block the pilot.

### Definition of Done

The plan and execution record cover all 30 rounds. The working pilot passes its local requirements and retains the showcase regression coverage. Report each external or production check whose result is still open.

### Planning Sources

- `lib/jido_assembly_web/endpoint.ex` and `app/pages/assembly/commands.ex`
- `lib/jido_assembly/chat.ex`, `lib/jido_assembly/chat_storage.ex`, and `lib/jido_assembly/seeds.ex`
- `deps/hologram/lib/hologram/runtime/session.ex`

## Adapter Results

- Markdown is canonical in this file.
- HTML and Beadwork were outside the requested output.
