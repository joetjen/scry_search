# scry_search

The `search` kind for [Scry](https://github.com/joetjen/scry)
(lang_spec.md §8.5) — a `scry_<kind>` package (impl_spec.md §2).

This bootstrap commit establishes `main` (LICENSE, README, `.gitignore`
only) before `git flow init` creates `develop` from it, per this
project's own git workflow rule (`AGENTS.md`) — everything else
(tooling config, Mix scaffolding, the actual grammar/executor
implementation) lives on `develop`.

Source: <https://github.com/joetjen/scry_search>. Specs live in the
separate [`scry`](https://github.com/joetjen/scry) repository; the
composition machinery this composes against lives in
[`scry_core`](https://github.com/joetjen/scry_core).
