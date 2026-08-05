# Hologram UI Source

This directory contains Hologram components, layouts, and pages that are
compiled into the Assembly client/server UI layer. The Phoenix backend, chat
context, SQLite persistence wrapper, and OTP application stay in `lib/`.

Hologram documents `app/` as an optional organization style, not a framework
requirement. `mix.exs` includes both `app/` and `lib/` in `elixirc_paths/1` so
Hologram can compile `app/components/*`, `app/pages/*`, and `app/layouts/*`
alongside the regular Elixir modules. Keeping these files outside `lib/` makes
the demo boundary explicit:

- `app/`: Hologram UI modules and page reducers.
- `lib/`: backend context, messaging integration, persistence, endpoint, and
  startup supervision.
