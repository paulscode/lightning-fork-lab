#!/usr/bin/env bash
# The bridge running inside Lightning Fork, end to end on the lab's four nodes:
#
#   lf2 (payer, BLAKE2b) --> lf1 (bridge) ... lnd-sha (bridge) --> lnd-sha2
#
# Needs `make bridge-setup` and `scripts/pace-blocks.sh` first: the topology,
# and chains whose block timestamps look like a real chain's. lf1 must be
# running with docker-compose.bridge.yml layered on, from a build that has the
# bridgerpc tag.
#
# What it covers, in order: a payment out to Bitcoin; the reverse direction,
# which is only reachable because a direction is chosen by option_blake2b
# rather than by which node can decode the invoice; a refund when the
# destination cancels; quoting the same invoice again once an attempt has
# ended; refusing to pay the bridge itself; a participant's credential, which
# reaches the payer calls and nothing else and is limited on its own; the rate
# changed while running; and a swap that survives the node being killed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

COMPOSE="docker compose -f docker-compose.yml -f docker-compose.bridge.yml"
AMT="${AMT:-2000000}"

# lf1's image has neither curl nor od, so REST is called from the host, at
# lf1's address on the lab network, with its certificate unchecked: this is a
# lab, and the scenario is about the bridge, not the transport.
lf1_addr() {
    $COMPOSE ps -q lf1 | xargs docker inspect --format \
        '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
}

mac_of() {
    $COMPOSE exec -T lf1 cat \
        /root/.lnd/data/chain/bitcoin/regtest/admin.macaroon | xxd -p | tr -d '\n'
}

# REST on lf1 with a given macaroon. Prints the body, then the HTTP status on
# its own line, so a caller can check both.
rest_as() {
    local mac="$1" method="$2" path="$3" body="${4:-}"
    if [ -n "$body" ]; then
        curl -s -k -w '\n%{http_code}' -X "$method" \
            -H "Grpc-Metadata-macaroon: $mac" -d "$body" \
            "https://$(lf1_addr):8080$path"
    else
        curl -s -k -w '\n%{http_code}' -X "$method" \
            -H "Grpc-Metadata-macaroon: $mac" "https://$(lf1_addr):8080$path"
    fi
}

# The operator's own calls, body only.
bridge() {
    local method="$1" body="${2:-}"
    if [ -n "$body" ]; then
        rest_as "$(mac_of)" POST "/v2/bridge/$method" "$body" | sed '$d'
    else
        rest_as "$(mac_of)" GET "/v2/bridge/$method" | sed '$d'
    fi
}

lncli_on() {
    local node="$1"; shift
    $COMPOSE exec -T "$node" lncli --network=regtest \
        --rpcserver=127.0.0.1:10009 "$@" </dev/null
}

invoice_on() {
    lncli_on "$1" addinvoice --amt_msat="$AMT" --memo="$2" | jq -r .payment_request
}

swap_state() {
    bridge swap "{\"hash\":\"$1\"}" | jq -r .state
}

fail() {
    echo "FAIL: $*"
    exit 1
}

# Waits rather than sleeps: a fixed pause is either too short on a loaded
# machine or wasted time on an idle one.
wait_for_state() {
    local hash="$1" want="$2" secs="${3:-90}" seen
    for _ in $(seq 1 "$secs"); do
        seen=$(swap_state "$hash" 2>/dev/null || true)
        [ "$seen" = "$want" ] && return 0
        sleep 1
    done
    fail "swap stayed in ${seen:-unknown}, wanted $want"
}

# Ready means the bridge answers as enabled with nothing refused, not merely
# that curl connected: the REST listener opens before the sub-server starts.
wait_ready() {
    local secs="${1:-120}" resp
    for _ in $(seq 1 "$secs"); do
        resp=$(bridge status 2>/dev/null || true)
        if [ -n "$resp" ] && echo "$resp" | jq -e \
            '.enabled == true and (.refusals | length) == 0' \
            >/dev/null 2>&1; then

            return 0
        fi
        sleep 1
    done

    fail "the bridge is not ready: ${resp:-no answer}"
}

# The preimage a node holds for a payment it made, by payment hash in hex.
paid_preimage() {
    lncli_on "$1" listpayments --max_payments 50 \
        | jq -r --arg h "$2" '.payments[] | select(.payment_hash == $h
            and .status == "SUCCEEDED") | .payment_preimage' | head -1
}

b64_to_hex() {
    echo "$1" | base64 -d | od -An -tx1 -v | tr -d ' \n'
}

