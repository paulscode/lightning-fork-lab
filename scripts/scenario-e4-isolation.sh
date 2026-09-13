#!/usr/bin/env bash
# E4: isolation from the SHA256d Lightning network.
#
#  - lf1 (strict, the default) drops a stock lnd peer because it sends no
#    networks list.
#  - lf2 (lenient) keeps the connection but every channel open fails on the
#    chain hash, in both directions.
#  - Invoices do not cross: lf refuses lnbc..., stock lnd refuses lnblakert...
source "$(dirname "$0")/lib.sh"

wait_for "lnd-sha rpc" 120 lnd_ready lnd-sha
wait_for "lnd-sha synced" 120 lnd_synced lnd-sha
wait_for "lf1 synced" 120 lnd_synced lf1
wait_for "lf2 synced" 120 lnd_synced lf2

sha_pub=$(pubkey_of lnd-sha)
lf1_pub=$(pubkey_of lf1)
lf2_pub=$(pubkey_of lf2)

step "E4: strict lf1 connects to stock lnd and must drop it"
lf1 connect "$sha_pub@lnd-sha:9735" >/dev/null 2>&1 || true
sleep 3
if lf1 listpeers | jq -e ".peers[] | select(.pub_key == \"$sha_pub\")" >/dev/null; then
    fail "lf1 (strict) kept a stock lnd peer that sent no networks list"
fi
# Capture first: grep -q closing the pipe early would fail the pipeline
# under pipefail even on a match.
lf1_logs=$($COMPOSE logs --no-color lf1 2>&1)
echo "$lf1_logs" | grep -q "did not advertise the chains it serves" \
    || { echo "$lf1_logs" | grep -i "$sha_pub\|networks" | tail -5; fail "lf1 did not log the missing-networks refusal"; }
pass "lf1 dropped the stock peer: 'did not advertise the chains it serves'"

step "E4: stock lnd connects inbound to strict lf1 and must be dropped too"
lndsha connect "$lf1_pub@lf1:9735" >/dev/null 2>&1 || true
sleep 3
if lf1 listpeers | jq -e ".peers[] | select(.pub_key == \"$sha_pub\")" >/dev/null; then
    fail "lf1 (strict) accepted an inbound stock lnd peer"
fi
pass "inbound stock peer refused as well"

step "E4: lenient lf2 keeps the connection but channels fail on chain hash"
lf2 connect "$sha_pub@lnd-sha:9735" >/dev/null 2>&1 || true
wait_for "lf2<->lnd-sha connected" 30 sh -c "$COMPOSE exec -T lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 listpeers | jq -e '.peers[] | select(.pub_key == \"$sha_pub\")' >/dev/null"
pass "lf2 (lenient) is connected to lnd-sha"

# Fund both sides so a channel open is attempted for real.
fund_lf lf2 1
addr=$(lndsha newaddress p2tr | jq -r .address)
sha -rpcwallet=lab sendtoaddress "$addr" 1 >/dev/null
mine_sha 6
wait_for "lnd-sha funds" 60 sh -c "[ \"\$($COMPOSE exec -T lnd-sha lncli --network=regtest --rpcserver=127.0.0.1:10009 walletbalance | jq -r .confirmed_balance)\" != 0 ]"
wait_for "lf2 synced after funding" 120 lnd_synced lf2
wait_for "lnd-sha synced after funding" 120 lnd_synced lnd-sha

out=$(lf2 openchannel --node_key="$sha_pub" --local_amt=500000 2>&1 || true)
echo "$out" | grep -qi "chain" || { echo "$out"; fail "lf2 -> lnd-sha openchannel did not fail on the chain hash"; }
pass "lf2 -> lnd-sha open refused: $(echo "$out" | head -1 | cut -c1-120)"

out=$(lndsha openchannel --node_key="$lf2_pub" --local_amt=500000 2>&1 || true)
echo "$out" | grep -qi "chain" || { echo "$out"; fail "lnd-sha -> lf2 openchannel did not fail on the chain hash"; }
pass "lnd-sha -> lf2 open refused: $(echo "$out" | head -1 | cut -c1-120)"

[ "$(lf2 pendingchannels | jq '.pending_open_channels | length')" = 0 ] || fail "lf2 has a pending channel with the SHA256d node"
[ "$(lndsha pendingchannels | jq '.pending_open_channels | length')" = 0 ] || fail "lnd-sha has a pending channel with lf2"

step "E4: invoices do not cross"
sha_inv=$(lndsha addinvoice --amt 1000 | jq -r .payment_request)
[[ "$sha_inv" == lnbcrt* ]] || fail "stock invoice is not lnbcrt...: $sha_inv"
out=$(lf1 decodepayreq "$sha_inv" 2>&1 || true)
echo "$out" | grep -q "SHA256" || { echo "$out"; fail "lf1 did not refuse the lnbcrt invoice by naming the SHA256 network"; }
pass "lf1 refuses lnbcrt...: $(echo "$out" | head -1 | cut -c1-100)"

lf_inv=$(lf1 addinvoice --amt 1000 | jq -r .payment_request)
[[ "$lf_inv" == lnblakert* ]] || fail "Lightning Fork invoice is not lnblakert...: $lf_inv"
out=$(lndsha decodepayreq "$lf_inv" 2>&1 || true)
echo "$out" | grep -qi "not for current active network\|invalid\|error" || { echo "$out"; fail "stock lnd decoded a lnblakert invoice"; }
pass "stock lnd refuses lnblakert...: $(echo "$out" | head -1 | cut -c1-100)"

out=$(lf1 payinvoice --force "$sha_inv" 2>&1 || true)
echo "$out" | grep -q "SHA256" || { echo "$out"; fail "lf1 payinvoice of a lnbcrt invoice did not refuse on the network"; }
pass "lf1 payinvoice refuses a SHA256d invoice"

step "E4: no gossip crossed"
[ "$(lf2 describegraph | jq '.edges | length')" = 0 ] || fail "lf2 graph has edges from the SHA256d side"
pass "lf2 graph carries no SHA256d channels"

lf2 disconnect "$sha_pub" >/dev/null 2>&1 || true
record e4-isolation result PASS
echo "E4 PASSED"
