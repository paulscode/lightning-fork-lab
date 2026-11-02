#!/usr/bin/env bash
# E4: isolation from the SHA256d Lightning network.
#
#  - A stock lnd peer is dropped in both directions. Since option_blake2b
#    (an even feature bit) separates the chains, the stock node is usually
#    the one that hangs up, on the unknown required bit, before Lightning
#    Fork has judged its init; which side refuses does not matter, that no
#    connection stays does. (Until 2026-09-17 a strict Lightning Fork refused
#    a peer that sent no networks list, and lf2 was a lenient one that kept
#    the connection; require-peer-networks is now off by default, and nothing
#    keeps a connection to a stock node.)
#  - No channel can be opened either way.
#  - Invoices decode across chains (the chain's own BOLT 11 prefix was
#    withdrawn), but a payment of one without option_blake2b in its features
#    is refused.
source "$(dirname "$0")/lib.sh"

wait_for "lnd-sha rpc" 120 lnd_ready lnd-sha
wait_for "lnd-sha synced" 120 lnd_synced lnd-sha
wait_for "lf1 synced" 120 lnd_synced lf1
wait_for "lf2 synced" 120 lnd_synced lf2

sha_pub=$(pubkey_of lnd-sha)
lf1_pub=$(pubkey_of lf1)
lf2_pub=$(pubkey_of lf2)

# connected_to NODE PUB: whether NODE lists PUB as a peer.
connected_to() {
    $COMPOSE exec -T "$1" lncli --network=regtest --rpcserver=127.0.0.1:10009 \
        listpeers | jq -e ".peers[] | select(.pub_key == \"$2\")" >/dev/null
}

step "E4: lf1 connects to stock lnd and the connection does not stay"
lf1 connect "$sha_pub@lnd-sha:9735" >/dev/null 2>&1 || true
sleep 3
connected_to lf1 "$sha_pub" && fail "lf1 kept a stock lnd peer"
connected_to lnd-sha "$lf1_pub" && fail "stock lnd kept lf1 as a peer"
pass "lf1 and the stock node are not connected"

step "E4: stock lnd connects inbound to lf2 and the connection does not stay"
lndsha connect "$lf2_pub@lf2:9735" >/dev/null 2>&1 || true
sleep 3
connected_to lf2 "$sha_pub" && fail "lf2 kept an inbound stock lnd peer"
connected_to lnd-sha "$lf2_pub" && fail "stock lnd kept lf2 as a peer"
pass "inbound stock peer dropped as well"

step "E4: no channel opens either way"
# Fund both sides so a channel open is attempted for real.
fund_lf lf2 1
addr=$(lndsha newaddress p2tr | jq -r .address)
sha -rpcwallet=lab sendtoaddress "$addr" 1 >/dev/null
mine_sha 6
wait_for "lnd-sha funds" 60 sh -c "[ \"\$($COMPOSE exec -T lnd-sha lncli --network=regtest --rpcserver=127.0.0.1:10009 walletbalance | jq -r .confirmed_balance)\" != 0 ]"
wait_for "lf2 synced after funding" 120 lnd_synced lf2
wait_for "lnd-sha synced after funding" 120 lnd_synced lnd-sha

out=$(lf2 openchannel --connect "lnd-sha:9735" --node_key="$sha_pub" --local_amt=500000 2>&1 || true)
echo "$out" | grep -q '"funding_txid"' && fail "lf2 -> lnd-sha openchannel succeeded: $out"
pass "lf2 -> lnd-sha open refused: $(echo "$out" | head -1 | cut -c1-120)"

out=$(lndsha openchannel --connect "lf2:9735" --node_key="$lf2_pub" --local_amt=500000 2>&1 || true)
echo "$out" | grep -q '"funding_txid"' && fail "lnd-sha -> lf2 openchannel succeeded: $out"
pass "lnd-sha -> lf2 open refused: $(echo "$out" | head -1 | cut -c1-120)"

[ "$(lf2 pendingchannels | jq '.pending_open_channels | length')" = 0 ] || fail "lf2 has a pending channel with the SHA256d node"
[ "$(lndsha pendingchannels | jq '.pending_open_channels | length')" = 0 ] || fail "lnd-sha has a pending channel with lf2"

step "E4: invoices do not cross"
sha_inv=$(lndsha addinvoice --amt 1000 | jq -r .payment_request)
[[ "$sha_inv" == lnbcrt* ]] || fail "stock invoice is not lnbcrt...: $sha_inv"
out=$(lf1 decodepayreq "$sha_inv" 2>&1 || true)
echo "$out" | grep -q '"num_satoshis"' || { echo "$out"; fail "lf1 could not decode the lnbcrt invoice"; }
pass "lf1 decodes lnbcrt...: the prefix no longer separates the chains"

lf_inv=$(lf1 addinvoice --amt 1000 | jq -r .payment_request)
[[ "$lf_inv" == lnbcrt* ]] || fail "Lightning Fork invoice is not lnbcrt...: $lf_inv"
out=$(lndsha decodepayreq "$lf_inv" 2>&1 || true)
echo "$out" | grep -q '"num_satoshis"' || { echo "$out"; fail "stock lnd could not decode the lnbcrt invoice"; }
pass "stock lnd decodes this chain's invoice too: the gap runs both ways"

# The invoice decodes, so what stops the payment is not the prefix. Since
# 0.21.3-beta-blake2b.12 it is refused outright: this chain's invoices set
# option_blake2b in their features and one that does not is not paid.
out=$(lf1 payinvoice --force "$sha_inv" 2>&1 || true)
echo "$out" | grep -qi "option_blake2b" || { echo "$out"; fail "expected the payment to be refused for lacking option_blake2b"; }
pass "payment refused: the stock invoice does not set option_blake2b"

step "E4: no gossip crossed"
[ "$(lf2 describegraph | jq '.edges | length')" = 0 ] || fail "lf2 graph has edges from the SHA256d side"
pass "lf2 graph carries no SHA256d channels"

lf2 disconnect "$sha_pub" >/dev/null 2>&1 || true
record e4-isolation result PASS
echo "E4 PASSED"
