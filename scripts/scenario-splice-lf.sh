#!/usr/bin/env bash
# Splicing between two Lightning Fork nodes (sp-lf, sp-lf2): each adds and
# moves out, payments while pending and after, the announcement, and a
# force close after the splices, swept.
set -euo pipefail
source "$(dirname "$0")/splice-lib.sh"

l2() { docker exec sp-lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 "$@"; }
c1() { lf listchannels | jq -r ".channels[0].$1"; }
c2() { l2 listchannels | jq -r ".channels[0].$1"; }
synced2() { [ "$(l2 getinfo 2>/dev/null | jq -r .synced_to_chain)" = true ]; }
both_synced() { wait_for "sp-lf synced" 120 lf_synced; wait_for "sp-lf2 synced" 120 synced2; }
locked() {
	[ "$(c1 capacity)" = "$1" ] && [ "$(c2 capacity)" = "$1" ] &&
		[ "$(c1 pending_splice)" = null ] && [ "$(c2 pending_splice)" = null ] &&
		[ "$(c1 channel_point)" = "$(c2 channel_point)" ]
}
active() {
	wait_for "channel active" 60 sh -c "docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -e '.channels[0].active' >/dev/null && docker exec sp-lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -e '.channels[0].active' >/dev/null"
}
pay_both() {
	local inv
	active
	inv=$(l2 addinvoice --amt 15000 | jq -r .payment_request)
	lf payinvoice --force "$inv" 2>&1 | grep -q SUCCEEDED || fail "sp-lf could not pay ($1)"
	inv=$(lf addinvoice --amt 6000 | jq -r .payment_request)
	l2 payinvoice --force "$inv" 2>&1 | grep -q SUCCEEDED || fail "sp-lf2 could not pay ($1)"
}
# splice_on NODE LOG ARGS...
splice_on() {
	local n=$1 log=$2; shift 2
	docker exec -d "$n" sh -c "lncli --network=regtest --rpcserver=127.0.0.1:10009 splice $* > /tmp/$log 2>&1"
	wait_for "splice $log broadcast" 60 sh -c "docker exec $n grep -q '\"broadcast\"' /tmp/$log"
}

step "splice-lf: two nodes"
for n in sp-lf sp-lf2; do docker rm -f $n >/dev/null 2>&1 || true; docker volume rm -f $n-data >/dev/null 2>&1 || true; done
start_lf sp-lf; start_lf sp-lf2; sleep 5
mine_b2b 1; both_synced
ensure_b2b_funds 5
b2b -rpcwallet=lab sendtoaddress "$(lf newaddress p2wkh | jq -r .address)" 2 >/dev/null
b2b -rpcwallet=lab sendtoaddress "$(l2 newaddress p2wkh | jq -r .address)" 2 >/dev/null
mine_b2b 6; both_synced
p2=$(l2 getinfo | jq -r .identity_pubkey)
lf connect "$p2@sp-lf2:9735" >/dev/null; sleep 2
lf openchannel --node_key "$p2" --local_amt 1000000 --push_amt 300000 --sat_per_vbyte 2 >/dev/null
mine_b2b 6; both_synced; active
pass "channel of 1,000,000 sat"

step "splice-lf: sp-lf adds 250,000, payments while pending"
splice_on sp-lf a.log in --chan_point "$(c1 channel_point)" --amt 250000 --sat_per_vbyte 2
pay_both pending1
mine_b2b 6; both_synced
wait_for "locked at 1,250,000" 60 locked 1250000
pay_both after1
pass "locked, paid while pending and after"

step "splice-lf: sp-lf2 moves 120,000 out to its wallet"
splice_on sp-lf2 b.log out --chan_point "$(c2 channel_point)" --amt 120000 --sat_per_vbyte 2
pay_both pending2
mine_b2b 6; both_synced
cap=$(c1 capacity)
wait_for "locked" 60 locked "$cap"
pay_both after2
pass "locked at $cap, paid while pending and after"

step "splice-lf: announced on the current funding, one edge each"
mine_b2b 1
for n in sp-lf sp-lf2; do
	wait_for "$n has the edge with its proof" 120 sh -c "docker exec $n lncli --network=regtest --rpcserver=127.0.0.1:10009 describegraph | jq -e --arg c \"$(c1 channel_point)\" '[.edges[] | select(.chan_point == \$c and .node1_policy != null and .node2_policy != null)] | length == 1' >/dev/null"
	[ "$(docker exec $n lncli --network=regtest --rpcserver=127.0.0.1:10009 describegraph | jq '.edges | length')" = 1 ] || fail "$n has edges of old fundings"
done
pass "one edge on $(c1 scid) on both nodes"

step "splice-lf: sp-lf2 force closes; both sweep"
b1=$(lf walletbalance | jq -r .confirmed_balance); bal1=$(c1 local_balance)
b2=$(l2 walletbalance | jq -r .confirmed_balance); bal2=$(c2 local_balance)
l2 closechannel --force --chan_point "$(c2 channel_point)" >/dev/null
for i in $(seq 1 10); do mine_b2b 2; sleep 3; done
wait_for "sp-lf swept" 120 sh -c "[ \"\$(docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 pendingchannels | jq '.pending_force_closing_channels | length')\" = 0 ]"
# The closer's own output waits out its CSV delay.
mature=$(l2 pendingchannels | jq -r '.pending_force_closing_channels[0].blocks_til_maturity // 0')
[ "$mature" -le 0 ] || { mine_b2b $((mature + 1)); sleep 10; mine_b2b 3; sleep 10; }
wait_for "sp-lf2 swept" 120 sh -c "[ \"\$(docker exec sp-lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 pendingchannels | jq '.pending_force_closing_channels | length')\" = 0 ]"
a1=$(lf walletbalance | jq -r .confirmed_balance); a2=$(l2 walletbalance | jq -r .confirmed_balance)
[ $((a1 - b1)) -gt $((bal1 - 2000)) ] || fail "sp-lf recovered $((a1 - b1)) of $bal1"
[ $((a2 - b2)) -gt $((bal2 - 5000)) ] || fail "sp-lf2 recovered $((a2 - b2)) of $bal2"
pass "sp-lf recovered $((a1 - b1)) of $bal1, sp-lf2 $((a2 - b2)) of $bal2"

echo
echo "splice-lf scenario: all steps passed"