echo "== the bridge is ready to quote =="
wait_ready 180
info=$(bridge info)
echo "$info" | jq -e '[.directions[] | select(.open)] | length == 2' \
    >/dev/null || fail "not both directions open: $info"
# Read first: docker compose exec reads stdin, and inside the pipeline below
# it would swallow the JSON meant for jq.
lf1_key=$(lncli_on lf1 getinfo </dev/null | jq -r .identity_pubkey)
echo "$info" | jq -e --arg n "$lf1_key" '.node == $n and .version == 1' \
    >/dev/null || fail "info: $info"
echo "PASS"

echo "== a Bitcoin invoice paid from the BLAKE2b chain =="
inv=$(invoice_on lnd-sha2 "to Bitcoin")
q=$(bridge quote "{\"invoice\":\"$inv\"}")
[ "$(echo "$q" | jq -r .direction)" = "toSHA256" ] \
    || fail "routed to $(echo "$q" | jq -r .direction): $q"
hash=$(echo "$q" | jq -r .hash)
hold=$(echo "$q" | jq -r .hold_invoice)
# The payer's checks: same hash, payable to the bridge's node.
dec=$(lncli_on lf2 decodepayreq "$hold")
[ "$(echo "$dec" | jq -r .payment_hash)" = "$(b64_to_hex "$hash")" ] \
    || fail "the hold invoice is for another hash"
[ "$(echo "$dec" | jq -r .destination)" = "$(echo "$info" | jq -r .node)" ] \
    || fail "the hold invoice pays someone else"
lncli_on lf2 payinvoice --force --timeout=120s "$hold" >/dev/null 2>&1 &
wait_for_state "$hash" settled
wait
pre=$(paid_preimage lf2 "$(b64_to_hex "$hash")")
[ -n "$pre" ] || fail "the payer holds no preimage"
[ "$(echo -n "$pre" | xxd -r -p | sha256sum | cut -d' ' -f1)" = "$(b64_to_hex "$hash")" ] \
    || fail "the payer's preimage does not prove the Bitcoin invoice was paid"
echo "PASS: settled, and the payer holds the proof"

echo "== a BLAKE2b invoice paid from Bitcoin (the reverse direction) =="
inv=$(invoice_on lf2 "to BLAKE2b")
q=$(bridge quote "{\"invoice\":\"$inv\"}")
[ "$(echo "$q" | jq -r .direction)" = "toBLAKE2b" ] \
    || fail "a BLAKE2b invoice routed to $(echo "$q" | jq -r .direction): $q"
hash=$(echo "$q" | jq -r .hash)
lncli_on lnd-sha2 payinvoice --force --timeout=120s \
    "$(echo "$q" | jq -r .hold_invoice)" >/dev/null 2>&1 &
wait_for_state "$hash" settled
wait
echo "PASS: settled"

echo "== the destination cancels: the payer gets their money back =="
inv=$(invoice_on lnd-sha2 "cancelled")
q=$(bridge quote "{\"invoice\":\"$inv\"}")
hash=$(echo "$q" | jq -r .hash)
lncli_on lnd-sha2 cancelinvoice "$(b64_to_hex "$hash")" >/dev/null
if lncli_on lf2 payinvoice --force --timeout=120s \
    "$(echo "$q" | jq -r .hold_invoice)" >/dev/null 2>&1; then
    fail "the payment went through to a cancelled invoice"
fi
wait_for_state "$hash" failed
echo "PASS: failed, nothing paid"

echo "== an invoice whose quote expired can be quoted again =="
inv=$(invoice_on lnd-sha2 "requote")
q=$(bridge quote "{\"invoice\":\"$inv\"}")
hash=$(echo "$q" | jq -r .hash)
again=$(bridge quote "{\"invoice\":\"$inv\"}")
echo "$again" | jq -r .message | grep -q '^in_progress: ' \
    || fail "a second quote while the first is live: $again"
echo "  waiting for the quote to expire (about two minutes)"
wait_for_state "$hash" expired 240
q=$(bridge quote "{\"invoice\":\"$inv\"}")
[ "$(echo "$q" | jq -r .hash)" = "$hash" ] || fail "re-quote: $q"
lncli_on lf2 payinvoice --force --timeout=120s \
    "$(echo "$q" | jq -r .hold_invoice)" >/dev/null 2>&1 &
wait_for_state "$hash" settled
wait
echo "PASS: quoted again and settled"

echo "== an invoice payable to the bridge itself is refused =="
inv=$(invoice_on lf1 "self")
r=$(bridge quote "{\"invoice\":\"$inv\"}")
echo "$r" | jq -r .message | grep -q '^self_payment: ' || fail "self: $r"
echo "PASS"

