#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Stacklok, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Smoke test of a running kind-keycloak architecture, through the same public hostnames a
# browser uses. Exits non-zero on the first check that fails.
#
#   1. alice, an ordinary user, signs in to the console through Keycloak.
#   2. A user added to Keycloak is refused until sync-users.sh pushes it, then accepted.
#   3. admin sets the org-wide default budget, when none is set.
#   4. alice sends one AI Gateway request, and her day's spend rises.
#   5. admin registers the sample MCP server as a connector and grants it to the everyone
#      group; alice then sees it among her connectors and turns it on.
#   6. alice signs in to the Connector Gateway as an MCP client does, and lists the
#      connector's tools.
#
# It changes the install only in ways a re-run expects: a default budget when none exists,
# a connector named verify-fetch replaced on every run, a directory user named verify-sync,
# reused by every run and left deactivated, and one registered OAuth client per run on the
# Connector Gateway.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

UI="https://$HOST_UI"
GATEWAY="https://$HOST_AIGW"
CONNECTORS="https://$HOST_CONNECTORS"
# Step 4's model, which an Anthropic-API provider behind the gateway must serve.
MODEL="${VERIFY_MODEL:-claude-haiku-4-5}"
CONNECTOR=verify-fetch

ensure_tools
require_cluster
USER_PASSWORD="$(secret_value kind-keycloak-keycloak user-password)"
WORK="$(mktemp -d)"
EM="https://$HOST_EM"
SCIM_TOKEN="$(secret_value kind-keycloak-scim-token token)"
# Step 2's user. Every run reuses the name: the directory's SCIM API deactivates a user but
# cannot delete one, so a fresh name per run would leave a user behind each time.
SYNC_USER=verify-sync
# Set while step 2's user exists in Keycloak, so remove_sync_user runs however the run ends.
sync_user_id=""

# remove_sync_user deletes step 2's user from Keycloak and deactivates it in the directory,
# so a later sync-users.sh pushes nothing for it. It mints its own Keycloak admin token,
# because the one step 2 used is short-lived, and reports a change it could not make.
remove_sync_user() {
  [ -n "$sync_user_id" ] || return 0
  local scim_id token
  scim_id="$(https -H "Authorization: Bearer $SCIM_TOKEN" \
    "$EM/scim/keycloak/v2/Users?filter=$(jq -rn --arg f "userName eq \"$SYNC_USER\"" '$f|@uri')" |
    jq -r '.Resources[0].id // empty' 2>/dev/null || true)"
  if [ -n "$scim_id" ]; then
    https -fo /dev/null -X PATCH -H "Authorization: Bearer $SCIM_TOKEN" -H 'Content-Type: application/scim+json' \
      "$EM/scim/keycloak/v2/Users/$scim_id" \
      -d '{"schemas":["urn:ietf:params:scim:api:messages:2.0:PatchOp"],"Operations":[{"op":"replace","path":"active","value":false}]}' ||
      log "could not deactivate $SYNC_USER in the directory"
  fi
  { token="$(keycloak_admin_token)" &&
    https -fo /dev/null -X DELETE -H "Authorization: Bearer $token" \
      "https://$HOST_AUTH/admin/realms/$REALM/users/$sync_user_id"; } ||
    log "could not delete $SYNC_USER from Keycloak; delete it in the admin console"
  sync_user_id=""
}
trap 'remove_sync_user; rm -rf "$WORK"' EXIT

step() { log "$*"; }
pass() { printf '  \033[32mok\033[0m %s\n' "$*" >&2; }
fail() { die "FAIL: $*"; }

# call <method> <url> <token|-> [body]: prints the body, then a line with the status code.
call() {
  local args=(-X "$1" "$2" -w '\n%{http_code}')
  [ "$3" = - ] || args+=(-H "Authorization: Bearer $3")
  [ -z "${4:-}" ] || args+=(-H 'Content-Type: application/json' -d "$4")
  https "${args[@]}" || printf '\n000'
}
status() { printf '%s' "${1##*$'\n'}"; }
body() { printf '%s' "${1%$'\n'*}"; }
expect() { # expect <want> <response> <what>
  [ "$(status "$2")" = "$1" ] || fail "$3 returned $(status "$2"), want $1: $(body "$2" | head -c 400)"
}

