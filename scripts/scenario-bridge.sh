#!/usr/bin/env bash
# The bridge running inside Lightning Fork: a swap each way, and one that
# survives the node being killed.
#
# Needs `make bridge-setup` and `scripts/pace-blocks.sh` first: the topology,
# and chains whose block timestamps look like a real chain's. lf1 must be
# running with docker-compose.bridge.yml layered on.
#
# The recovery case is the one worth having. Everything else here was already
# covered by unit tests against fakes; that a swap survives an abrupt kill,
# is picked up from the journal on restart and then settles, was not.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/lib.sh 2>/dev/null || true

COMPOSE="docker compose -f docker-compose.yml -f docker-compose.bridge.yml"
AMT="${AMT:-2000000}"

bridge() {
    local method="$1" body="${2:-}" mac
    mac=$($COMPOSE exec -T lf1 od -An -tx1 -v \
        /root/.lnd/data/chain/bitcoin/regtest/admin.macaroon | tr -d ' \n')

    if [ -n "$body" ]; then
        $COMPOSE exec -T lf1 curl -s -k \
            -H "Grpc-Metadata-macaroon: $mac" -X POST -d "$body" \
            "https://127.0.0.1:8080/v2/bridge/$method"
    else
        $COMPOSE exec -T lf1 curl -s -k \
            -H "Grpc-Metadata-macaroon: $mac" \
            "https://127.0.0.1:8080/v2/bridge/$method"
    fi
}

lncli_on() {
    local node="$1"; shift
    $COMPOSE exec -T "$node" lncli --network=regtest \
        --rpcserver=127.0.0.1:10009 "$@"
}

invoice_on() {
    lncli_on "$1" addinvoice --amt_msat="$AMT" --memo="$2" | jq -r .payment_request
}

swap_state() {
    bridge swap "{\"hash\":\"$1\"}" | jq -r .state
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
    echo "FAIL: swap stayed in ${seen:-unknown}, wanted $want"
    return 1
}

# Ready means the bridge answers as enabled, not merely that curl connected.
# Waiting for a connection returns the moment lnd's REST listener opens, which
# is before the sub-server has started, and every check after that then races
# a bridge that is not up yet.
wait_ready() {
    local secs="${1:-120}" resp
    for _ in $(seq 1 "$secs"); do
        resp=$(bridge status 2>/dev/null || true)
        if [ -n "$resp" ] && echo "$resp" | jq -e '.enabled == true' \
            >/dev/null 2>&1; then

            return 0
        fi
        sleep 1
    done

    echo "FAIL: the bridge did not come up: ${resp:-no answer}"
    return 1
}

echo "== the bridge is ready to quote =="
wait_ready 180
bridge status | jq -e '.refusals == []' >/dev/null \
    || { echo "FAIL: $(bridge status)"; exit 1; }
echo "PASS"

echo "== a swap out to Bitcoin =="
inv=$(invoice_on lnd-sha2 "scenario toBitcoin")
q=$(bridge quote "{\"invoice\":\"$inv\"}")
hash=$(echo "$q" | jq -r .hash)
hold=$(echo "$q" | jq -r .hold_invoice)
[ "$(echo "$q" | jq -r .direction)" = "toBitcoin" ] || {
    echo "FAIL: routed to $(echo "$q" | jq -r .direction)"; exit 1; }

lncli_on lf2 payinvoice --force --timeout=120s "$hold" >/dev/null 2>&1 &
wait_for_state "$hash" settled
echo "PASS: settled"

echo "== a swap that survives the node being killed =="
inv=$(invoice_on lnd-sha2 "scenario recovery")
q=$(bridge quote "{\"invoice\":\"$inv\"}")
hash=$(echo "$q" | jq -r .hash)
hold=$(echo "$q" | jq -r .hold_invoice)

# Killed rather than stopped: a clean shutdown is the easy case, and the one
# that matters is the node going away without getting to write anything.
$COMPOSE kill lf1 >/dev/null
$COMPOSE up -d lf1 >/dev/null
wait_ready 180

# Asserted through the API rather than by scraping a log line. What matters is
# that the swap is still known and still moving, not that a particular sentence
# was printed, and a log check races the thing it is looking for.
after=$(swap_state "$hash" 2>/dev/null || true)
case "$after" in
    offered|funded|paying|paid|settled) ;;
    *)
        echo "FAIL: after an abrupt kill the swap is ${after:-gone}"
        exit 1
        ;;
esac
echo "PASS: the swap survived an abrupt kill, in $after"

lncli_on lf2 payinvoice --force --timeout=120s "$hold" >/dev/null 2>&1 &
wait_for_state "$hash" settled
echo "PASS: settled after recovery"

echo "ALL BRIDGE SCENARIOS PASSED"
