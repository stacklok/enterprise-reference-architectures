# shellcheck shell=bash
# The settings are read by the scripts that source this file.
# shellcheck disable=SC2034
# SPDX-FileCopyrightText: Copyright 2026 Stacklok, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Shared settings and helpers for up.sh, verify.sh, sync-users.sh and down.sh. Sourced, not
# run. Every name and hostname the architecture uses is fixed here; secrets are generated
# into the cluster or read from the environment, never written to this directory.

set -euo pipefail

ARCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-sep-kind-keycloak}"
# Every *.127-0-0-1.sslip.io name resolves to 127.0.0.1 through public DNS, where kind maps
# host port 443 to Traefik. Inside the cluster, CoreDNS rewrites the same names to Traefik's
# Service, so a browser, this machine and every pod use one issuer URL.
DOMAIN=127-0-0-1.sslip.io
NAMESPACE=stacklok
RELEASE=stacklok
REALM=stacklok
CONNECTOR_GATEWAY_ID=kind-keycloak

HOST_UI="ui.$DOMAIN"
HOST_AUTH="auth.$DOMAIN"
HOST_EM="em.$DOMAIN"
HOST_AIGW="aigw.$DOMAIN"
HOST_CONNECTORS="connectors.$DOMAIN"
HOST_REGISTRY="registry.$DOMAIN"
ISSUER="https://$HOST_AUTH/realms/$REALM"

# The example realm's users (manifests/realm.json). admin is in platform-admins.
EXAMPLE_USERS="admin alice bob"

# State a run keeps on this machine: the cluster's admin kubeconfig, the CA that signed the
# HTTPS certificate and, for the released chart, the registry login. The directory is private
# to the user (ensure_state_dir).
STATE_DIR="${STATE_DIR:-$ARCH_DIR/.state}"
CA_FILE="$STATE_DIR/ca.crt"
export KUBECONFIG="$STATE_DIR/kubeconfig"

# Pinned tools, downloaded once into TOOLS_DIR so a machine needs only Docker, curl and
# openssl. Set TOOLS_FROM_PATH=1 to use the kind, kubectl, helm and jq already on PATH.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sep-reference-architectures"
TOOLS_DIR="${TOOLS_DIR:-$CACHE_DIR/bin}"
# Pinned charts and manifests up.sh installs, fetched once.
DOWNLOADS_DIR="$CACHE_DIR/downloads"
KIND_VERSION=v0.33.0
KUBECTL_VERSION=v1.36.4
HELM_VERSION=v4.0.1
JQ_VERSION=1.8.1
# The node image kind v0.33.0 ships for Kubernetes 1.36.
KIND_NODE_IMAGE=kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed

log() { printf '\033[1m[kind-keycloak]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[kind-keycloak] %s\033[0m\n' "$*" >&2; exit 1; }

os_arch() {
  local os arch
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) die "unsupported OS $(uname -s); use macOS or Linux" ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 ;;
    arm64 | aarch64) arch=arm64 ;;
    *) die "unsupported CPU $(uname -m)" ;;
  esac
  echo "$os-$arch"
}

# tool_sha <tool> <os-arch>: the pinned SHA-256 of one download.
tool_sha() {
  case "$1/$2" in
    kind/darwin-amd64) echo 5a99f26f57246dc9319dd294803313197a0f34d33c525b3ea8b655db5916ece0 ;;
    kind/darwin-arm64) echo 0c8c7dbe5e23594a198b786c4bc13dacc101fa6196b0cb0b23a1ca44e61f4b4f ;;
    kind/linux-amd64) echo aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d ;;
    kind/linux-arm64) echo 20022bee6cfcd5086cb7234d218e3454e6090022f2a8f55d1fa7fcf42c3867a2 ;;
    kubectl/darwin-amd64) echo 71a3aa7c2ee2c974d9fbb462cba0c5c04a4df2e8d85eee94714fd819ea3c4e63 ;;
    kubectl/darwin-arm64) echo c9e4f713d6fee0043a3d835cca13077cda2bc0973840eb9779360df0b5bdfc69 ;;
    kubectl/linux-amd64) echo 8b8f088da2dab964f853b38464033b1be15ede2839eca751482357c45abdd05a ;;
    kubectl/linux-arm64) echo 0ecf44450ee6063bf19dd166a103ee6df4a9034455c2abce626e6eea657d73fb ;;
    helm/darwin-amd64) echo a8d1ca46c3ff5484b2b635dfc25832add4f36fdd09cf2a36fb709829c05b4112 ;;
    helm/darwin-arm64) echo 8e0b9615cf72a62faaa0cfc0e22115f05bcddfd3d7ee58406ef97bc1ba563ae8 ;;
    helm/linux-amd64) echo e0365548f01ed52a58a1181ad310b604a3244f59257425bb1739499372bdff60 ;;
    helm/linux-arm64) echo 959fa52d34e2e1f0154e3220ed5f22263c8593447647a43af07890bba4b004d1 ;;
    jq/darwin-amd64) echo e80dbe0d2a2597e3c11c404f03337b981d74b4a8504b70586c354b7697a7c27f ;;
    jq/darwin-arm64) echo a9fe3ea2f86dfc72f6728417521ec9067b343277152b114f4e98d8cb0e263603 ;;
    jq/linux-amd64) echo 020468de7539ce70ef1bceaf7cde2e8c4f2ca6c3afb84642aabc5c97d9fc2a0d ;;
    jq/linux-arm64) echo 6bc62f25981328edd3cfcfe6fe51b073f2d7e7710d7ef7fcdac28d4e384fc3d4 ;;
    *) die "no pinned digest for $1 on $2" ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fetch <url> <sha256> <out>: download url to out and fail unless it has the pinned digest.
