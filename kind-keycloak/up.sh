#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Stacklok, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Brings SEP up on a local kind cluster that signs in through a bundled Keycloak. Safe to
# re-run: each step reuses what an earlier run created. See README.md.
#
#   SEP_LICENSE_ID=... SEP_LICENSE_EMAIL=... ./up.sh   # the released chart at CHART_VERSION
#   CHART=<chart dir> LOAD_IMAGES="<image> ..." ./up.sh # a chart and images you supply
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# A chart directory to install in place of the released chart.
CHART="${CHART:-}"
CHART_CHANNEL="${CHART_CHANNEL:-stable}"
# The release these values were written for. A published architecture carries it in VERSION.
if [ -z "${CHART_VERSION:-}" ] && [ -f "$ARCH_DIR/VERSION" ]; then
  CHART_VERSION="$(tr -d '[:space:]' <"$ARCH_DIR/VERSION")"
fi
CHART_VERSION="${CHART_VERSION:-}"
EXTRA_VALUES="${EXTRA_VALUES:-}"
# Images to copy from the local Docker daemon into the cluster before SEP installs.
LOAD_IMAGES="${LOAD_IMAGES:-}"
# An optional mock LLM provider image. It is test tooling, not part of a release; without
# it the AI Gateway needs a real provider (README: Use a real LLM provider).
MOCK_PROVIDER_IMAGE="${MOCK_PROVIDER_IMAGE:-}"

# Third-party installs, pinned by digest.
GATEWAY_API_URL=https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.7.0/standard-install.yaml
GATEWAY_API_SHA=4e2602c4cbe1afbc394d86f4ac6522e1a5263b01133bba1e40a6d1a549e753a1
CERT_MANAGER_URL=https://charts.jetstack.io/charts/cert-manager-v1.21.3.tgz
CERT_MANAGER_SHA=9ec67938b2981d8b333af61b3fcf53e26b4f6f5deb7ccda3de4ea116bb373a17
TRAEFIK_URL=https://traefik.github.io/charts/traefik/traefik-42.2.0.tgz
TRAEFIK_SHA=03ec772e0caab39f3d265db14014f56832ab420da98d6210f83d3ef908c077e5
check_inputs() {
  if [ -n "$CHART" ]; then
    [ -f "$CHART/Chart.yaml" ] || die "CHART names $CHART, which is not a chart directory"
  else
    [ -n "$CHART_VERSION" ] || die "set CHART_VERSION, the released chart version to install"
    [ -n "${SEP_LICENSE_ID:-}" ] || die "set SEP_LICENSE_ID, the license ID that authenticates the chart and image pulls"
    [ -n "${SEP_LICENSE_EMAIL:-}" ] || die "set SEP_LICENSE_EMAIL, the email on the license's customer record"
  fi
  local f
  for f in $EXTRA_VALUES; do [ -f "$f" ] || die "EXTRA_VALUES names $f, which does not exist"; done
}

create_cluster() {
  ensure_state_dir
  if cluster_exists; then
    log "reusing kind cluster $CLUSTER_NAME"
  else
    log "creating kind cluster $CLUSTER_NAME (host ports 80 and 443 on 127.0.0.1 must be free)"
    kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" \
      --config "$ARCH_DIR/manifests/kind-config.yaml" --wait 3m
  fi
  kind get kubeconfig --name "$CLUSTER_NAME" >"$KUBECONFIG"
}

# cached <url> <sha256>: the path of a pinned download, fetched once into DOWNLOADS_DIR.
cached() {
  local out="$DOWNLOADS_DIR/$2"
  mkdir -p "$(dirname "$out")"
  [ -f "$out" ] || fetch "$1" "$2" "$out"
  echo "$out"
}

