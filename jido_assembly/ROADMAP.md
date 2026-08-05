# Jido Assembly Roadmap

Assembly is currently a Slack-like developer demo, not a Slack replacement. The
useful product question is where Assembly should copy the category, and where it
should diverge once Jido-native agents and bridges are added.

## Current Feature Inventory

Implemented now:

- One seeded workspace: `Jido Assembly`
- Multiple channels and direct messages
- Realtime Hologram broadcasts for message sends, replies, reactions, and channel
  creation
- Responsive chat shell with desktop sidebar and mobile room switcher
- Composer, demo user switcher, room switching, unread counters, desktop thread
  panel, and mobile thread drawer
- Developer inspector that makes the Hologram, `jido_messaging`, SQLite,
  `jido_chat`, and Jido responsibilities visible in the UI
- Mentions, reactions, lightweight thread replies, and message search
- Canonical rooms, participants, messages, reactions, and threads stored through
  `jido_messaging`
- SQLite durability through upstream `Jido.Messaging.Persistence.SQLite`
- Hologram action/command tests for core page behavior
- Assembly guard test confirming it uses upstream SQLite persistence

Important gaps:

- No production authentication, authorization, memberships, invites, or workspace
  switching
- No edit/delete, emoji picker, formatting, files, pins, saved items, typing
  indicators, or notification preferences
- No private channel semantics beyond seeded DMs
- No admin, audit log, retention, export, compliance, billing, or enterprise SSO
- No agent runner integration yet
- No adapter bridge UI yet for Slack, Discord, Mattermost, email, or other rooms

## Competitive Baseline

Slack sets the collaboration baseline: fast channels and DMs, threads,
mentions, search, files, reactions, huddles, workflows, apps, Canvas, Lists,
enterprise controls, and AI features. Assembly should not try to match all of
that first. It should match the minimum chat primitives users expect, then win
on Jido-native agent and bridge workflows.

Mattermost is the self-hosted and controlled-deployment reference. It matters if
Assembly needs private infrastructure, compliance, incident workflows, or
government/regulated buyers.

Discord is the realtime community reference. It is stronger on voice, presence,
and lightweight community flow than enterprise workflow. Assembly can learn from
its immediacy without adopting its community-first information architecture.

Microsoft Teams is the bundled-suite reference. It wins through meetings,
documents, calendar, identity, and Microsoft 365 gravity. Assembly should not
compete there directly unless Jido needs a specific enterprise integration path.

## Product Position

After the developer demo, Assembly should become an agent-native team chat and
bridge console:

- Chat rooms are the human interface to Jido Messaging.
- Agents can participate as first-class room members.
- External providers can be bridged into canonical rooms without the UI owning
  provider-specific message shapes.
- Rooms can show operational context: adapter health, workflow runs, source
  events, delivery state, summaries, and next actions.
- The differentiator is not "another Slack", it is "team chat where the agent
  runtime and integration fabric are native".

## Phase 0: Developer Demo Hardening

Goal: keep the current Hologram plus `jido_messaging` demo readable, durable,
and reliable for 5-10 local users.

- Keep Hologram UI state isolated from messaging persistence.
- Keep SQLite durability in `jido_messaging`; Assembly should consume it through
  its app-specific chat context.
- Keep tests layered: Chat context ExUnit, Hologram action/command ExUnit,
  Playwright for browser/realtime/mobile.
- Decide how feature tests should start Hologram with the Assembly patch/prune
  path.
- Continue extracting view modules so the Hologram page stops owning all shaping.

Exit criteria:

- One command runs compile, unit tests, Hologram page tests, and assets.
- Playwright smoke proves two-tab realtime message propagation.
- Room creation, message send, replies, reactions, search, mentions, and SQLite
  restart durability are represented in automated tests.
- The Hologram compiler workaround is documented and reproducible from clean deps.

## Phase 1: Chat MVP

Goal: reach the minimum Slack-shaped experience that a small team can use.

- Durable persistence for memberships and read receipts.
- Real identity: user records, sessions, current user from auth, invite links.
- Channel and DM lifecycle: create, rename, archive, join/leave, membership list.
- Message primitives: edit, delete, soft-delete, reactions, timestamps, delivery
  status, Markdown-ish formatting, code blocks.
- Mentions and notifications: user mentions, channel mentions, unread semantics,
  notification settings, room-level mute.
- Search: recent room search first, then global message search.
- Files: upload, preview, link unfurl skeleton, attachment metadata.

Exit criteria:

- A real user can sign in, create a room, invite another user, chat in realtime,
  leave, return, and see durable history.
- Core message primitives behave consistently across refreshes and two clients.

## Phase 2: Slack-Parity Primitives

Goal: cover expected team-chat workflows before going deeper on agents.

- Threads with reply counts and unread thread state.
- Pins, saved items, bookmarks, and room topic/purpose editing.
- Typing indicators and presence.
- Keyboard shortcuts and command palette through Hologram JS interop.
- Notification routing: in-app, email digest, desktop/browser notification
  permission path.
- Better mobile: room drawer, thread drawer, composer ergonomics, safe areas.
- Accessibility pass: keyboard navigation, focus order, ARIA labels, contrast,
  reduced-motion handling.

Exit criteria:

- Assembly feels familiar to someone fluent in Slack for daily channel, DM,
  thread, and search workflows.

## Phase 3: Jido-Native Differentiation

Goal: make Assembly more useful than a clone for Jido users.

- Room Assistant as an actual agent subscriber, not seeded fixture text.
- Agent participants with capabilities, status, memory scope, and room-specific
  permissions.
- Slash commands backed by Jido actions.
- Workflow messages: runs, approvals, retry buttons, structured outputs, error
  cards, and audit trail links.
- Adapter bridge dashboard in the room context panel: connected providers,
  delivery state, inbound/outbound event IDs, retry controls.
- Cross-provider rooms: Slack channel plus Discord channel plus native Assembly
  room mapped into one canonical `jido_messaging` room.
- Summaries and handoffs: daily room summary, unresolved questions, decisions,
  extracted tasks, and "what changed since I left".

Exit criteria:

- Assembly can host a room where people, agents, and external provider messages
  coordinate around a shared Jido workflow.

## Phase 4: Administration And Trust

Goal: make the product operable beyond a local spike.

- Workspace settings, roles, permissions, and guest access.
- Private channels and scoped DMs.
- Audit logs and admin search/export.
- Retention policy, legal hold hooks, and deletion semantics.
- SSO/SAML/OIDC path, SCIM later if enterprise direction is real.
- Rate limiting, abuse controls, content safety hooks, and attachment scanning.
- Observability: message latency, event bridge lag, failed deliveries, queue
  depth, Hologram connection health.

Exit criteria:

- A team can deploy Assembly with clear operational controls and trust the event
  history.

## Phase 5: Product Expansion

Goal: choose the wedge after the foundation is credible.

- If the wedge is "agent operations", build richer agent timelines, approvals,
  runbooks, incidents, and tool-use transcripts.
- If the wedge is "bridge console", prioritize provider mapping, replay,
  deduplication, conflict resolution, and delivery observability.
- If the wedge is "team chat", continue toward Slack parity: apps, workflows,
  huddles, canvases, lists, enterprise governance, and AI search.

The recommended wedge is agent operations plus bridge console. Slack parity is a
large surface area with little inherent advantage. Jido has a stronger reason to
exist where messages, agents, and provider bridges meet.
