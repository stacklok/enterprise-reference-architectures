#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Stacklok, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Prints what a failed up.sh or verify.sh needs to be debugged: every pod, recent events,
# and the logs of each pod that is not ready. Never fails, so CI can run it after a failure.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
set +e

# ensure_tools exits through die when Docker is down or a download fails; diagnostics then
# have nothing to read, so that ends the script without failing it.
(ensure_tools) || exit 0
[ "${TOOLS_FROM_PATH:-0}" = 1 ] || export PATH="$TOOLS_DIR:$PATH"
cluster_exists || { log "kind cluster $CLUSTER_NAME does not exist"; exit 0; }
ensure_state_dir
kind get kubeconfig --name "$CLUSTER_NAME" >"$KUBECONFIG"

log "pods"
kubectl get pods -A -o wide
log "events"
kubectl get events -A --sort-by=.lastTimestamp | tail -n 100
kubectl get pods -A -o json |
  jq -r '.items[] | select(.status.phase != "Succeeded" and (((.status.containerStatuses // []) | length) == 0 or any(.status.containerStatuses[]; .ready | not))) | "\(.metadata.namespace) \(.metadata.name)"' |
  while read -r ns pod; do
    log "logs of $ns/$pod"
    kubectl -n "$ns" describe pod "$pod" | tail -n 30
    kubectl -n "$ns" logs "$pod" --all-containers --tail 200
  done
exit 0
