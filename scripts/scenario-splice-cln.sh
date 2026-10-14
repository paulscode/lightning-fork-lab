#!/usr/bin/env bash
# Splicing between Lightning Fork (sp-lf, built with protocol.splice) and the
# Core Lightning port's release (sp-cln, --experimental-splicing), on the
# lab's BLAKE2b regtest. Every direction: Lightning Fork adding and moving
# out, Core Lightning adding and moving out; payments both ways after each;
# a restart while a splice is pending; the announcement on the new funding;
# a force close each way afterwards, swept.
#
#   LF_IMAGE=lightning-fork:splice CLN_IMAGE=cln-blake2b-release:v7 \
#     bash scripts/scenario-splice-cln.sh
set -euo pipefail
source "$(dirname "$0")/splice-lib.sh"

lf_chan()  { lf listchannels | jq -r ".channels[0].$1"; }
cln_chan() { cln listpeerchannels | jq -r "[.channels[] | select(.state == \"CHANNELD_NORMAL\")][0].$1"; }
cln_cid()  { cln_chan channel_id; }

# lf_splice LOG ARGS...: runs an lncli splice to the broadcast, in the
# background inside the container, and waits for it.
lf_splice() {
	local log=$1; shift
	docker exec -d sp-lf sh -c "lncli --network=regtest --rpcserver=127.0.0.1:10009 splice $* > /tmp/$log 2>&1"
	wait_for "splice $log broadcast" 60 sh -c "docker exec sp-lf grep -q '\"broadcast\"' /tmp/$log"
	! docker exec sp-lf grep -q '"aborted"' /tmp/$log || fail "splice $log aborted"
}

# locked CAPACITY: both sides on one funding of CAPACITY sat.
locked() {
	[ "$(lf_chan capacity)" = "$1" ] &&
		[ "$(lf_chan pending_splice)" = null ] &&
		[ "$(cln_chan total_msat)" = "${1}000" ] &&
		[ "$(cln_chan funding_txid)" = "$(lf_chan channel_point | cut -d: -f1)" ]
}

# A payment right after a lock can meet lnd's bootstrapper replacing the
# connection to the only node it knows (links restart); it is tried again
# once the channel is active.
pay_both_ways() {
	local inv i
	for i in 1 2 3; do
		wait_for "channel active" 60 sh -c "docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -e '.channels[0].active' >/dev/null"
		inv=$(cln invoice 10000000 "sp-$1-$i" x | jq -r .bolt11)
		if lf payinvoice --force "$inv" 2>&1 | grep -q SUCCEEDED; then
			break
		fi
		[ "$i" -lt 3 ] || fail "Lightning Fork could not pay ($1)"
		sleep 3
	done
	inv=$(lf addinvoice --amt 5000 | jq -r .payment_request)
	# pay prints its progress before the result.
	cln pay "$inv" 2>/dev/null | grep -q '"status": "complete"' \
		|| fail "Core Lightning could not pay ($1)"
}

reconnect() {
	lf connect "$(cln getinfo | jq -r .id)@sp-cln:9735" >/dev/null 2>&1 || true
	wait_for "channel active" 60 sh -c "docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -e '.channels[0].active' >/dev/null"
}

step "splice: fresh nodes"
for n in sp-lf sp-cln; do docker rm -f $n >/dev/null 2>&1 || true; docker volume rm -f $n-data >/dev/null 2>&1 || true; done
start_lf; start_cln; sleep 5
mine_b2b 1; wait_synced
ensure_b2b_funds 5
b2b -rpcwallet=lab sendtoaddress "$(lf newaddress p2wkh | jq -r .address)" 2 >/dev/null
b2b -rpcwallet=lab sendtoaddress "$(lf newaddress p2wkh | jq -r .address)" 1 >/dev/null
b2b -rpcwallet=lab sendtoaddress "$(cln newaddr | jq -r .bech32)" 2 >/dev/null
mine_b2b 6; wait_synced
lf connect "$(cln getinfo | jq -r .id)@sp-cln:9735" >/dev/null
sleep 2
lf openchannel --node_key "$(cln getinfo | jq -r .id)" --local_amt 1000000 --push_amt 200000 --sat_per_vbyte 2 >/dev/null
mine_b2b 6; wait_synced
wait_for "channel open" 60 sh -c "[ \"\$(docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq -r '.channels[0].state')\" = CHANNELD_NORMAL ]"
cln listpeerchannels | jq -e '.channels[0].channel_type.names | index("unified_sigs/even")' >/dev/null || fail "no unified_sigs"
pass "a unified channel of 1,000,000 sat, splice_status $(lf_chan splice_status)"

step "splice: Lightning Fork adds 300,000 sat, paying both ways while it is pending"
lf_splice s1.log in --chan_point "$(lf_chan channel_point)" --amt 300000 --sat_per_vbyte 2
# Every update now signs a commitment on each funding: start_batch.
pay_both_ways s1-pending
[ "$(lf_chan pending_splice.state)" = broadcast ] || fail "splice not pending"
mine_b2b 6; wait_synced
wait_for "locked at 1,300,000" 60 locked 1300000
pay_both_ways s1
pass "paid both ways while pending; locked on both sides, payments both ways"

step "splice: Core Lightning adds 250,000 sat"
cln_splicein "$(cln_cid)" 250000 >/dev/null
# Coins of the peer's: deeper by the value of its inputs, up to 36.
mine_b2b 36; wait_synced
wait_for "locked at 1,550,000" 60 locked 1550000
reconnect
pay_both_ways s2
[ "$(lf_chan last_splice.initiator)" = INITIATOR_REMOTE ] || fail "last splice not the peer's"
pass "locked on both sides after a splice of the peer's, payments both ways"

