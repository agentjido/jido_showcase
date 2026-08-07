# Jido Showcase Repository Guide

## Overview

This repository contains independent showcase applications for Jido and its
ecosystem. Each top-level showcase directory owns its source code, dependencies,
runtime configuration, documentation, and tests.

## Runtime Baseline

- Keep the supported Elixir and Erlang/OTP versions explicit in each showcase.
- Register each supported runtime pair in `.github/workflows/ci.yml`.
- Do not make one showcase depend on another showcase directory.

## Canonical Commands

Run commands from the showcase directory:

```sh
mix deps.get
mix hex.audit
mix compile --warnings-as-errors
mix test
mix deps.unlock --check-unused
mix deps.audit --ignore-file .mix_audit.ignore
```

Use the project README for application-specific setup and run commands.

## Architecture And Scope

- Keep root files focused on repository-wide discovery, contribution rules,
  dependency automation, and CI orchestration.
- Keep application code and application-specific automation inside its showcase
  directory.
- Add each new Mix showcase to the CI matrix and keep its Dependabot coverage.

## Standards And Conventions

- Use Conventional Commits.
- Keep examples understandable without knowledge of other showcase projects.
- Do not commit generated build output, local data, or credentials.
- Do not modify package `CHANGELOG.md` files for routine work.

## Testing And QA

- Run formatting checks, warnings-as-errors compilation, tests, unused-dependency
  checks, and the Hex security audit for every changed Mix showcase.
- Run application-specific build checks documented by the showcase.
- Do not merge dependency updates without clean CI.

## Release Hygiene And References

Showcases are applications and examples, not Hex release packages. Do not add a
Hex release workflow unless a project is intentionally converted into a package.
See the root `README.md` and each showcase README for setup details.
