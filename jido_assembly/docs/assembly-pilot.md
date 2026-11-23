# Run an Assembly team pilot

Assembly has a local demo and a separate pilot for one team. The pilot starts
with **#general** and a roster that you control. Team members can create shared
channels, post, reply, react, search, and open links to exact messages.

## Prepare the team roster

Generate a different access key for each member on a trusted machine.

```sh
elixir -e '
  key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  IO.puts("Access key " <> key)
  IO.puts("SHA-256 " <> Base.encode16(:crypto.hash(:sha256, key), case: :lower))
'
```

Give each member their user ID and access key through a secure channel. Store
the SHA-256 digest in the roster. Keep the roster outside the Git checkout
and restrict file access to the operator and the application user.

```json
[
  {
    "id": "user:ada",
    "name": "Ada Turner",
    "key_sha256": "<64 hexadecimal characters>"
  },
  {
    "id": "user:lee",
    "name": "Lee Chen",
    "key_sha256": "<64 hexadecimal characters>"
  }
]
```

User IDs have the form `user:name`. The part after `user:` starts with a
lowercase letter and can contain lowercase letters, digits, hyphens, and
underscores. Use stable IDs. Names can change. The demo administrator and
agent handles are reserved. The roster supports up to 50 accounts.

## Start Assembly locally

Run these commands from `jido_assembly`. Use an absolute path for the roster
and a dedicated SQLite file for the team. Assembly rejects a database from
the other mode.

```sh
mix setup
export JIDO_ASSEMBLY_ROSTER=/path/to/roster.json
export JIDO_ASSEMBLY_PILOT_DB=/path/to/team.sqlite3
mix holo
```

Open [Assembly on localhost](http://localhost:4000). Sign in with a roster
user ID and its access key. Use a second browser session for a second user.
Sign-in preserves room and message IDs from an incoming link.

For self-hosting, run one application node behind HTTPS. Production startup
requires the pilot roster and database, plus `SECRET_KEY_BASE` and the
appropriate `PHX_HOST` and `PORT`. Configure the proxy to forward the
HTTPS scheme and stream Hologram events. Use `GET /health` for a basic
process check. The production cookie requires HTTPS.

## Operate the pilot

- Add a member to the roster and restart. The member gets access to existing
  shared channels. To remove a member or rotate a key, update the roster and
  restart. Members sign in again after a restart. Sessions expire after
  12 hours.
- Stop Assembly before copying its SQLite database. Keep the roster and the
  database backup in protected storage. To restore, start against a copy of
  the backup using the correct roster.
- Agents start disabled. Set `JIDO_ASSEMBLY_PILOT_AGENTS=1` and configure a
  model to enable normal `@triage` mentions. The seeded release review and
  automatic provider setup are demo features. Model and provider setup for
  a team release needs its own review and validation.

## Verify the pilot

```sh
mix test
MIX_ENV=test mix run --no-start scripts/pilot_rehearsal.exs
MIX_ENV=test mix run --no-start scripts/pilot_rehearsal.exs --load
```

The rehearsal starts a fresh pilot, stores chat between two people, restores
a backup, and proves that it retains the same reply and reaction. The load
option runs 25 simulated senders at 10 posts per second in one room and then
across five rooms. Set `ASSEMBLY_PILOT_LOAD_SECONDS=60` for a longer run.
The report measures the local send call through storage acknowledgment.

For a browser check, sign in as two roster members in separate sessions.
Send a message from the first account. From the second account, add a reaction
and reply in the thread. Follow the reply link from a fresh page and verify
that the correct thread and reply open. Sign out and reload the link to check
that Assembly asks you to sign in.
