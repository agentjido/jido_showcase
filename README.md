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

## Add a Showcase

Create a new top-level directory with a clear README and all files that the
project needs to run independently. If the project uses a package ecosystem
that is not already in `.github/dependabot.yml`, add an update entry for that
ecosystem.

## Dependency Updates

Dependabot checks the Mix manifest in each top-level showcase directory every
week. Its directory pattern includes new top-level Mix projects automatically.
