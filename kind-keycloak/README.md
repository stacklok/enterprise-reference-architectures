# kind + Keycloak

SEP on a local [kind](https://kind.sigs.k8s.io/) cluster, signing in through a bundled
Keycloak. A proof of concept needs no production identity provider. The scripts need no
terminal input, so CI can run them as they are.

| Script | What it does |
|---|---|
| `up.sh` | Creates the cluster and installs everything below. Safe to re-run. |
| `verify.sh` | Smoke-tests a running install and exits non-zero on the first failure. |
| `sync-users.sh` | Pushes Keycloak's users and groups into SEP's directory over SCIM. |
| `down.sh` | Deletes the cluster and the local state. |

With [Task](https://taskfile.dev) installed, each one is also a task in this directory:
`task up`, `task verify`, and so on.

## What runs

```
browser / curl ──https://*.127-0-0-1.sslip.io──▶ host port 443 ──▶ Traefik Gateway (kind NodePort)
                                                                   │
   ui.  ──▶ Cloud UI          em.  ──▶ Enterprise Manager (directory, budgets)
   auth.──▶ Keycloak          aigw.──▶ AI Gateway ──▶ your LLM provider
   registry. ──▶ Registry Server      connectors. ──▶ Connector Gateway ──▶ MCP servers
```

- **Hostnames.** Public DNS resolves every `*.127-0-0-1.sslip.io` name to `127.0.0.1`, and
  kind maps host port 443 to Traefik. Inside the cluster, CoreDNS rewrites the same names to
  Traefik's Service. A browser, this machine and every pod therefore use one issuer URL,
  `https://auth.127-0-0-1.sslip.io/realms/stacklok`.
- **TLS.** cert-manager issues a wildcard certificate from a CA the install creates. `up.sh`
  writes the CA to `.state/ca.crt`.
  - Accept the browser's warning, or trust the CA.
  - The CA carries a name constraint, so a machine that trusts it trusts it for
    `127-0-0-1.sslip.io` names only.
  - Each `up.sh` on a new cluster makes a new CA. Remove the old one from your trust store
    after `down.sh`.
- **Local state.** `.state/` holds the cluster's admin kubeconfig, so `up.sh` makes it
  readable by you alone.
- **Identity.** Keycloak runs in development mode with the realm in
  [`manifests/realm.json`](manifests/realm.json).
  - Groups: `everyone`, `engineering`, `finance` and `platform-admins`.
  - Users: `admin` (a platform admin), `alice` and `bob`.
  - Every SEP surface trusts the realm, and the directory binds tokens on `sub`.
- **Data.** PostgreSQL for Enterprise Manager and the Registry Server, and Valkey for the
  Connector Gateway. Each is a single replica on a small volume.
- **LLM traffic.** The AI Gateway needs an LLM provider: add yours as in
  [Use a real LLM provider](#use-a-real-llm-provider). The gateway is metered, so requests
  are refused until an admin sets a budget.
- **Connectors.** A sample `fetch` MCP server runs in the cluster, ready to register as a
  connector.

Docker needs about 6 GiB of memory, and host ports 80 and 443 on `127.0.0.1` must be free.

## Bring it up

`up.sh` installs a released chart from `oci.stacklok.com` and pulls the release's images with
your license. It needs only Docker, `curl` and `openssl`:

```sh
export SEP_LICENSE_ID=...            # the license ID; treat it as a secret
export SEP_LICENSE_EMAIL=...         # the email on the license's customer record
./up.sh
```

`CHART_VERSION` picks the release. It defaults to the `VERSION` file in this directory, the
release these values were written for, so the values and the chart agree. Without that file,
set it. `values/sep.yaml` keeps the keys older charts read.

`CHART_CHANNEL` picks the channel: `stable` (the default), `beta` or `unstable`. A version
reaches `stable` only once it is promoted, so install a newer one from `beta` or `unstable`.

The AI Gateway needs an LLM provider before it answers. Add yours in the same `up.sh` run
with `EXTRA_VALUES`, as in [Use a real LLM provider](#use-a-real-llm-provider).

To install a chart you already have instead, name its directory in `CHART`. The license is
then optional: without it nothing pulls from the license-gated image proxy, so every image the
chart runs must already be in the cluster. `LOAD_IMAGES` lists images in your local Docker
to load into the cluster before SEP installs, and an `EXTRA_VALUES` file points the chart at
them:

```sh
CHART=./stacklok-enterprise-platform LOAD_IMAGES="registry.example/sep/ai-gateway:dev ..." \
  EXTRA_VALUES=my-images.yaml ./up.sh
```

`kind`, `kubectl`, `helm` and `jq` are downloaded at pinned versions into
`~/.cache/sep-reference-architectures/bin`. Set `TOOLS_FROM_PATH=1` to use your own copies
instead.

`up.sh` prints the URLs when it finishes. Sign in to `https://ui.127-0-0-1.sslip.io` as
`admin`.

## Secrets

Nothing in this directory is a credential. `up.sh` generates every secret into a Kubernetes
Secret in the `stacklok` namespace the first time it runs, and later runs reuse it. The
exceptions come from the environment:

| Variable | Used for |
|---|---|
| `SEP_LICENSE_ID`, `SEP_LICENSE_EMAIL` | the released chart and its image pulls |
| `SEP_USER_PASSWORD` | the example users' password; generated when unset, and a new value replaces it on the next `up.sh` |

Read the generated passwords with:

```sh
export KUBECONFIG=.state/kubeconfig
kubectl -n stacklok get secret kind-keycloak-keycloak -o jsonpath='{.data.user-password}' | base64 -d
kubectl -n stacklok get secret kind-keycloak-keycloak -o jsonpath='{.data.admin-password}' | base64 -d   # Keycloak's own admin console
```

## Add your team

1. Add people to the `stacklok` realm at `https://auth.127-0-0-1.sslip.io/admin`.
2. Put them in `everyone` so they can see the catalog. Put them in `platform-admins` to make
   them SEP admins.
3. Run `./sync-users.sh`.

SEP's directory accepts a user only after the sync, so a new user can sign in once it has
run. Each sync replaces group membership to match Keycloak. It does not remove a user who was
deleted from Keycloak.

## Use a real LLM provider

`values/sep.yaml` points the gateway at an in-cluster mock provider that this directory does
not ship, so until you add a provider every LLM request fails. Put yours in your own values
file and name it in `EXTRA_VALUES`, a space-separated list of files layered last. Helm
replaces a list whole, so your `providers` list replaces the mock entries:

```sh
KUBECONFIG=.state/kubeconfig kubectl -n stacklok create secret generic anthropic-api-key --from-literal=api-key="$ANTHROPIC_API_KEY"
cat > my-providers.yaml <<'EOF'
ai-gateway-v2:
  providers:
    - kind: anthropic
      baseUrl: https://api.anthropic.com
      models: ["claude-sonnet-4-5"]
      credentialSecretRef: {name: anthropic-api-key, key: api-key}
EOF
EXTRA_VALUES=my-providers.yaml ./up.sh
```

## Verify

`./verify.sh` checks a running install through the public hostnames, using only the APIs:

1. `alice`, an ordinary user, signs in to the console through Keycloak, and Enterprise
   Manager accepts her token.
2. The check adds `verify-sync` to Keycloak. The directory-gated AI Gateway refuses that user
   until `sync-users.sh` runs, then accepts them. The check then deletes the user from
   Keycloak and deactivates it in the directory, whose SCIM API cannot delete a user. Every
   run reuses the name, so nothing piles up.
3. `admin` sets the org-wide default budget (5 USD a day) when none is set. `alice` cannot
   change it.
4. `alice` sends one AI Gateway request. The request without a token is refused, and her
   spend for the day rises.
5. `admin` registers the sample MCP server as the connector `verify-fetch` and grants it to
   `everyone`. `alice` then sees it among her connectors and turns it on. Each run replaces
   `verify-fetch`.
6. `alice` signs in to the Connector Gateway as an MCP client does: the client registers
   itself, she consents and signs in through Keycloak, and the client exchanges the code for a
   token. Her MCP session then lists the `fetch` tool from `verify-fetch`. A request without a
   token is refused.

Step 4 sends one request through the gateway's Anthropic API, so it needs a provider: it
asks for `VERIFY_MODEL`, `claude-haiku-4-5` unless you set it, which must be a model your
provider serves. A run takes about half a minute.

## Tear it down

```sh
./down.sh
```

This deletes the cluster and `.state/`. The downloaded tools are kept for the next `up.sh`.

## Troubleshooting

- **`up.sh` fails creating the cluster.** Another process holds host port 80 or 443. A
  second kind cluster with the same mapping counts too.
- **Keycloak is not reachable at its issuer.** Your DNS resolver may refuse names that
  resolve to `127.0.0.1` (DNS rebinding protection). Allow `sslip.io`, or use a resolver
  that does not filter.
- **Pods stuck in `ImagePullBackOff` on the released chart.** The license ID is wrong, or
  the license does not include the chart version.
- **Pods stuck in `ErrImageNeverPull` or `ImagePullBackOff` with `CHART`.** The chart names
  an image that is not in the cluster. Add it to `LOAD_IMAGES`.
- **Enterprise Manager crash-loops with `no migration found for version N` after switching
  charts.** The database already holds migrations newer than the chart you installed, for
  example an older release over a newer one. SEP does not downgrade its schema, so run
  `./down.sh` first.
- **A changed `SEP_USER_PASSWORD` has no effect.** It takes effect on the next `up.sh`, which
  resets the example users' password in Keycloak.
