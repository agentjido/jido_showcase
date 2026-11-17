# Jido Assembly V3 backend migration plan

Status: Active

Date: 2026-11-17

## Goal

Move Jido Assembly from the retired messaging package and split Jido V2 packages to the
consolidated Jido V3 and Jido Chat V3 stack. Keep the current product behavior,
use a new SQLite database, and remove all production and test references to
the retired messaging package.

## Baseline

- The clean Assembly checkout passes 56 tests.
- The application uses Jido 2.4, Jido AI 2.4, Jido Chat 1.2, and Jido
  Messaging 1.1.
- `Jido.Assembly.Messaging` owns the old process tree and SQLite database.
- Three AI participants use the Jido V2 `ask_sync` interface.
- Telegram and Discord use released V1 adapters.

## Migration constraint

The retired messaging package requires Jido V2. Consolidated Jido Chat requires Jido V3.
These dependency graphs cannot run in one Mix application. The dependency
change and removal of the old process tree are therefore one atomic compile
boundary. Work remains grouped by the approved 5A through 5F slices, but the
first full compile can occur only after the 5C cutover removes every old
runtime module from the supervision tree.

## 5A - Dependencies and consolidated Jido AI

1. Use the same fixed Jido source as Jido Chat core.
2. Use local paths for Jido Chat, Telegram, and Discord.
3. Remove the retired messaging dependency and standalone AI dependency.
4. Add `exqlite` as an Assembly dependency.
5. Move AI configuration to `:jido`.
6. Add a stable Jido namespace.
7. Convert the three participants to the graph-first AI DSL.
8. Use `Jido.start_agent/3` and `Jido.AgentServer.call/3`.
9. Add a deterministic inference client for tests.
10. Remove generated Jido instance calls and direct `ReqLLM` key reads.

Checks:

- Agent definition and preflight tests pass.
- Scripted inference tests pass without a provider key.
- Source scans find no split AI dependency or V2 Agent API.
- Run an Elixir design review and fix all accepted findings.

## 5B - Assembly SQLite storage adapter

1. Add `Jido.Assembly.ChatStorage` as one supervised SQLite resource.
2. Use a new V3 database path.
3. Add versioned, Assembly-owned migrations.
4. Add dedicated tables and unique indexes for links, outbox work, rooms,
   Room declarations, memberships, message history, reactions, connections,
   and bindings.
5. Store each value with the Jido JSON codec. Do not store Erlang terms.
6. Implement all ten current Jido Chat storage capabilities.
7. Use exact revision checks through the Jido Chat storage engine.
8. Commit each command batch in one SQLite transaction.
9. Load and validate all stored records during resource startup.

Checks:

- Capability contract tests cover inserts, queries, updates, conflicts,
  cursor bounds, and atomic rollback.
- A resource restart preserves all record types.
- The V3 resource never opens the old Messaging database.
- Run an Elixir design review and fix all accepted findings.

## 5C - Runtime and chat context cutover

1. Add one Room definition and `Jido.Assembly.ChatRuntime`.
2. Start Phoenix Presence, Jido, ChatStorage, and ChatRuntime in the approved
   order.
3. Remove `Jido.Assembly.Messaging`.
4. Move Room creation, membership, posting, history, replies, and reactions to
   public Jido Chat Runtime functions and Room Signals.
5. Convert Jido turn results into Assembly view models. Do not copy the old
   command-result type.
6. Keep profiles, mentions, search, and workspace presentation in Assembly.

Checks:

- Room commands return committed Jido turn evidence.
- Rejected commands do not persist data or publish a committed notification.
- Runtime and storage restart tests preserve durable state.
- Run an Elixir design review and fix all accepted findings.

## 5D - Realtime and presence cutover

1. Replace old PubSub signal subscriptions with one Runtime Bus subscriber.
2. Reread durable state before each Hologram broadcast.
3. Replace the Messaging presence macro with a small Assembly service that
   uses Phoenix Presence sessions and a bounded TTL.
4. Keep presence events separate from durable Room membership.

Checks:

- The notifier reconnects after a Runtime restart.
- Two subscribers read the same committed state.
- Join, heartbeat, multi-session, leave, and expiry tests pass.
- Run an Elixir design review and fix all accepted findings.

## 5E - Provider bridge cutover

1. Replace old bridge configuration with durable connection declarations and
   bindings.
2. Add a host secret resolver for environment references.
3. Keep credential-free Telegram and Discord demo mode deterministic.
4. Use explicit inbound, outbound, or both directions.
5. Use deterministic broadcast routing for outbound bindings.

Checks:

- Demo mode starts without credentials and makes no provider call.
- Durable declarations and bindings recover after restart.
- Selected live checks run only when the required credentials exist.
- Run an Elixir design review and fix all accepted findings.

## 5F - Seeds, tests, and removal

1. Add stable source keys and one seed version.
2. Provision Rooms, memberships, messages, threads, reactions, connections,
   and bindings through public V3 APIs.
3. Make first boot, second boot, and partial recovery deterministic.
4. Preserve all user-created data.
5. Rewrite backend and page-state tests for V3 contracts.
6. Remove old modules, fixtures, compiler exclusions, documentation, and
   namespaces.

Checks:

- Empty boot and second boot create one copy of each seed record.
- Partial recovery completes only missing seed records.
- User data is not changed.
- No provider call occurs during seed work.
- A full source scan finds no retired messaging namespace or standalone
  `jido_ai`, `config :jido_ai`, old generated instance calls, or undeclared
  `ReqLLM` calls.
- Run an Elixir design review and fix all accepted findings.

## Final backend gates

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix deps.unlock --check-unused`
- `mix test`
- `mix deps.audit --ignore-file .mix_audit.ignore`
- `mix assets.build`
- Hologram compilation
- Clean dependency, source, and database-path scans

## Out of scope for this plan

- UI layout and browser QA are Unit 6.
- Mattermost is not in scope.
- Remote Hex deprecation and GitHub archive need separate remote authority.
- No compatibility module or reference implementation is retained.
