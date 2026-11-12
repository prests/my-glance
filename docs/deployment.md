# Deployment

## One-time Oracle VPS setup

1. In an Oracle Cloud tenancy whose home region is **US East (Ashburn)** (`us-ashburn-1`), create an Always Free eligible **Ubuntu 24.04 Minimal x86_64** instance using `VM.Standard.E2.1.Micro` (1/8 OCPU, 1 GB RAM). This is sufficient for Glance, Nginx, and Cloudflare Tunnel. Availability can still vary by availability domain.
2. In the VCN security list/security group, allow TCP **22** only. Do **not** open 80 or 443: Cloudflare Tunnel makes outbound connections from the VM.
3. SSH in using the initial Oracle key. Install Docker Engine and the Compose plugin using [Docker's Ubuntu instructions](https://docs.docker.com/engine/install/ubuntu/), then verify `docker compose version`.
4. Keep the `ubuntu` deployment account or create a dedicated non-root account in the `docker` group. Create `~/glance/config` for it.
5. Add a dedicated ED25519 public deployment key to that account's `~/.ssh/authorized_keys`. It must not be a personal key.
6. In `/etc/ssh/sshd_config` (or an included drop-in), set `PermitRootLogin no` and `PasswordAuthentication no`; test a second SSH session before restarting SSH.
7. Install/configure `fail2ban` (or equivalent SSH rate limiting) and keep OS security updates current.
8. Capture the server's host key **from a trusted SSH session** with `ssh-keyscan -H <server-ip-or-name>` and verify its fingerprint. Save the resulting line for `DEPLOY_SSH_KNOWN_HOSTS`; do not disable strict host-key checking.

The deployment workflow copies only Compose and Nginx configuration into `~/glance`. Docker creates transient runtime secret mounts from the deployment process environment; credentials are not written to that directory.

## Cloudflare Tunnel

1. In Cloudflare Zero Trust, create a **remotely managed** tunnel and copy its token.
2. Add a public hostname `news.byte-cave.com` to that tunnel. Set its service to `http://nginx:8080`; `cloudflared` and Nginx share the Compose `tunnel` network.
3. Leave the public DNS record Cloudflare-managed. The VM needs no public HTTP/HTTPS listener.
4. The Nginx configuration replaces all incoming `X-Forwarded-For` values with Cloudflare's `CF-Connecting-IP`. This is required because Glance trusts `X-Forwarded-For` for its failed-login block list. Do not point the tunnel directly at Glance or publish Glance's port.

### Public OPML feed

The deployment exposes only `https://news.byte-cave.com/feeds/news.opml`. It is a static export of the public feed list and does not require dashboard authentication.

Terraform manages Cloudflare caching, rate limiting, port restrictions, and response security headers. The cache rule stores the public OPML feed for 30 minutes and matches only that route:

```text
http.host eq "news.byte-cave.com" and http.request.uri.path eq "/feeds/news.opml"
```

The rate-limit and security-header rules match only `news.byte-cave.com`. The firewall rule blocks requests for that hostname on every Cloudflare port except 80 and 443:

```text
http.host eq "news.byte-cave.com" and not cf.edge.server_port in {80 443}
```

The rate limit is 60 requests per 10 seconds per IP, blocking that IP for 10 seconds. The cache rule has a one-day edge TTL and removes query strings from the cache key. HTTPS responses receive HSTS, clickjacking, MIME-sniffing, and referrer protections.

### Terraform setup

1. In Cloudflare R2, create a bucket named `my-glance-terraform-state`. Terraform state is stored there; do not commit state files.
2. Create an R2 API token scoped to that bucket with **Object Read & Write** access, then create its S3 API credentials.
3. Create a separate Cloudflare API token for Terraform. Grant **Zone: Cache Rules: Edit**, **Zone: WAF: Edit**, and **Zone: Transform Rules: Edit** for only `byte-cave.com`, plus the required **Account: Account Rulesets: Edit** and **Account: Account Filter Lists: Edit** permissions. Do not use the global API key.
4. In the GitHub `production` Environment, add these secrets:
   - `CLOUDFLARE_API_TOKEN`
   - `R2_ACCESS_KEY_ID`
   - `R2_SECRET_ACCESS_KEY`
5. In the same environment, add these variables:
   - `CLOUDFLARE_ACCOUNT_ID`
   - `CLOUDFLARE_ZONE_ID` — the ID for the `byte-cave.com` zone
   - `TF_STATE_BUCKET` — `my-glance-terraform-state`
6. Run **Terraform** with `plan`, inspect the output, then rerun it with `apply`.

A zone can have only one entry-point ruleset per phase. If `byte-cave.com` already has cache, rate-limit, custom firewall, or response-header transform rules, import and manage the existing phase ruleset before applying; otherwise Terraform could conflict with rules outside this project. Every rule remains restricted to `news.byte-cave.com`, and the cache rule is further restricted to the exact OPML path above.

## GitHub setup

Create a repository Environment named `production` without required reviewers. Add these **Environment secrets** after VPS setup:

| Secret                      | Value                                                                    |
| --------------------------- | ------------------------------------------------------------------------ |
| `DEPLOY_HOST`               | Oracle VM public IP or DNS name                                          |
| `DEPLOY_USER`               | `ubuntu`, unless a dedicated deployment user was created                 |
| `DEPLOY_SSH_PRIVATE_KEY`    | Private half of the dedicated ED25519 deployment key                     |
| `DEPLOY_SSH_KNOWN_HOSTS`    | The verified host-key line captured during bootstrap                     |
| `CLOUDFLARE_TUNNEL_TOKEN`   | Remotely managed tunnel token                                            |
| `GLANCE_AUTH_USERNAME`      | The manually chosen dashboard username                                   |
| `GLANCE_AUTH_PASSWORD_HASH` | Output from `varlock run -- ./scripts/generate-secrets.sh`               |
| `GLANCE_AUTH_SECRET_KEY`    | Stable output from `docker run --rm glanceapp/glance:v0.8.8 secret:make` |

The first successful branch-push build creates the GHCR package at `ghcr.io/prests/my-glance`. Change that package's visibility to **Public** in GitHub Packages. It is safe to make public because the image contains dashboard configuration only, never credentials.

The build workflow publishes one AMD64 image per pushed commit using its full SHA tag and a provenance attestation. Pull requests format-check, build, and start the stack but do not publish. In the **Deploy** Actions workflow, select the desired branch with GitHub's branch selector. The workflow takes that branch tip SHA, verifies its existing attestation, resolves its digest, and deploys the digest; it does not build an image.

## Operations

### Deploy and redeploy

Run the **Deploy** workflow manually and select a branch. It deploys the selected branch tip only when that exact commit already has a verified, attested GHCR image. To redeploy the same release, select the same branch while it still points to that commit; after the branch advances, use a branch that points to the desired commit.

The workflow performs a loopback health check after deployment. If it fails, it starts the previous Glance image again and fails the run. Inspect the GitHub Actions log and then the Oracle logs:

```sh
cd ~/glance
docker compose -p glance -f compose.yaml -f compose.production.yaml logs --tail=200
```

### Rollback

For a deliberate rollback, use a branch whose tip is the previously published commit, then run **Deploy** for that branch. This preserves the invariant that a deployment always uses a prebuilt, attested SHA image. Do not edit `GLANCE_IMAGE` by hand unless recovering from a failed host; doing so bypasses workflow verification.

### Password and signing-key rotation

For a password rotation, update the local `GLANCE_AUTH_PASSWORD`, run:

```sh
varlock run -- ./scripts/generate-secrets.sh
```

Replace `GLANCE_AUTH_PASSWORD_HASH` in the `production` Environment with the output, then run **Deploy**. Do not store or upload `GLANCE_AUTH_PASSWORD`.

To rotate the signing key, generate a new value with:

```sh
docker run --rm glanceapp/glance:v0.8.8 secret:make
```

Replace `GLANCE_AUTH_SECRET_KEY` in both local configuration and the `production` Environment, then deploy. This invalidates all current Glance login sessions. Rotate the Cloudflare tunnel token in Cloudflare and the `CLOUDFLARE_TUNNEL_TOKEN` Environment secret together.

## Oracle availability note

Always Free capacity is limited and Oracle can reclaim persistently idle Always Free instances. Keep the initial Oracle recovery SSH key in a safe place, monitor the service, and retain the documented setup steps so the VM can be recreated.