fetch() {
  local tmp
  tmp="$(mktemp)"
  curl -fsSL --retry 3 -o "$tmp" "$1" || die "download $1 failed"
  [ "$(sha256_of "$tmp")" = "$2" ] || { rm -f "$tmp"; die "download $1 does not match its pinned digest"; }
  mv "$tmp" "$3"
}

install_tool() {
  local name=$1 plat sha tmp
  plat="$(os_arch)"
  sha="$(tool_sha "$name" "$plat")"
  [ -x "$TOOLS_DIR/$name" ] && [ -f "$TOOLS_DIR/.$name.sha" ] && [ "$(cat "$TOOLS_DIR/.$name.sha")" = "$sha" ] && return 0
  mkdir -p "$TOOLS_DIR"
  log "downloading $name"
  case "$name" in
    kind) fetch "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-$plat" "$sha" "$TOOLS_DIR/kind" ;;
    kubectl) fetch "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/${plat%-*}/${plat#*-}/kubectl" "$sha" "$TOOLS_DIR/kubectl" ;;
    jq)
      local jq_os=${plat%-*}
      [ "$jq_os" = darwin ] && jq_os=macos
      fetch "https://github.com/jqlang/jq/releases/download/jq-$JQ_VERSION/jq-$jq_os-${plat#*-}" "$sha" "$TOOLS_DIR/jq"
      ;;
    helm)
      tmp="$(mktemp -d)"
      fetch "https://get.helm.sh/helm-$HELM_VERSION-$plat.tar.gz" "$sha" "$tmp/helm.tgz"
      tar -xzf "$tmp/helm.tgz" -C "$tmp"
      mv "$tmp/$plat/helm" "$TOOLS_DIR/helm"
      rm -rf "$tmp"
      ;;
  esac
  chmod +x "$TOOLS_DIR/$name"
  echo "$sha" >"$TOOLS_DIR/.$name.sha"
}

ensure_tools() {
  command -v docker >/dev/null || die "Docker is required"
  docker info >/dev/null 2>&1 || die "Docker is not running"
  local t
  for t in curl openssl; do command -v "$t" >/dev/null || die "$t is required"; done
  if [ "${TOOLS_FROM_PATH:-0}" = 1 ]; then
    for t in kind kubectl helm jq; do command -v "$t" >/dev/null || die "TOOLS_FROM_PATH=1, but $t is not on PATH"; done
    return 0
  fi
  for t in kind kubectl helm jq; do install_tool "$t"; done
  export PATH="$TOOLS_DIR:$PATH"
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
}

cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; }

require_cluster() {
  cluster_exists || die "kind cluster $CLUSTER_NAME does not exist; run up.sh first"
  ensure_state_dir
  kind get kubeconfig --name "$CLUSTER_NAME" >"$KUBECONFIG"
  [ -f "$CA_FILE" ] || kubectl -n cert-manager get secret kind-keycloak-root-ca \
    -o jsonpath='{.data.ca\.crt}' | base64 -d >"$CA_FILE"
}

# secret_value <secret> <key>: one decoded value of a Secret in the SEP namespace.
secret_value() {
  kubectl -n "$NAMESPACE" get secret "$1" -o jsonpath="{.data.${2//./\\.}}" | base64 -d
}

# https <curl args...>: curl against the architecture's public hostnames, trusting its CA.
https() { curl -sS --cacert "$CA_FILE" --max-time 30 "$@"; }

# password_token <username> <password>: an access token from the console's confidential
# client, which carries the Enterprise Manager, AI Gateway and Registry audiences.
password_token() {
  local secret
  secret="$(secret_value kind-keycloak-oidc-client client-secret)"
  https -f -X POST "$ISSUER/protocol/openid-connect/token" \
    --data-urlencode grant_type=password --data-urlencode client_id=stacklok-cloud-ui \
    --data-urlencode "client_secret=$secret" --data-urlencode "username=$1" \
    --data-urlencode "password=$2" --data-urlencode "scope=openid email profile groups" |
    jq -re '.access_token'
}

# keycloak_admin_token: a master-realm admin token for Keycloak's admin API.
keycloak_admin_token() {
  https -f -X POST "https://$HOST_AUTH/realms/master/protocol/openid-connect/token" \
    --data-urlencode grant_type=password --data-urlencode client_id=admin-cli \
    --data-urlencode username=admin \
    --data-urlencode "password=$(secret_value kind-keycloak-keycloak admin-password)" |
    jq -re '.access_token'
}

# retry <attempts> <delay> <command...>: run command until it succeeds.
retry() {
  local n=$1 delay=$2 i
  shift 2
  for i in $(seq 1 "$n"); do
    "$@" && return 0
    [ "$i" = "$n" ] || sleep "$delay"
  done
  return 1
}
