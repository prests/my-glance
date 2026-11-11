# My Glance

A private, Cloudflare Tunnel–hosted [Glance](https://github.com/glanceapp/glance) dashboard at `news.byte-cave.com`. The image is public; dashboard credentials and tunnel credentials are runtime-only secrets.

## Local setup

Install Docker Compose, Node.js (for Prettier), `yamllint` (`pipx install yamllint`), and [Varlock](https://varlock.dev/), then clone the repository and enable its tracked hooks once:

```sh
git config core.hooksPath ./git-hooks
```

Git deliberately does not execute repository code during cloning, so hooks cannot be enabled automatically. The pre-commit hook lints staged YAML with `yamllint` and checks staged YAML, JSON, Markdown, and GitHub Actions files with Prettier. Format files before committing with:

```sh
npx --yes prettier@3.5.3 --write README.md docs .github/workflows config compose.yaml compose.production.yaml
```

Create an ignored `.env.local` with values matching `.env.schema`:

```dotenv
GLANCE_AUTH_USERNAME=your-username
GLANCE_AUTH_PASSWORD=your-long-password
GLANCE_AUTH_SECRET_KEY=replace-with-the-command-output-below
```

Choose the username yourself. Generate the signing key once and keep it stable—changing it invalidates active sessions:

```sh
docker run --rm glanceapp/glance:v0.8.8 secret:make
```

Generate a bcrypt hash without printing the password:

```sh
varlock run -- ./scripts/generate-secrets.sh
```

Copy its sole output (`GLANCE_AUTH_PASSWORD_HASH=...`) into `.env.local`. Start the local stack:

```sh
varlock run -- docker compose up -d --build
open http://localhost:8080
```

Stop it with `varlock run -- docker compose down`. To change the password, update `GLANCE_AUTH_PASSWORD`, rerun the generator, and replace only `GLANCE_AUTH_PASSWORD_HASH`; keep the signing key unchanged.

## Deployment

See [docs/deployment.md](docs/deployment.md) for Oracle, Cloudflare, GitHub Environment secrets, deployments, rollback, and rotation.
