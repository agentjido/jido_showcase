# Jido Assembly

`jido_assembly` is the Jido Chat showcase app: agent-native team chat plus a
bridge console, presented with familiar Slack-like chat primitives. It uses
Hologram as the UI layer, Phoenix as the web shell, `jido_messaging` for durable
chat primitives and bridge routing, SQLite for local persistence, Jido
Signal-style events for UI updates, Phoenix Presence for online state,
`jido_chat` adapters for optional Telegram and Discord connectors, and `jido_ai`
for bounded AI participants in chat.

The package module prefix is `Jido.Assembly`.

![Jido Assembly Slack-like chat UI](priv/static/images/assembly-screenshot.png)

## What This Demonstrates

- A responsive Slack-like shell with workspace rail, channels, DMs, timeline,
  composer, reactions, threads, mentions, search, and mobile room switching.
- A seeded `#ops-workflow` room that drops directly into a realistic incident
  flow with humans, narrative agents, provider-shaped messages, and a workflow
  approval card.
- Durable rooms, participants, messages, reactions, and thread replies through
  `jido_messaging` and SQLite.
- Hologram realtime broadcasts carrying compact `jido.messaging.*` signal
  metadata after durable writes commit.
- Optional live Telegram and Discord bridge setup using `jido_messaging`
  `BridgeConfig`, `RoomBinding`, and `RoutingPolicy` records. Without
  credentials, seeded demo traffic keeps the app usable.
- Three seeded ops agents, Triage Agent, Bridge Agent, and Runbook Agent, that
  can run a safety-capped agent round when `ANTHROPIC_API_KEY` is present.
- A thin Phoenix web layer: Phoenix hosts Hologram, health checks, static
  assets, and Presence integration while the chat behavior lives in the app
  context.
- A developer inspector that shows how Hologram, `jido_messaging`, Jido Signal,
  SQLite, `jido_chat`, adapters, bridge delivery metadata, and Assembly
  responsibilities fit together for the active room.

## Run

```sh
mix setup
mix holo
```

