#!/usr/bin/env bash
# The connection at which a splice's reserves take effect, between two
# Lightning Fork nodes, when one splice_locked is lost: sp-lf2 never gets
# sp-lf's, so on reconnecting sp-lf (lock complete) applies the splice's
# reserves while sp-lf2 completes the lock from sp-lf's channel_reestablish
# and keeps the opening ones for that connection. sp-lf2's balance sits
# between the two reserves: its payments under the opening reserves, before
# its first commitment_signed and after it, must go through.
#
# The lost message: sp-lf is paused while the lock block is mined, so
# sp-lf2's splice_locked waits in sp-lf's socket; sp-lf2 is paused in turn
# and sp-lf resumed, takes it, locks and completes, its own splice_locked
# left unread in sp-lf2's socket; sp-lf2 is then killed, which drops it. Both lock
# at depth 6 (splice-peer-input-confs=6).
#
# sp-lf2 runs LF2_IMAGE (default LF_IMAGE). EXPECT=pay (default): sp-lf2,
# an at-load peer without the sending floor, pays twice. EXPECT=hold: a
# sp-lf2 with the floor for a lock completed at reestablish holds its own
# payments to the splice's reserves, so it can't pay, and nothing is
# refused at sp-lf either.
#
#   LF_IMAGE=lightning-fork:reserve LF2_IMAGE=lightning-fork:base241 \
#     bash scripts/scenario-splice-reserve.sh
set -euo pipefail
source "$(dirname "$0")/splice-lib.sh"

FLAGS=(--protocol.splice-peer-input-confs=6)
LF2_IMAGE=${LF2_IMAGE:-$LF_IMAGE}
EXPECT=${EXPECT:-pay}
l2() { docker exec sp-lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 "$@"; }
c1() { lf listchannels | jq -r ".channels[0].$1"; }
c2() { l2 listchannels | jq -r ".channels[0].$1"; }
synced2() { [ "$(l2 getinfo 2>/dev/null | jq -r .synced_to_chain)" = true ]; }
both_synced() { wait_for "sp-lf synced" 120 lf_synced; wait_for "sp-lf2 synced" 120 synced2; }
active() {
	wait_for "channel active" 90 sh -c "docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -e '.channels[0].active' >/dev/null && docker exec sp-lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -e '.channels[0].active' >/dev/null"
}
# b_pays SATS LABEL: sp-lf2 pays an invoice of sp-lf's.
b_pays() {
	local inv
	inv=$(lf addinvoice --amt "$1" | jq -r .payment_request)
	l2 payinvoice --force --timeout 60s "$inv" 2>&1 | grep -q SUCCEEDED ||
		fail "sp-lf2 could not pay $1 sat ($2)"
}

step "splice-reserve: two nodes, a channel with sp-lf2 at 100,000 sat"
for n in sp-lf sp-lf2; do docker rm -f $n >/dev/null 2>&1 || true; docker volume rm -f $n-data >/dev/null 2>&1 || true; done
start_lf sp-lf "${FLAGS[@]}"; LF_IMAGE=$LF2_IMAGE start_lf sp-lf2 "${FLAGS[@]}"; sleep 5
mine_b2b 1; both_synced
ensure_b2b_funds 5
b2b -rpcwallet=lab sendtoaddress "$(lf newaddress p2wkh | jq -r .address)" 2 >/dev/null
mine_b2b 6; both_synced
p2=$(l2 getinfo | jq -r .identity_pubkey)
lf connect "$p2@sp-lf2:9735" >/dev/null; sleep 2
lf openchannel --node_key "$p2" --local_amt 1000000 --push_amt 100000 --sat_per_vbyte 2 >/dev/null
mine_b2b 6; both_synced; active
pass "channel of 1,000,000 sat, sp-lf2 holds 100,000"

step "splice-reserve: sp-lf adds 15,000,000 (new reserve 160,000)"
docker exec -d sp-lf sh -c "lncli --network=regtest --rpcserver=127.0.0.1:10009 splice in --chan_point $(c1 channel_point) --amt 15000000 --sat_per_vbyte 2 > /tmp/s.log 2>&1"
wait_for "splice broadcast" 60 sh -c "docker exec sp-lf grep -q '\"broadcast\"' /tmp/s.log"
mine_b2b 5; both_synced
pass "pending at 5 confirmations"

step "splice-reserve: the lock, sp-lf's splice_locked lost"
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
docker pause sp-lf >/dev/null
mine_b2b 1
wait_for "sp-lf2 sends splice_locked" 60 sh -c "docker logs --since $since sp-lf2 2>&1 | grep -q 'Sending SpliceLocked'"
sleep 1
docker pause sp-lf2 >/dev/null
docker unpause sp-lf >/dev/null
wait_for "sp-lf completes the lock" 60 sh -c "docker logs --since $since sp-lf 2>&1 | grep -q 'locked at'"
sleep 1
docker kill sp-lf2 >/dev/null
docker logs --since "$since" sp-lf2 2>&1 | grep -q 'locked at' && fail "sp-lf2 completed the lock before it was killed"
pass "sp-lf locked, sp-lf2 has sent its splice_locked only"

step "splice-reserve: reconnecting, sp-lf on the splice's reserves, sp-lf2 on the opening ones"
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
docker start sp-lf2 >/dev/null
both_synced
lf connect "$p2@sp-lf2:9735" >/dev/null 2>&1 || true
active
wait_for "sp-lf2 completes at the reestablish" 60 sh -c "docker logs --since $since sp-lf2 2>&1 | grep -q 'locked at'"
docker logs --since "$since" sp-lf 2>&1 | grep 'splice reserves now' | head -1
pass "both on the splice's funding"

if [ "$EXPECT" = hold ]; then
	step "splice-reserve: sp-lf2 holds its payments to the splice's reserves"
	inv=$(lf addinvoice --amt 20000 | jq -r .payment_request)
	l2 payinvoice --force --timeout 30s "$inv" 2>&1 | grep -q SUCCEEDED && fail "sp-lf2 paid under the opening reserves"
	docker logs --since "$since" sp-lf2 2>&1 | grep -q 'our balance below the reserve' || fail "sp-lf2 did not hold its payment to the floor"
else
	step "splice-reserve: sp-lf2 pays under the opening reserves, twice"
	b_pays 20000 "before its first commitment_signed"
	b_pays 20000 "after its first commitment_signed"
fi
docker logs --since "$since" sp-lf 2>&1 | grep -E 'unable to handle upstream add|Sending Error' && fail "sp-lf refused an add"
pass "no add refused, no error sent"

echo
echo "splice-reserve scenario: all steps passed"