step "splice: Lightning Fork moves 200,000 sat out, restarting while pending"
addr=$(b2b -rpcwallet=lab getnewaddress "" bech32)
lf_splice s3.log out --chan_point "$(lf_chan channel_point)" --amt 200000 --addr "$addr" --sat_per_vbyte 2
docker restart sp-lf >/dev/null; sleep 5
wait_for "sp-lf synced" 120 lf_synced
reconnect
[ "$(lf_chan pending_splice.state)" = broadcast ] || fail "splice not pending after the restart"
mine_b2b 6; wait_synced
cap=$((1550000 - 200000 + $(lf_chan last_splice.local_delta_sat 2>/dev/null || echo 0) + 200000))
wait_for "locked after the restart" 60 sh -c "[ \"\$(docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -r '.channels[0].pending_splice')\" = null ]"
cap=$(lf_chan capacity)
wait_for "Core Lightning on the same funding" 60 locked "$cap"
[ "$(b2b -rpcwallet=lab getreceivedbyaddress "$addr")" = 0.00200000 ] || fail "the address didn't get 200,000 sat"
pay_both_ways s3
pass "moved out to the address, locked at $cap after a restart, payments both ways"

step "splice: Core Lightning moves 100,000 sat out"
docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data -J spliceout "$(cln_cid)" 100000 | jq -e .txid >/dev/null \
	|| fail "Core Lightning's splice-out failed"
mine_b2b 6; wait_synced
wait_for "locked after the peer's splice-out" 60 sh -c "[ \"\$(docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -r '.channels[0].last_splice.remote_delta_sat')\" -lt -100000 ]"
cap=$(lf_chan capacity)
wait_for "Core Lightning on the same funding" 60 locked "$cap"
reconnect
pay_both_ways s4
pass "locked at $cap, payments both ways"

step "splice: the channel announced on its current funding"
mine_b2b 1
scid=$(lf_chan scid)
wait_for "our edge on the current funding" 60 sh -c "docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 describegraph | jq -e --arg c \"\$(docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -r '.channels[0].channel_point')\" '[.edges[] | select(.chan_point == \$c and .node1_policy != null and .node2_policy != null)] | length == 1' >/dev/null"
[ "$(lf describegraph | jq '.edges | length')" = 1 ] || fail "edges of old fundings left in our graph"
wait_for "Core Lightning knows the new scid" 120 sh -c "docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data listchannels | jq -e --arg s \"$(cln_chan short_channel_id)\" '[.channels[] | select(.short_channel_id == \$s)] | length == 2' >/dev/null"
[ "$(lf_chan original_chan_id)" != "$scid" ] || fail "chan_id still the original"
pass "one edge, on scid $scid, both directions, announced to Core Lightning"

step "splice: Lightning Fork force closes by the current channel point"
before=$(lf walletbalance | jq -r .confirmed_balance)
local_bal=$(lf_chan local_balance)
lf closechannel --force --chan_point "$(lf_chan channel_point)" >/dev/null
for i in 1 2 3 4 5 6; do mine_b2b 2; sleep 3; done
wait_for "swept" 120 sh -c "[ \"\$(docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 pendingchannels | jq '.pending_force_closing_channels | length')\" = 0 ]"
after=$(lf walletbalance | jq -r .confirmed_balance)
[ $((after - before)) -gt $((local_bal - 2000)) ] || fail "recovered $((after - before)) of $local_bal"
pass "recovered $((after - before)) of $local_bal sat"

step "splice: Core Lightning force closes a spliced channel while Lightning Fork is down"
lf openchannel --node_key "$(cln getinfo | jq -r .id)" --local_amt 600000 --sat_per_vbyte 2 >/dev/null
mine_b2b 6; wait_synced
wait_for "second channel active" 60 sh -c "docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -e '.channels[0].active' >/dev/null"
lf_splice s5.log in --chan_point "$(lf_chan channel_point)" --amt 150000 --sat_per_vbyte 2
mine_b2b 6; wait_synced
wait_for "locked at 750,000" 60 locked 750000
before=$(lf walletbalance | jq -r .confirmed_balance)
local_bal=$(lf_chan local_balance)
docker stop sp-lf >/dev/null
docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data -J close "$(cln_cid)" 1 2>/dev/null | grep -q '"type": "unilateral"' \
	|| fail "Core Lightning didn't close unilaterally"
mine_b2b 1
docker start sp-lf >/dev/null; sleep 5
wait_for "sp-lf synced" 120 lf_synced
for i in 1 2 3 4 5 6; do mine_b2b 1; sleep 3; done
wait_for "swept" 120 sh -c "[ \"\$(docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 pendingchannels | jq '.pending_force_closing_channels | length')\" = 0 ]"
after=$(lf walletbalance | jq -r .confirmed_balance)
[ $((after - before)) -gt $((local_bal - 2000)) ] || fail "recovered $((after - before)) of $local_bal"
[ "$(lf closedchannels | jq -r '.channels[-1].close_type')" = REMOTE_FORCE_CLOSE ] || fail "not a remote force close"
pass "the peer's commitment on the spliced funding found, $((after - before)) of $local_bal sat recovered"

echo
echo "splice scenario: all steps passed"