echo "== a participant's credential =="
pin=$($COMPOSE exec -T lf1 cat /root/.lnd/tls.cert | python3 -c '
import base64, hashlib, re, sys
pem = sys.stdin.read()
der = base64.b64decode("".join(re.findall(r"^[A-Za-z0-9+/=]+$", pem.split("BEGIN CERTIFICATE-----")[1].split("-----END")[0], re.M)))
h = hashlib.sha256(der).hexdigest().upper()
print(":".join(h[i:i+2] for i in range(0, 64, 2)))')
code=$(lncli_on lf1 bridge code --url https://lf1:8080 --label lab \
    --cert "$pin")
id=$(echo "$code" | jq -r .root_key_id)
pmac=$(echo "$code" | jq -r .code | python3 -c '
import base64, json, sys
s = sys.stdin.read().strip().split(":", 1)[1]
print(json.loads(base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)))["macaroon"])')
[ -n "$pmac" ] && [ "$pmac" != null ] || fail "no macaroon in $code"
out=$(rest_as "$pmac" GET /v2/bridge/info)
[ "$(echo "$out" | tail -1)" = 200 ] || fail "participant info: $out"
out=$(rest_as "$pmac" POST /v2/bridge/rate '{"rate":2}')
[ "$(echo "$out" | tail -1)" != 200 ] || fail "a participant set the rate"
out=$(rest_as "$pmac" GET /v2/bridge/status)
[ "$(echo "$out" | tail -1)" != 200 ] || fail "a participant read status"
echo "PASS: info allowed, rate and status refused"

# Two unpaid quotes is the default limit; the third is refused as limit.
for i in 1 2; do
    inv=$(invoice_on lnd-sha2 "limit $i")
    out=$(rest_as "$pmac" POST /v2/bridge/quote "{\"invoice\":\"$inv\"}")
    [ "$(echo "$out" | tail -1)" = 200 ] || fail "participant quote $i: $out"
done
inv=$(invoice_on lnd-sha2 "limit 3")
out=$(rest_as "$pmac" POST /v2/bridge/quote "{\"invoice\":\"$inv\"}")
[ "$(echo "$out" | tail -1)" = 429 ] || fail "third unpaid quote: $out"
echo "$out" | sed '$d' | jq -r .message | grep -q '^limit: ' \
    || fail "third unpaid quote, no limit code: $out"
# The operator is not limited by the participant's quotes.
inv=$(invoice_on lnd-sha2 "operator")
bridge quote "{\"invoice\":\"$inv\"}" | jq -e .hold_invoice >/dev/null \
    || fail "the operator was limited"
echo "PASS: limited at two unpaid quotes, and the operator is not"

lncli_on lf1 deletemacaroonid "$id" >/dev/null
out=$(rest_as "$pmac" GET /v2/bridge/info)
[ "$(echo "$out" | tail -1)" != 200 ] || fail "a revoked code still works"
echo "PASS: revoked"

echo "== the rate, changed while running =="
lncli_on lf1 bridge setrate 1.02 >/dev/null
bridge info | jq -e '.directions[] | select(.name == "toSHA256")
    | .rate == 1.02' >/dev/null || fail "info after setrate: $(bridge info)"
bridge status | jq -e '.rate == 1.02 and (.rate_expires_at | tonumber) > 0' \
    >/dev/null || fail "status after setrate"
lncli_on lf1 bridge setrate 1.0 >/dev/null
echo "PASS"

echo "== a swap that survives the node being killed =="
inv=$(invoice_on lnd-sha2 "recovery")
q=$(bridge quote "{\"invoice\":\"$inv\"}")
hash=$(echo "$q" | jq -r .hash)
hold=$(echo "$q" | jq -r .hold_invoice)

# Killed rather than stopped: a clean shutdown is the easy case, and the one
# that matters is the node going away without getting to write anything.
$COMPOSE kill lf1 >/dev/null
$COMPOSE up -d lf1 >/dev/null
wait_ready 180

after=$(swap_state "$hash" 2>/dev/null || true)
case "$after" in
    offered|funded|paying|paid|settled) ;;
    *) fail "after an abrupt kill the swap is ${after:-gone}" ;;
esac
echo "PASS: the swap survived an abrupt kill, in $after"

# A rate set before the kill is still in force after it.
bridge status | jq -e '.rate == 1' >/dev/null || fail "rate after restart"

lncli_on lf2 payinvoice --force --timeout=120s "$hold" >/dev/null 2>&1 &
wait_for_state "$hash" settled
wait
echo "PASS: settled after recovery"

echo "ALL BRIDGE SCENARIOS PASSED"