install_platform() {
  log "installing Gateway API, cert-manager and Traefik"
  kubectl apply --server-side -f "$(cached "$GATEWAY_API_URL" "$GATEWAY_API_SHA")" >/dev/null
  helm upgrade --install cert-manager "$(cached "$CERT_MANAGER_URL" "$CERT_MANAGER_SHA")" \
    -n cert-manager --create-namespace --set crds.enabled=true --wait --timeout 10m >/dev/null
  helm upgrade --install traefik "$(cached "$TRAEFIK_URL" "$TRAEFIK_SHA")" \
    -n traefik --create-namespace -f "$ARCH_DIR/manifests/traefik-values.yaml" --wait --timeout 10m >/dev/null
}

# Pods resolve every *.127-0-0-1.sslip.io name to Traefik's Service, so a pod calling the
# issuer or a public hostname reaches the same Gateway a browser does.
rewrite_dns() {
  local rule="rewrite name regex (.*)\\.127-0-0-1\\.sslip\\.io traefik.traefik.svc.cluster.local answer auto"
  local corefile
  corefile="$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
  grep -qF "$rule" <<<"$corefile" && return 0
  log "pointing cluster DNS for *.$DOMAIN at Traefik"
  kubectl -n kube-system get configmap coredns -o json |
    jq --arg rule "    $rule" '.data.Corefile |= sub("\\.:53 \\{\n"; ".:53 {\n" + $rule + "\n")' |
    kubectl replace -f - >/dev/null
  kubectl -n kube-system rollout restart deployment coredns >/dev/null
  kubectl -n kube-system rollout status deployment coredns --timeout 2m >/dev/null
}

install_pki() {
  log "issuing certificates"
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f "$ARCH_DIR/manifests/pki.yaml" >/dev/null
  kubectl -n cert-manager wait certificate/kind-keycloak-root-ca --for=condition=Ready --timeout 2m >/dev/null
  kubectl -n traefik wait certificate/kind-keycloak-tls --for=condition=Ready --timeout 2m >/dev/null
  kubectl -n "$NAMESPACE" wait certificate --all --for=condition=Ready --timeout 2m >/dev/null
  kubectl -n cert-manager get secret kind-keycloak-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >"$CA_FILE"
  kubectl -n "$NAMESPACE" create configmap kind-keycloak-ca --from-file=ca.crt="$CA_FILE" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

password() { openssl rand -base64 18 | tr '+/' '-_'; }
has_secret() { kubectl -n "$NAMESPACE" get secret "$1" >/dev/null 2>&1; }
# new_secret <name> <kubectl create secret generic args...>: create a Secret once. A later
# run keeps it, so data stores and Keycloak keep the credentials they started with.
new_secret() {
  local name=$1
  shift
  has_secret "$name" || kubectl -n "$NAMESPACE" create secret generic "$name" "$@" >/dev/null
}
# put_secret <name> <kubectl create secret generic args...>: create or replace a Secret.
put_secret() {
  local name=$1
  shift
  kubectl -n "$NAMESPACE" create secret generic "$name" "$@" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}
ec_key() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null; }
kek() { printf '{"1":"%s"}' "$(openssl rand -base64 32)"; }

