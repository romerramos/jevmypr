# AGENTS.md

Instructions for coding agents (Codex, Claude Code, Cursor, …) and humans working on Jev my PR.
If an `AGENTS.local.md` exists next to this file, read it too: it holds this machine's private details
(server paths, restart commands) and is never committed.

## What this is

A Rails 8 app: sign in with GitHub, pick a pull request, and [Jev](https://typesafe.ai) tags it for a human
review, an LLM review or no review. See [README.md](README.md) for the product and the data it handles.

- GitHub and Jev are wrapped in `app/adapters/github/client.rb` and `app/adapters/jev/client.rb`;
  `app/services/pr_review_decider.rb` asks the question; `app/models/jev_allowance.rb` holds the usage limits.
- UI: Hotwire (Turbo Frames, small Stimulus controllers), Tailwind 4 + daisyUI 5 with the custom `triage`
  themes in `app/assets/tailwind/application.css`, Lucide icons. Prefer plain links, forms and Turbo over custom
  JavaScript, and nested, resourceful routes.
- Secrets come from credentials or env vars through `AppSecrets` (`config/initializers/app_secrets.rb`); see
  `config/credentials.example.yml`. Never commit credentials, keys or real tokens.

## Working on it

```sh
bin/setup                                  # first time
bin/dev                                    # run it
bin/rails test && bin/rails test:system    # all tests (GitHub and Jev calls are stubbed with WebMock)
bin/rubocop && bin/brakeman --no-pager     # lint and security scan (CI fails on any Brakeman warning)
```

- Keep CI green: run the tests, RuboCop and Brakeman before pushing. When piping test output, use
  `set -o pipefail` so a failing suite isn't hidden.
- Commits are authored by the maintainer only: **no `Co-Authored-By` or other AI attribution lines** in commit
  messages or pull requests.
- Check UI changes on a phone width and on desktop, in light and dark mode.

## Releasing

Releases use [semantic versioning](https://semver.org). The current release is in `VERSION`, each release is a
tag `vX.Y.Z` on `main` with a GitHub Release, and the app shows the version next to its logo.

When asked to "release this" (or similar):

1. Run `bin/release --plan`. It shows the last release, the candidate versions and every commit since.
   Read the commits, and the diff where the impact isn't obvious (`git diff <last tag>..HEAD`).
2. Decide the bump:
   - **Breaking**: someone running or self-hosting the app must act, e.g. a new required secret or setting, a
     removed feature or route, a data-destroying migration, or a changed deploy step.
   - **Feature**: something new a user can do or see.
   - **Fix**: bug fixes, polish, copy, refactors, dependencies, docs, tests.

   While the version is **0.x**: breaking → `minor`, feature or fix → `patch`.
   From **1.0.0**: breaking → `major`, feature → `minor`, fix → `patch`.
3. Tell the user the proposed version and a one-line reason, and **wait for their OK** (they may override it).
4. Write the release notes to a temporary Markdown file: a one-sentence summary, then short sections such as
   *New*, *Improved*, *Fixed*, and *Upgrade notes* (migrations, new secrets or settings; say "none" if none).
   Write for users, not commit hashes.
5. Run `bin/release <patch|minor|major> --notes <file>`. It checks you're on a clean, pushed `main` whose last
   commit passed CI, bumps `VERSION`, commits "Release vX.Y.Z", tags, pushes and publishes the GitHub Release.
   If CI is still running, wait for it; don't use `--skip-ci` unless the user asks.

## Deploying a release

On a server that runs the app from a git checkout, when asked to "update to the latest release" or
"update to vX.Y.Z":

1. Run `bin/update` (latest) or `bin/update vX.Y.Z`. It fetches tags, checks out that release, installs gems,
   runs migrations and precompiles assets (in production).
2. Restart the app with this server's restart command (see `AGENTS.local.md`).
3. Check the version next to the logo, or `cat VERSION`.

Rolling back is the same command with the previous tag. Read the release's *Upgrade notes* first: a new
secret or setting has to be in place before restarting.