Then open [`localhost:4000`](http://localhost:4000).

Use `mix holo` instead of `mix phx.server` when working on Hologram pages. In
dev and test, Hologram only starts when `HOLOGRAM_START=1`, which `mix holo`
sets for you.

If another local app is already using port 4000:

```sh
PORT=4002 mix holo
```

Assembly stores local demo state in `data/jido_assembly.sqlite3`. Delete that
file if you want to reset the demo workspace.

The default app works without connector credentials. To enable live connector
routing, set any supported connector pair before starting the server. Runtime
configuration is loaded from `.env` via Dotenvy, so local demos do not need
shell exports:

```sh
cp .env.example .env
mix holo
```

### Telegram

1. Create a bot with BotFather and put the token in `.env`:

   ```sh
   TELEGRAM_BOT_TOKEN=123456:bot-token
   ```

2. Send a message to the bot, or add the bot to the group/channel you want to
   bridge.

3. Fetch the chat id:

   ```sh
   curl "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates"
   ```

   Copy the `message.chat.id` value into either Telegram target env var:

   ```sh
   TELEGRAM_TEST_CHAT_ID=-1001234567890
   # or
   TELEGRAM_BRIDGE_CHAT_ID=-1001234567890
   ```

4. Restart `mix holo`. The sidebar should show `Telegram` as `live`, local
   `#ops-workflow` messages will fan out to Telegram, and inbound Telegram
   messages will persist back into the same canonical room.

### Discord

1. Create a Discord application and bot in the Discord Developer Portal. Enable
   the bot's Message Content intent so the gateway can read message bodies.

2. Invite the bot to your test server with access to the target channel. It
   needs to view the channel, read message history, and send messages.

3. Copy the bot token and channel id into `.env`:

   ```sh
   DISCORD_BOT_TOKEN=discord-bot-token
   DISCORD_TEST_CHANNEL_ID=123456789012345678
   # or
   DISCORD_BRIDGE_CHANNEL_ID=123456789012345678
   ```

   `DISCORD_PUBLIC_KEY` is optional for this demo path; it is only needed for
   Discord webhook/interactions flows.

4. Restart `mix holo`. The sidebar should show `Discord` as `live`, local
   `#ops-workflow` messages will fan out to Discord, and inbound Discord
   channel messages will persist back into the same canonical room.

Connector setup is per-provider. If only Telegram is configured, Telegram runs
live and Discord stays in seeded demo mode. If neither is configured, the app is
still fully usable with provider-shaped demo traffic.

To try live AI agent actions, add an Anthropic key before starting the server:

```sh
cp .env.example .env
# edit .env and set ANTHROPIC_API_KEY
mix holo
```

Open the default `#ops-workflow` room, keep `Safety cap` enabled, type a
question in the ops agent prompt, and click `Ask`. Each human prompt can be
continued for two agent rounds; ask a new question to restart the discussion.
Without `ANTHROPIC_API_KEY`, only live agent actions are disabled.

## Dependency Note

Assembly depends on released Hex packages for Hologram, `jido_messaging`, and
the optional Telegram and Discord chat adapters. Hologram `0.9.2` includes the
reflection fix for Erlang-compiled BEAM modules that use Elixir-style module
names, such as `Luerl`. `jido_messaging` `1.1.0` includes the SQLite
persistence, presence, and signal helper APIs that Assembly exercises.

The Phoenix-generated `heroicons` asset dependency still uses Tailwind Labs'
optimized SVG checkout from GitHub because `assets/vendor/heroicons.js` reads
the `deps/heroicons/optimized` file tree directly.

## Code Shape

- `app/` contains Hologram pages, components, reducers, and server command
  handlers.
- `lib/jido_assembly/` contains the Assembly backend context, bridge setup,
  read projections, mentions, seeds, messaging integration, Presence adapter
  configuration, Jido AI agent orchestration, and developer inspector data.
- `lib/jido_assembly_web/` stays thin: endpoint, router, Phoenix Presence,
  Hologram presence notifier, and signal presentation for the UI.
- `jido_messaging` owns reusable messaging primitives, bridge configs, room
  bindings, routing policies, and the SQLite adapter. Assembly owns the
  Slack-like product choices and demo read models.

## Testing Story

Assembly now has Hologram-focused ExUnit coverage in
`test/jido_assembly/pages/assembly_page_test.exs`. These tests exercise the
parts of Hologram that are most testable today: page `init/3`, template
evaluation, client `action/3` state transitions, server `command/3` handling,
and queued Hologram broadcasts.

The local suite also checks the Assembly chat context, mentions, Presence
adapter, connector setup, signal presenter, and wiring to the upstream
`Jido.Messaging.Persistence.SQLite` adapter. Adapter-level durability tests
belong in `jido_messaging`; Assembly should prove that the demo uses those
primitives cleanly rather than duplicating low-level persistence coverage.

Compared with Phoenix LiveView testing, this is lower-level. Hologram actions
and commands are easy to unit test because they return `%Hologram.Component{}`
and `%Hologram.Server{}` structs, but Hologram does not currently provide a
LiveViewTest-style DOM/event DSL for full in-process interaction tests.

Compared with Playwright, these tests are faster and more deterministic, but
they do not prove browser behavior, CSS/layout, JavaScript interop, SSE
delivery, or cross-tab realtime updates. Keep Playwright for the end-to-end
checks that matter to a chat product: two browser sessions, realtime sends,
room creation propagation, mobile layout, focus/keyboard behavior, and visual
overflow.

`Hologram.Test.setup/0` exists for browser/feature tests, but the current
feature-test story is still not as mature as Phoenix LiveView's built-in test
ergonomics. Assembly keeps a small Hologram prune compile task so server-only
modules stay out of the client compiler path, while the upstream Hologram pin
handles Erlang-compiled transitive modules correctly.

## Intentional Non-Goals

- Full Slack API compatibility
- Production authentication, authorization, billing, or compliance controls
- File uploads, huddles, workflows, apps, Canvas, Lists, or enterprise admin
- Full connector administration UI beyond the small status surface and
  developer inspector

See `ROADMAP.md` for a fuller product and platform roadmap against Slack-like
alternatives.
