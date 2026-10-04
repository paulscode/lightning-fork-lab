#!/usr/bin/env bash
# A bridge turned off with a payment unfinished finishes it, then stops.
#
# The platforms refuse to turn the bridge off while a payment is unfinished;
# this is the case that slips past them (a payment that starts in between, or
# a configuration edited by hand). With its SHA256 node down, a payer's HTLC
# is held at lf3; lf3 restarts with the bridge off; the node comes back. The
# bridge must finish the swap through it without quoting anything new, and
# stop once nothing is unfinished.
#
# Needs the state scenario-supervised.sh leaves (a channel from the SHA256
# node, a rate, the payer's channel to lf3). Puts lf3 back on at the end.
source "$(dirname "$0")/lib.sh"

C="docker compose -f docker-compose.yml -f docker-compose.supervised.yml"
OFF="$C -f docker-compose.supervised-off.yml"
lf3() { $C exec -T lf3 lncli --network=regtest --rpcserver=127.0.0.1:10009 "$@"; }
status() { lf3 bridge status; }
invoice_state() { lndsha2 lookupinvoice "$1" | jq -r .state; }

step "1. A payer's HTLC held, the SHA256 node down"
[ "$(status | jq -r .enabled)" = true ] || fail "run scenario-supervised.sh first"
inv=$(lndsha2 addinvoice --amt 30000 | jq -r .payment_request)
hold=$(lf3 bridge quote "$inv" | jq -r .hold_invoice)
[ -n "$hold" ] && [ "$hold" != null ] || fail "no quote"
hash=$(lndsha2 decodepayreq "$inv" | jq -r .payment_hash)
$C stop lf3-sha256 >/dev/null 2>&1
( lf2 payinvoice --force --timeout 10m "$hold" > results/drain-held.json 2>&1 || true ) &
payer=$!
wait_for "the bridge to hold the payer's HTLC" 120 \
    sh -c "[ \"\$($C exec -T lf3 lncli --network=regtest bridge status | jq -r .swaps_in_flight)\" -ge 1 ]"
pass "a swap is under way and cannot finish yet"

step "2. Lightning Fork restarts with the bridge off"
$OFF up -d lf3 >/dev/null 2>&1
wait_for "lf3 to answer" 120 lf3 getinfo
wait_for "the bridge to say it is finishing" 60 \
    sh -c "$C exec -T lf3 lncli --network=regtest bridge status | jq -e '.enabled == false and (.refusals | map(select(test(\"finishing the swaps\"))) | length == 1)' >/dev/null"
pass "off, with a swap unfinished: draining"
other=$(lndsha2 addinvoice --amt 20000 | jq -r .payment_request)
if lf3 bridge quote "$other" >/dev/null 2>&1; then
    fail "a draining bridge quoted"
fi
pass "nothing new is quoted"
[ "$(invoice_state "$hash")" = OPEN ] || fail "paid before the SHA256 node was back"

step "3. The SHA256 node comes back"
$C start lf3-sha256 >/dev/null 2>&1
wait_for "the SHA256 invoice to settle" 300 \
    sh -c "[ \"\$($COMPOSE exec -T lnd-sha2 lncli --network=regtest --rpcserver=127.0.0.1:10009 lookupinvoice $hash | jq -r .state)\" = SETTLED ]"
wait "$payer" || true
paid=$(lf2 listpayments --include_incomplete --max_payments 1000 \
    | jq -r --arg h "$hash" '.payments[] | select(.payment_hash==$h) | .status')
[ "$paid" = SUCCEEDED ] || fail "the payer's payment is $paid"
pass "the swap finished: the SHA256 invoice paid and the payer's payment settled"
wait_for "the bridge to stop once drained" 120 \
    sh -c "$C exec -T lf3 lncli --network=regtest bridge status | jq -e '(.refusals | map(select(test(\"finishing\"))) | length == 0)' >/dev/null"
pass "drained, the bridge stopped"

step "4. Back on"
$C up -d lf3 >/dev/null 2>&1
wait_for "lf3 to answer" 120 lf3 getinfo
wait_for "the bridge to be on again" 300 \
    sh -c "[ \"\$($C exec -T lf3 lncli --network=regtest bridge status | jq -r .sha256_node.state)\" = ready ]"
pass "lf3 is back as it was"

echo
echo "DRAIN SCENARIO PASSED"
