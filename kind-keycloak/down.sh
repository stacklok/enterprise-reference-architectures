#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Stacklok, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Deletes the kind cluster and this architecture's local state (kubeconfig, CA, registry
# login). Every secret lived in the cluster, so nothing is left behind. The downloaded
# tools are kept for the next up.sh.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ensure_tools
if cluster_exists; then
  log "deleting kind cluster $CLUSTER_NAME"
  kind delete cluster --name "$CLUSTER_NAME"
else
  log "kind cluster $CLUSTER_NAME does not exist"
fi
rm -rf "$STATE_DIR"
