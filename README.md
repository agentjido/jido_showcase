# Jido Showcase

Jido Showcase is a collection of standalone projects that demonstrate how to
build practical applications with Jido and related Elixir tools.

Each showcase has its own source code, dependencies, setup instructions, and
tests. You can open one project without having to build or run the others.

## Showcases

| Project | What it demonstrates | Main tools |
| --- | --- | --- |
| [Jido Assembly](jido_assembly/) | Agent-native team chat, durable messaging, bridge routing, and AI participants in a Slack-like workspace | Jido, Hologram, Phoenix, SQLite |

More standalone showcases will be added over time.

## Run a Showcase

Enter the project directory and follow its README. For example:

```sh
cd jido_assembly
mix setup
mix holo
```

The projects do not share a build step or runtime. Keep project-specific
configuration, documentation, and tests in the project directory.

## Verify A Showcase

Before you open a pull request, run the standard checks from the showcase
directory:

```sh
mix deps.get
mix hex.audit
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix deps.unlock --check-unused
mix deps.audit --ignore-file .mix_audit.ignore
```

CI runs these checks for each supported Elixir and Erlang/OTP pair. Applications
can also define build checks for their UI or production assets.

## Add a Showcase

Create a new top-level directory with a clear README and all files that the
project needs to run independently. If the project uses a package ecosystem
that is not already in `.github/dependabot.yml`, add an update entry for that
ecosystem. Add the project and its supported runtime pairs to the CI matrix.

## Dependency Updates

Dependabot checks the Mix manifest in each top-level showcase directory every
week. Its directory pattern includes new top-level Mix projects automatically.
Related Phoenix and Jido ecosystem updates are grouped to reduce lock-file
conflicts.