generate_secrets() {
  log "generating secrets"
  # kind-keycloak-db-roles is written last: until it exists Postgres cannot have started,
  # so a run interrupted before it rewrites the two client Secrets to match it.
  if ! has_secret kind-keycloak-db-roles; then
    local db_app db_migrator em_app em_migrator em_admin
    db_app="$(password)" db_migrator="$(password)" em_app="$(password)" em_migrator="$(password)" em_admin="$(password)"
    put_secret kind-keycloak-em-db --from-literal=postgres-password="$em_app" \
      --from-literal=postgres-migration-password="$em_migrator" --from-literal=postgres-admin-password="$em_admin"
    put_secret kind-keycloak-registry-db --from-literal=app-password="$db_app" --from-literal=migrator-password="$db_migrator"
    new_secret kind-keycloak-db-roles --from-literal=DB_APP_PASSWORD="$db_app" \
      --from-literal=DB_MIGRATOR_PASSWORD="$db_migrator" --from-literal=EM_APP_PASSWORD="$em_app" \
      --from-literal=EM_MIGRATOR_PASSWORD="$em_migrator" --from-literal=EM_ADMIN_PASSWORD="$em_admin"
  fi
  new_secret kind-keycloak-postgres-admin --from-literal=password="$(password)"
  new_secret kind-keycloak-valkey --from-literal=password="$(password)"
  new_secret kind-keycloak-em-signing-key --from-literal=signing.pem="$(ec_key)"
  new_secret kind-keycloak-directory-kek --from-literal=kek="$(kek)"
  new_secret kind-keycloak-connector-gateway-kek --from-literal=kek="$(kek)"
  new_secret kind-keycloak-connector-gateway-auth-keys --from-literal=signing-key.pem="$(ec_key)" \
    --from-literal=hmac-secret="$(openssl rand -hex 32)"
  new_secret kind-keycloak-scim-token --from-literal=token="$(openssl rand -hex 32)"
  new_secret kind-keycloak-oidc-client --from-literal=client-secret="$(password)"
  new_secret kind-keycloak-cloud-ui --from-literal=secret="$(openssl rand -hex 32)"
  # Not a credential: the mock provider's Anthropic route only refuses an empty key.
  new_secret kind-keycloak-mock-provider --from-literal=api-key=mock-provider-placeholder

  # The example users' password is SEP_USER_PASSWORD when set, generated otherwise; a set
  # value replaces the stored one, and reset_example_users applies it in Keycloak.
  local admin user
  if has_secret kind-keycloak-keycloak; then
    admin="$(secret_value kind-keycloak-keycloak admin-password)"
    user="${SEP_USER_PASSWORD:-$(secret_value kind-keycloak-keycloak user-password)}"
  else
    admin="$(password)"
    user="${SEP_USER_PASSWORD:-$(password)}"
  fi
  put_secret kind-keycloak-keycloak --from-literal=admin-password="$admin" --from-literal=user-password="$user"

  if [ -n "${SEP_LICENSE_ID:-}" ]; then
    local auth
    auth="$(printf '%s:%s' "$SEP_LICENSE_ID" "$SEP_LICENSE_ID" | base64 | tr -d '\n')"
    kubectl -n "$NAMESPACE" create secret docker-registry enterprise-pull-secret \
      --from-file=.dockerconfigjson=<(printf '{"auths":{"image-proxy.stacklok.com":{"auth":"%s"}}}' "$auth") \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  fi
}

install_services() {
  log "starting PostgreSQL, Valkey and Keycloak"
  kubectl -n "$NAMESPACE" create configmap kind-keycloak-postgres-init \
    --from-file=init.sh="$ARCH_DIR/manifests/postgres-init.sh" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$NAMESPACE" create configmap kind-keycloak-realm \
    --from-file=stacklok-realm.json="$ARCH_DIR/manifests/realm.json" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f "$ARCH_DIR/manifests/services.yaml" >/dev/null
  kubectl -n "$NAMESPACE" rollout status statefulset/postgres --timeout 5m >/dev/null
  kubectl -n "$NAMESPACE" rollout status statefulset/valkey --timeout 5m >/dev/null
  kubectl -n "$NAMESPACE" rollout status deployment/keycloak --timeout 10m >/dev/null
  retry 30 5 curl -fs --cacert "$CA_FILE" -o /dev/null "$ISSUER/.well-known/openid-configuration" ||
    die "Keycloak is not reachable at $ISSUER; is host port 443 mapped to this cluster?"
}

# Keycloak imports realm.json on its first start only, so the example users' password is
# set through the admin API on every run.
reset_example_users() {
  local token user id pw
  token="$(retry 12 5 keycloak_admin_token)" || die "could not sign in to Keycloak's admin API"
  pw="$(secret_value kind-keycloak-keycloak user-password)"
  for user in $EXAMPLE_USERS; do
    id="$(https -f -H "Authorization: Bearer $token" \
      "https://$HOST_AUTH/admin/realms/$REALM/users?exact=true&username=$user" | jq -r '.[0].id // empty')"
    [ -n "$id" ] || continue
    jq -n --arg pw "$pw" '{type: "password", value: $pw, temporary: false}' |
      https -f -X PUT -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
        "https://$HOST_AUTH/admin/realms/$REALM/users/$id/reset-password" -d @- >/dev/null
  done
}