# keycloak_login <cookie-jar> <login-page-html> <username>: submits Keycloak's login form as
# the user and prints where Keycloak redirects next.
keycloak_login() {
  local action
  action="$(grep -o 'id="kc-form-login"[^>]*action="[^"]*"' <<<"$2" | sed 's/.*action="//; s/"$//; s/&amp;/\&/g')"
  [ -n "$action" ] || fail "Keycloak's login page has no login form"
  https -c "$1" -b "$1" -o /dev/null -w '%{redirect_url}' \
    --data-urlencode "username=$3" --data-urlencode "password=$USER_PASSWORD" "$action"
}

# --- 1. Console sign-in --------------------------------------------------------------------
step "1. alice signs in to the console through Keycloak"
jar="$WORK/cookies"
start="$(https -c "$jar" -b "$jar" -X POST "$UI/api/auth/sign-in/social" \
  -H 'Content-Type: application/json' -H "Origin: $UI" \
  -d '{"provider":"oidc","callbackURL":"/"}')" || fail "the console did not start a sign-in"
authorize="$(jq -r '.url // empty' <<<"$start")"
[ -n "$authorize" ] || fail "the console's sign-in returned no authorization URL: $start"
login_page="$(https -c "$jar" -b "$jar" -L "$authorize")" || fail "Keycloak's login page did not load"
callback="$(keycloak_login "$jar" "$login_page" alice)"
case "$callback" in "$UI"/*) ;; *) fail "Keycloak did not redirect back to the console after login (got '$callback')" ;; esac
https -c "$jar" -b "$jar" -L -o /dev/null "$callback" || fail "the console's OIDC callback failed"
email="$(https -b "$jar" "$UI/api/auth/get-session" | jq -r '.user.email // empty')"
[ "$email" = alice@example.com ] || fail "the console session is for '$email', want alice@example.com"
pass "console session for $email"

admin_token="$(password_token admin "$USER_PASSWORD")" || fail "Keycloak issued no token for admin"
alice_token="$(password_token alice "$USER_PASSWORD")" || fail "Keycloak issued no token for alice"
expect 401 "$(call GET "$EM/v1/me" -)" "Enterprise Manager without a token"
expect 200 "$(call GET "$EM/v1/me" "$alice_token")" "GET /v1/me as alice"
pass "Enterprise Manager accepts alice's token and refuses a missing one"

# --- 2. SCIM sync --------------------------------------------------------------------------
step "2. a user added to Keycloak is in the directory once sync-users.sh runs"
kc_token="$(keycloak_admin_token)" || fail "could not sign in to Keycloak's admin API"
kc_admin="https://$HOST_AUTH/admin/realms/$REALM"
# A run that was killed outright can leave the user in Keycloak.
for id in $(https -f -H "Authorization: Bearer $kc_token" "$kc_admin/users?exact=true&username=$SYNC_USER" | jq -r '.[].id'); do
  https -fo /dev/null -X DELETE -H "Authorization: Bearer $kc_token" "$kc_admin/users/$id" ||
    fail "could not delete a leftover $SYNC_USER from Keycloak"
done
new_password="$(openssl rand -hex 16)"
jq -n --arg u "$SYNC_USER" --arg pw "$new_password" '{
  username: $u, enabled: true, email: ($u + "@example.com"), emailVerified: true,
  firstName: "Verify", lastName: "User", groups: ["/everyone"],
  credentials: [{type: "password", value: $pw, temporary: false}]}' |
  https -f -X POST -H "Authorization: Bearer $kc_token" -H 'Content-Type: application/json' \
    "$kc_admin/users" -d @- >/dev/null || fail "could not add $SYNC_USER to Keycloak"
sync_user_id="$(https -f -H "Authorization: Bearer $kc_token" "$kc_admin/users?exact=true&username=$SYNC_USER" | jq -re '.[0].id')" ||
  fail "could not read back $SYNC_USER from Keycloak"
new_token="$(password_token "$SYNC_USER" "$new_password")" || fail "Keycloak issued no token for $SYNC_USER"
# The AI Gateway refuses a caller the directory cannot resolve, so it shows whether the
# directory knows the user. The user is new to Keycloak, so its sub is new to the directory.
expect 403 "$(call GET "$GATEWAY/anthropic/v1/models" "$new_token")" "the AI Gateway as $SYNC_USER before the sync"
"$ARCH_DIR/sync-users.sh" || fail "sync-users.sh failed"
expect 200 "$(call GET "$GATEWAY/anthropic/v1/models" "$new_token")" "the AI Gateway as $SYNC_USER after the sync"
pass "the directory refused $SYNC_USER before the sync and accepts them after it"
remove_sync_user

# --- 3. Budget -----------------------------------------------------------------------------
step "3. admin sets the default budget"
r="$(call GET "$EM/v1/budgets/default" "$admin_token")"
case "$(status "$r")" in
  200) pass "a default budget exists: $(body "$r" | jq -c '{limit_usd, period}')" ;;
  404)
    expect 204 "$(call PUT "$EM/v1/budgets/default" "$admin_token" '{"limit_usd":"5.000000000","period":"day"}')" \
      "PUT /v1/budgets/default as admin"
    expect 200 "$(call GET "$EM/v1/budgets/default" "$admin_token")" "GET /v1/budgets/default after the write"
    pass "set the default budget to 5 USD a day"
    ;;
  *) fail "GET /v1/budgets/default as admin returned $(status "$r")" ;;
esac
expect 403 "$(call PUT "$EM/v1/budgets/default" "$alice_token" '{"limit_usd":"1000.000000000","period":"day"}')" \
  "PUT /v1/budgets/default as alice"
pass "alice cannot change the budget"

# --- 4. Spend ------------------------------------------------------------------------------
step "4. alice sends an AI Gateway request and her spend rises"
# spent: alice's spend today in USD. Fails unless the summary answers 200 with the field, so a
# failed read cannot pass for zero spend.
spent() {
  local r
  r="$(call GET "$EM/v1/me/budgets/summary" "$alice_token")"
  [ "$(status "$r")" = 200 ] || fail "GET /v1/me/budgets/summary as alice returned $(status "$r"): $(body "$r")"
  body "$r" | jq -re '.day.used_usd' || fail "alice's budget summary has no day.used_usd: $(body "$r")"
}
before="$(spent)" || exit 1
message="$(jq -cn --arg m "$MODEL" '{model: $m, max_tokens: 16, messages: [{role: "user", content: "Say hello."}]}')"
anthropic() { https -X POST "$GATEWAY/anthropic/v1/messages" -H 'anthropic-version: 2023-06-01' \
  -H 'Content-Type: application/json' -w '\n%{http_code}' "$@" -d "$message"; }
expect 401 "$(anthropic)" "the AI Gateway without a token"
r=""
for _ in $(seq 1 24); do
  r="$(anthropic -H "Authorization: Bearer $alice_token")"
  [ "$(status "$r")" = 200 ] && break
  sleep 5
done
expect 200 "$r" "POST /anthropic/v1/messages as alice"
[ "$(body "$r" | jq -r '.content[0].text // empty')" != "" ] || fail "the AI Gateway's reply has no text: $(body "$r")"
pass "the gateway answered $MODEL"
after="$before"
for _ in $(seq 1 30); do
  after="$(spent)" || exit 1
  awk -v a="$after" -v b="$before" 'BEGIN { exit !(a > b) }' && break
  sleep 2
done
awk -v a="$after" -v b="$before" 'BEGIN { exit !(a > b) }' ||
  fail "alice's spend today stayed at $before USD after the request"
pass "alice's spend today rose from $before to $after USD"

# --- 5. Connector --------------------------------------------------------------------------
step "5. admin adds a connector and alice sees it"
gw="$EM/v1/gateways/$CONNECTOR_GATEWAY_ID/connectors"
endpoint="$(kubectl -n "$NAMESPACE" get mcpserver fetch -o jsonpath='{.status.url}')"
[ -n "$endpoint" ] || fail "the sample MCP server has no URL yet (kubectl -n $NAMESPACE get mcpserver fetch)"
r="$(call GET "$gw" "$admin_token")"
expect 200 "$r" "GET the gateway's connectors as admin"
for id in $(body "$r" | jq -r --arg n "$CONNECTOR" '.items[] | select(.name == $n) | .id'); do
  expect 204 "$(call DELETE "$gw/$id" "$admin_token")" "DELETE the previous $CONNECTOR"
done
connector="$(jq -cn --arg n "$CONNECTOR" --arg e "$endpoint" '{
  name: $n, description: "The sample fetch MCP server, added by verify.sh.",
  endpoint: $e, transport: "streamable-http", draft: false, allow_private_ips: true,
  auth: {type: "none"}}')"
r="$(call POST "$gw" "$admin_token" "$connector")"
expect 201 "$r" "POST a connector as admin"
connector_id="$(body "$r" | jq -r '.id')"
everyone="$(https -H "Authorization: Bearer $SCIM_TOKEN" \
  "$EM/scim/keycloak/v2/Groups?filter=$(jq -rn '"displayName eq \"everyone\""|@uri')" | jq -r '.Resources[0].id // empty')"
[ -n "$everyone" ] || fail "the directory has no everyone group; did sync-users.sh run?"
# The policy write is optimistic: it carries the ETag of the policy it replaces.
etag="$(https -o /dev/null -D - -H "Authorization: Bearer $admin_token" "$EM/v1/connectors/$connector_id/policy" |
  awk 'tolower($1) == "etag:" { sub(/\r$/, ""); print $2 }')"
[ -n "$etag" ] || fail "GET /v1/connectors/$connector_id/policy returned no ETag"
r="$(https -X PUT "$EM/v1/connectors/$connector_id/policy/groups" -w '\n%{http_code}' \
  -H "Authorization: Bearer $admin_token" -H 'Content-Type: application/json' -H "If-Match: $etag" \
  -d "{\"group_ids\":[\"$everyone\"]}" || printf '\n000')"
case "$(status "$r")" in 200 | 204) ;; *) fail "granting $CONNECTOR to everyone returned $(status "$r"): $(body "$r")" ;; esac
# A new connector reaches a user's list once the directory has verified it and applied the
# grant, which can take a few seconds.
for _ in $(seq 1 24); do
  r="$(call GET "$EM/v1/me/gateways/$CONNECTOR_GATEWAY_ID/connectors" "$alice_token")"
  expect 200 "$r" "GET /v1/me/gateways/$CONNECTOR_GATEWAY_ID/connectors as alice"
  body "$r" | jq -e --arg n "$CONNECTOR" 'any(.items[]; .name == $n)' >/dev/null && break
  sleep 5
done
body "$r" | jq -e --arg n "$CONNECTOR" 'any(.items[]; .name == $n)' >/dev/null ||
  fail "alice does not see $CONNECTOR among her connectors after two minutes: $(body "$r")"
pass "alice sees $CONNECTOR"
# The Connector Gateway serves a user only the connectors they turned on.
expect 201 "$(call POST "$EM/v1/me/connections" "$alice_token" "$(jq -cn --arg c "$connector_id" --arg g "$CONNECTOR_GATEWAY_ID" \
  '{connector_id: $c, gateway_id: $g, enabled: true, tools_enabled_by_default: true}')")" \
  "POST /v1/me/connections for $CONNECTOR as alice"
pass "alice turned $CONNECTOR on"

# --- 6. Connector Gateway ------------------------------------------------------------------
step "6. alice signs in to the Connector Gateway as an MCP client and lists the tools"
MCP="$CONNECTORS/gw/mcp"
expect 401 "$(call POST "$MCP" - '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')" "the Connector Gateway without a token"
# The client registers itself, then runs the authorization code flow with PKCE. The gateway's
# authorization server asks alice to consent, then sends her to Keycloak to sign in. Nothing
# listens on the redirect URI: the flow stops at the redirect that carries the code.
redirect_uri=http://127.0.0.1:8976/callback
client_id="$(jq -cn --arg r "$redirect_uri" '{client_name: "verify.sh", redirect_uris: [$r],
  grant_types: ["authorization_code", "refresh_token"], response_types: ["code"], token_endpoint_auth_method: "none"}' |
  https -f -X POST "$CONNECTORS/oauth/register" -H 'Content-Type: application/json' -d @- | jq -re '.client_id')" ||
  fail "the Connector Gateway did not register an OAuth client"
verifier="$(openssl rand -hex 32)"
challenge="$(printf %s "$verifier" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
state="$(openssl rand -hex 16)"
uri() { jq -rn --arg v "$1" '$v|@uri'; }
jar="$WORK/mcp-cookies"
consent="$(https -c "$jar" -b "$jar" -L "$CONNECTORS/oauth/authorize?response_type=code&client_id=$client_id&redirect_uri=$(uri "$redirect_uri")&scope=$(uri 'openid offline_access')&state=$state&code_challenge=$challenge&code_challenge_method=S256&resource=$(uri "$MCP")")" ||
  fail "the Connector Gateway's authorization endpoint failed"
handle="$(grep -o 'name="handle" value="[^"]*"' <<<"$consent" | sed 's/.*value="//; s/"$//')"
[ -n "$handle" ] || fail "the Connector Gateway showed no consent form"
login_page="$(https -c "$jar" -b "$jar" -L -H "Origin: $CONNECTORS" \
  --data-urlencode "handle=$handle" --data-urlencode decision=approve "$CONNECTORS/oauth/consent")" ||
  fail "the Connector Gateway refused alice's consent"
next="$(keycloak_login "$jar" "$login_page" alice)"
# Keycloak redirects to the gateway's callback, which redirects to the client with the code.
for _ in 1 2 3; do
  case "$next" in "$redirect_uri"*) break ;; "$CONNECTORS"/*) ;; *) fail "unexpected redirect during the MCP sign-in: '$next'" ;; esac
  next="$(https -c "$jar" -b "$jar" -o /dev/null -w '%{redirect_url}' "$next")"
done
case "$next" in "$redirect_uri"*) ;; *) fail "the MCP sign-in did not reach the client's redirect URI (got '$next')" ;; esac
[ "$(sed -n 's/.*[?&]state=\([^&]*\).*/\1/p' <<<"$next")" = "$state" ] || fail "the MCP sign-in returned a different state"
code="$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$next")"
mcp_token="$(https -f -X POST "$CONNECTORS/oauth/token" --data-urlencode grant_type=authorization_code \
  --data-urlencode "code=$code" --data-urlencode "redirect_uri=$redirect_uri" --data-urlencode "client_id=$client_id" \
  --data-urlencode "code_verifier=$verifier" --data-urlencode "resource=$MCP" | jq -re '.access_token')" ||
  fail "the Connector Gateway did not exchange the code for a token"
