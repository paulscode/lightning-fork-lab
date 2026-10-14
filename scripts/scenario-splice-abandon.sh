#!/usr/bin/env bash
# A splice the Core Lightning port abandons after Lightning Fork signed it:
# the port splices in through splice_init and splice_update, Lightning Fork,
# contributing less, sends its tx_signatures first, and the port's user then
# aborts (abort_channels) instead of signing. The port forgets the splice;
# Lightning Fork keeps it (the port holds its signatures), can take no more
# updates on the channel, and closes it: cooperatively, recovering its
# balance; or, with an HTLC in flight that could never be settled, by force.
#
#   LF_IMAGE=lightning-fork:splice CLN_IMAGE=cln-blake2b-release:v7 \
#     bash scripts/scenario-splice-abandon.sh
set -euo pipefail
source "$(dirname "$0")/splice-lib.sh"

lf_chan()  { lf listchannels | jq -r ".channels[0].$1"; }
cln_cid()  { cln listpeerchannels | jq -r '[.channels[] | select(.state == "CHANNELD_NORMAL")][0].channel_id'; }

# cln_splice_abandoned: Core Lightning splices in 200,000 sat until the
# commitments are secured and Lightning Fork's tx_signatures are out, then
# its user aborts instead of signing.
cln_splice_abandoned() {
	local cid psbt out secured=false sent
	cid=$(cln_cid)
	sent=$(docker logs sp-lf 2>&1 | grep -c 'Sending TxSignatures' || true)
	out=$(cln -J fundpsbt -k satoshi=200000sat feerate=normal startweight=800 excess_as_change=true) || true
	psbt=$(echo "$out" | jq -r '.psbt // empty' 2>/dev/null) || true
	[ -n "$psbt" ] || fail "fundpsbt: $(echo "$out" | tr -d '\n' | cut -c1-200)"
	out=$(cln -J splice_init "$cid" 200000 "$psbt") || true
	psbt=$(echo "$out" | jq -r '.psbt // empty' 2>/dev/null) || true
	[ -n "$psbt" ] || fail "splice_init: $(echo "$out" | tr -d '\n' | cut -c1-200)"
	for i in $(seq 1 10); do
		out=$(cln -J splice_update "$cid" "$psbt") || fail "splice_update: $(echo "$out" | tr -d '\n' | cut -c1-200)"
		psbt=$(echo "$out" | jq -r .psbt)
		secured=$(echo "$out" | jq -r .commitments_secured)
		[ "$secured" = true ] && break
	done
	[ "$secured" = true ] || fail "commitments not secured"
	wait_for "Lightning Fork's tx_signatures sent" 30 sh -c "[ \$(docker logs sp-lf 2>&1 | grep -c 'Sending TxSignatures') -gt $sent ]"
	cln abort_channels "[\"$cid\"]" >/dev/null || fail "abort_channels refused"
}

step "abandon: fresh nodes, a channel of 1,000,000 sat"
for n in sp-lf sp-cln; do docker rm -f $n >/dev/null 2>&1 || true; docker volume rm -f $n-data >/dev/null 2>&1 || true; done
start_lf; start_cln; sleep 5
mine_b2b 1; wait_synced
ensure_b2b_funds 5
b2b -rpcwallet=lab sendtoaddress "$(lf newaddress p2wkh | jq -r .address)" 2 >/dev/null
# Two coins: an aborted splice keeps its coin reserved for a while.
b2b -rpcwallet=lab sendtoaddress "$(cln newaddr | jq -r .bech32)" 1 >/dev/null
b2b -rpcwallet=lab sendtoaddress "$(cln newaddr | jq -r .bech32)" 1 >/dev/null
mine_b2b 6; wait_synced
lf connect "$(cln getinfo | jq -r .id)@sp-cln:9735" >/dev/null
sleep 2
lf openchannel --node_key "$(cln getinfo | jq -r .id)" --local_amt 1000000 --push_amt 200000 --sat_per_vbyte 2 >/dev/null
mine_b2b 6; wait_synced
wait_for "channel open" 60 sh -c "[ \"\$(docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq -r '.channels[0].state')\" = CHANNELD_NORMAL ]"
wait_for "channel active" 60 sh -c "docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -e '.channels[0].active' >/dev/null"
local_bal=$(lf_chan local_balance)
before=$(lf walletbalance | jq -r .confirmed_balance)
pass "channel open, Lightning Fork's balance $local_bal"

