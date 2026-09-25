# GitHub OAuth App settings

GitHub → Settings → Developer settings → OAuth Apps → Jev my PR

| Field | Value |
|---|---|
| Application name | Jev my PR |
| Homepage URL | http://localhost:3000 (your deployed URL later) |
| Application description | see below |
| Authorization callback URL | http://localhost:3000/auth/github/callback |
| Logo | `oauth-app-logo.png` (1024×1024) or `oauth-app-logo-512.png` |
| Badge background color | `#18222E` |

## Application description

> Jev my PR triages your pull requests. Pick a repository and a pull request, and Jev reads the changes and tags it: needs a human review, an LLM review is enough, or no review needed. It only reads your repositories and pull requests. GitHub asks for full repository access because that is the only way to read private repositories; Jev my PR never pushes code, comments, or changes settings.

The logo is rendered from `design/icons/github-app-logo.svg`:

```sh
rsvg-convert -w 1024 -h 1024 design/icons/github-app-logo.svg -o design/github/oauth-app-logo.png
magick design/github/oauth-app-logo.png -resize 512x512 design/github/oauth-app-logo-512.png
```
