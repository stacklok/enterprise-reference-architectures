#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Stacklok, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Pushes Keycloak's users and groups into SEP's directory over SCIM. Keycloak's own SCIM
# support is inbound only, so this reads the realm through Keycloak's admin API and writes
# each user and group to the directory's SCIM endpoint. up.sh runs it; run it again after
# adding or changing a user in Keycloak, and that user can sign in.
#
# Each user's externalId is its Keycloak id, which is the sub the directory binds tokens
# on. Existing users and groups are replaced, so group membership follows Keycloak. A user
# deleted from Keycloak is not removed from the directory.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ensure_tools
require_cluster

SCIM_URL="https://$HOST_EM/scim/keycloak/v2"
SCIM_TOKEN="$(secret_value kind-keycloak-scim-token token)"
KC_ADMIN="https://$HOST_AUTH/admin/realms/$REALM"

kc_token="$(retry 30 5 keycloak_admin_token)" || die "could not sign in to Keycloak's admin API"
kc_get() { https -f -H "Authorization: Bearer $kc_token" "$KC_ADMIN$1"; }

# scim <method> <path> [body]: one SCIM call, retried while Enterprise Manager starts.
# Prints the response body followed by a line holding the status code.
scim() {
  local out i code
  for i in $(seq 1 12); do
    out="$(https -X "$1" "$SCIM_URL$2" -H "Authorization: Bearer $SCIM_TOKEN" \
      -H 'Content-Type: application/scim+json' ${3:+-d "$3"} -w '\n%{http_code}' || echo $'\n000')"
    code="${out##*$'\n'}"
    case "$code" in 000 | 5??) sleep 5 ;; *) break ;; esac
  done
  printf '%s\n' "$out"
}

# upsert <Users|Groups> <attr> <value> <body>: replace the resource whose attr equals
# value, or create it. Prints its SCIM id.
upsert() {
  local kind=$1 attr=$2 value=$3 body=$4 out code id filter
  filter="$(jq -rn --arg f "$attr eq \"$value\"" '$f|@uri')"
  out="$(scim GET "/$kind?filter=$filter")"
  code="${out##*$'\n'}"
  [ "$code" = 200 ] || die "SCIM lookup of $kind $value returned $code: ${out%$'\n'*}"
  id="$(printf '%s' "${out%$'\n'*}" | jq -r '.Resources[0].id // empty')"
  if [ -n "$id" ]; then
    out="$(scim PUT "/$kind/$id" "$body")"
    code="${out##*$'\n'}"
    [ "$code" = 200 ] || die "SCIM replace of $kind $value returned $code: ${out%$'\n'*}"
  else
    out="$(scim POST "/$kind" "$body")"
    code="${out##*$'\n'}"
    [ "$code" = 201 ] || die "SCIM create of $kind $value returned $code: ${out%$'\n'*}"
    id="$(printf '%s' "${out%$'\n'*}" | jq -r '.id')"
  fi
  echo "$id"
}

users="$(kc_get '/users?max=1000&briefRepresentation=false')" || die "could not list Keycloak users"
groups="$(kc_get '/groups?max=1000')" || die "could not list Keycloak groups"

# Keycloak id -> SCIM id, one "kcid scimid" line each.
ids=""
while IFS= read -r user; do
  name="$(jq -r .username <<<"$user")"
  body="$(jq -c '{
    schemas: ["urn:ietf:params:scim:schemas:core:2.0:User"],
    userName: .username,
    externalId: .id,
    displayName: ([.firstName, .lastName] | map(select(. != null and . != "")) | join(" ")),
    name: {givenName: (.firstName // ""), familyName: (.lastName // "")},
    active: .enabled
  } + (if (.email // "") != "" then {emails: [{value: .email, primary: true}]} else {} end)' <<<"$user")"
  id="$(upsert Users userName "$name" "$body")"
  ids+="$(jq -r .id <<<"$user") $id"$'\n'
done < <(jq -c '.[]' <<<"$users")

while IFS= read -r group; do
  gid="$(jq -r .id <<<"$group")"
  name="$(jq -r .name <<<"$group")"
  members="$(kc_get "/groups/$gid/members?max=1000")" || die "could not list members of group $name"
  refs="$(jq -c --arg ids "$ids" '
    ($ids | split("\n") | map(select(. != "") | split(" ") | {key: .[0], value: .[1]}) | from_entries) as $m
    | [.[] | $m[.id] | select(. != null) | {value: .}] | sort_by(.value)' <<<"$members")"
  body="$(jq -c --argjson refs "$refs" '{
    schemas: ["urn:ietf:params:scim:schemas:core:2.0:Group"],
    displayName: .name,
    externalId: .id,
    members: $refs
  }' <<<"$group")"
  upsert Groups displayName "$name" "$body" >/dev/null
done < <(jq -c '.[]' <<<"$groups")

log "pushed $(jq length <<<"$users") users and $(jq length <<<"$groups") groups to the directory"