step "abandon: Core Lightning splices in 200,000 sat, Lightning Fork signs first, its user aborts"
cln_splice_abandoned
wait_for "Lightning Fork takes it as disowned" 30 sh -c "docker logs sp-lf 2>&1 | grep -q 'disowned splice'"
wait_for "a cooperative close" 60 sh -c "docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 pendingchannels | jq -e '.waiting_close_channels | length == 1' >/dev/null"
if docker logs sp-lf 2>&1 | grep -q 'unable to close'; then
	fail "the close request failed: $(docker logs sp-lf 2>&1 | grep 'unable to close' | tail -1)"
fi
pass "the splice kept as disowned, the channel closing cooperatively"

step "abandon: the close confirms, the balance comes back"
for i in 1 2 3 4 5 6; do mine_b2b 1; sleep 2; done
wait_for "closed" 120 sh -c "[ \"\$(docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 closedchannels | jq -r '.channels[-1].close_type')\" = COOPERATIVE_CLOSE ]"
wait_for "Core Lightning closed" 60 sh -c "docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq -e '[.channels[] | select(.state == \"CHANNELD_NORMAL\")] | length == 0' >/dev/null"
after=$(lf walletbalance | jq -r .confirmed_balance)
[ $((after - before)) -gt $((local_bal - 2000)) ] || fail "recovered $((after - before)) of $local_bal"
pass "closed cooperatively, $((after - before)) of $local_bal sat recovered"

step "abandon: again with an HTLC in flight, which could never be settled"
lf openchannel --node_key "$(cln getinfo | jq -r .id)" --local_amt 1000000 --push_amt 200000 --sat_per_vbyte 2 >/dev/null
mine_b2b 6; wait_synced
wait_for "second channel open" 60 sh -c "docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq -e '[.channels[] | select(.state == \"CHANNELD_NORMAL\")] | length == 1' >/dev/null"
wait_for "second channel active" 60 sh -c "docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -e '.channels[0].active' >/dev/null"
pre=$(head -c 32 /dev/urandom | xxd -p -c 64)
hash=$(printf '%s' "$pre" | xxd -r -p | sha256sum | cut -d' ' -f1)
inv=$(lf addholdinvoice "$hash" --amt 30000 | jq -r .payment_request)
docker exec -d sp-cln sh -c "lightning-cli --network=regtest --lightning-dir=/data pay $inv > /tmp/hold.log 2>&1"
wait_for "HTLC in flight" 60 sh -c "[ \"\$(docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 lookupinvoice $hash | jq -r .state)\" = ACCEPTED ]"
local_bal=$(lf_chan local_balance)
before=$(lf walletbalance | jq -r .confirmed_balance)
cln_splice_abandoned
wait_for "Lightning Fork force closes" 60 sh -c "docker logs sp-lf 2>&1 | grep -q 'closing it by force'"
# A close counts after a few confirmations, more for a larger channel.
mine_b2b 6
wait_for "force close pending" 60 sh -c "docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 pendingchannels | jq -e '.pending_force_closing_channels | length == 1' >/dev/null"
pass "force closed with the HTLC in flight"

step "abandon: the HTLC cancelled, everything swept"
lf cancelinvoice "$hash" >/dev/null
for i in $(seq 1 20); do mine_b2b 10; sleep 2; done
wait_for "swept" 300 sh -c "[ \"\$(docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 pendingchannels | jq '.pending_force_closing_channels | length')\" = 0 ]"
after=$(lf walletbalance | jq -r .confirmed_balance)
[ $((after - before)) -gt $((local_bal - 3000)) ] || fail "recovered $((after - before)) of $local_bal"
[ "$(lf closedchannels | jq -r '.channels[-1].close_type')" = LOCAL_FORCE_CLOSE ] || fail "not a local force close"
pass "$((after - before)) of $local_bal sat recovered"

echo
echo "splice-abandon scenario: all steps passed"