pass "alice signed in to the Connector Gateway"

# mcp <session-id|-> <json-rpc>: posts one JSON-RPC message to the gateway as alice. It prints
# the response headers, a blank line, the body and a line with the status code.
mcp() {
  local args=(-D - -X POST "$MCP" -w '\n%{http_code}' -H "Authorization: Bearer $mcp_token"
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$2")
  [ "$1" = - ] || args+=(-H "Mcp-Session-Id: $1")
  https "${args[@]}" || printf '\n000'
}
# rpc_result: the JSON-RPC message in a response body, plain JSON or a server-sent event.
rpc_result() { sed -n 's/^data: //; /^{/p'; }
r="$(mcp - "$(jq -cn '{jsonrpc: "2.0", id: 1, method: "initialize", params: {protocolVersion: "2025-06-18",
  capabilities: {}, clientInfo: {name: "verify.sh", version: "1"}}}')")"
expect 200 "$r" "MCP initialize as alice"
session="$(awk 'tolower($1) == "mcp-session-id:" { sub(/\r$/, ""); print $2 }' <<<"$r")"
[ -n "$session" ] || fail "MCP initialize returned no Mcp-Session-Id"
expect 202 "$(mcp "$session" '{"jsonrpc":"2.0","method":"notifications/initialized"}')" "the MCP initialized notification"
# The gateway learns of a new connection asynchronously, so the tool can take a moment to appear.
tools=""
for _ in $(seq 1 30); do
  r="$(mcp "$session" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
  expect 200 "$r" "MCP tools/list as alice"
  tools="$(body "$r" | rpc_result | jq -c '[.result.tools[].name]')"
  jq -e --arg n "$CONNECTOR" 'any(.[]; startswith($n + "_") and endswith("_fetch"))' <<<"$tools" >/dev/null && break
  sleep 2
done
jq -e --arg n "$CONNECTOR" 'any(.[]; startswith($n + "_") and endswith("_fetch"))' <<<"$tools" >/dev/null ||
  fail "alice's tools/list has no fetch tool from $CONNECTOR: $tools"
pass "alice's MCP session lists $(jq -r --arg n "$CONNECTOR" 'map(select(startswith($n + "_"))) | join(", ")' <<<"$tools")"

log "all checks passed"