# load_image <image>: copy an image from the local Docker daemon into the cluster, pulling
# it into Docker first when it is not there. The pull uses your Docker credentials.
load_image() {
  docker image inspect "$1" >/dev/null 2>&1 || docker pull -q "$1" >/dev/null ||
    die "image $1 is neither in the local Docker daemon nor pullable"
  kind load docker-image "$1" --name "$CLUSTER_NAME" >/dev/null
}

load_images() {
  local image
  for image in $LOAD_IMAGES; do
    log "loading $image"
    load_image "$image"
  done
}

install_mock_provider() {
  if [ -z "$MOCK_PROVIDER_IMAGE" ]; then
    log "no MOCK_PROVIDER_IMAGE: the AI Gateway answers once you add a real provider (README: Use a real LLM provider)"
    return 0
  fi
  log "starting the mock LLM provider ($MOCK_PROVIDER_IMAGE)"
  load_image "$MOCK_PROVIDER_IMAGE"
  sed "s|image: MOCK_PROVIDER_IMAGE|image: $MOCK_PROVIDER_IMAGE|" "$ARCH_DIR/manifests/mock-provider.yaml" |
    kubectl apply -f - >/dev/null
  # An image loaded again under the same tag reaches only a new pod.
  kubectl -n mock-provider rollout restart deployment/mock-provider >/dev/null
  kubectl -n mock-provider rollout status deployment/mock-provider --timeout 2m >/dev/null
}

install_sep() {
  local chart args=()
  args+=(-f "$ARCH_DIR/values/sep.yaml")
  local f
  for f in $EXTRA_VALUES; do args+=(-f "$f"); done
  if [ -n "$CHART" ]; then
    chart="$CHART"
  else
    # The registry login stays in this architecture's state, not the user's Helm config.
    export HELM_REGISTRY_CONFIG="$STATE_DIR/registry.json"
    printf '%s' "$SEP_LICENSE_ID" | helm registry login oci.stacklok.com --username "$SEP_LICENSE_EMAIL" --password-stdin >/dev/null
    chart="oci://oci.stacklok.com/stacklok-enterprise/$CHART_CHANNEL/stacklok-enterprise-platform"
    args+=(--version "$CHART_VERSION")
  fi
  log "installing SEP from $chart$([ -z "$CHART" ] && printf ' %s' "$CHART_VERSION") (up to 20 minutes)"
  helm upgrade --install "$RELEASE" "$chart" -n "$NAMESPACE" "${args[@]}" --wait --timeout 20m
  kubectl apply -f "$ARCH_DIR/manifests/content.yaml" >/dev/null
}

summary() {
  cat >&2 <<EOF

SEP is up on kind cluster $CLUSTER_NAME.

  Console            https://$HOST_UI
  Keycloak admin     https://$HOST_AUTH/admin   (user admin, password: kubectl -n $NAMESPACE get secret kind-keycloak-keycloak -o jsonpath='{.data.admin-password}' | base64 -d)
  AI Gateway         https://$HOST_AIGW
  Enterprise Manager https://$HOST_EM
  Connectors         https://$HOST_CONNECTORS/gw/mcp

  Example users      $EXAMPLE_USERS  (admin is a platform admin)
  Their password     kubectl -n $NAMESPACE get secret kind-keycloak-keycloak -o jsonpath='{.data.user-password}' | base64 -d
  KUBECONFIG         $KUBECONFIG
  CA certificate     $CA_FILE  (trust it, or accept the browser warning)

Next: ./verify.sh checks it end to end. ./sync-users.sh pushes Keycloak users you add to
the directory. ./down.sh deletes the cluster.
EOF
}

check_inputs
ensure_tools
create_cluster
install_platform
rewrite_dns
install_pki
generate_secrets
install_services
reset_example_users
install_mock_provider
load_images
install_sep
"$ARCH_DIR/sync-users.sh"
summary
