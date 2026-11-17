# Assembly V3 UI completion

Status: implementation active.

## Objective

Complete the Jido Assembly V3 browser surface before final QA. Mobile users
must have access to the same required workspace controls and V3 evidence as
desktop users. Controls that do not have an Assembly action must not look
active. Browser QA must use a deterministic Agent responder and must not call a
live model or provider.

## Work

1. Add a small-screen workspace panel for search, Room creation, demo-user
   selection, connector status, and Room navigation.
2. Add a small-screen developer panel for the current Room, Runtime, storage,
   connection, binding, Signal, and message evidence.
3. Add clear open, close, Escape, and focus-return behavior for both panels.
4. Remove inactive formatting, attachment, clip, voice, and overflow controls
   from the composer and message rows.
5. Add an explicit scripted Agent mode selected by environment configuration.
   Keep live model mode as the default.
6. Add reducer and page tests. Run Assembly checks and an Elixir design review.
7. Run desktop, tablet, mobile, two-client, persistence, presence, and scripted
   Agent browser QA. Record screenshots and browser errors.

## Verification

- `mix precommit`
- `HOLOGRAM_START=1 mix compile --force --warnings-as-errors`
- Browser viewports: 1440 by 900, 1024 by 768, and 390 by 844
- Room creation, message, reaction add and remove, thread reply, search,
  demo-user change, scripted Agent response, reload, and two-client sync
- Mobile workspace and inspector panels
- No console error, runtime exception, failed request, or page overflow

Live provider and model calls are excluded. Remote writes and releases are
excluded.
