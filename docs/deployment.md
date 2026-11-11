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
