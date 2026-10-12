#!/usr/bin/env bash
# An HTLC in flight across a whole splice, between two Lightning Fork
# nodes: sp-lf pays a hold invoice of sp-lf2's, so the HTLC stays on both
# commitments; sp-lf then splices in and out while it is pending, through
# the negotiation, the signatures and the lock; then sp-lf2 settles it,
# and a second one is cancelled. Balances add up at every step.
#
#   LF_IMAGE=lightning-fork:splice bash scripts/scenario-splice-htlc.sh
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
splice_on() {
	local n=$1 log=$2; shift 2
	docker exec -d "$n" sh -c "lncli --network=regtest --rpcserver=127.0.0.1:10009 splice $* > /tmp/$log 2>&1"
	wait_for "splice $log broadcast" 60 sh -c "docker exec $n grep -q '\"broadcast\"' /tmp/$log"
	! docker exec "$n" grep -q '"aborted"' "/tmp/$log" || fail "splice $log aborted"
}
pending_htlcs() { c1 'pending_htlcs | length'; }
# hold PREIMAGE_HEX SATS: a hold invoice of sp-lf2's, paid by sp-lf in the
# background; waits until the HTLC is on the channel.
hold() {
	local hash inv
	hash=$(printf '%s' "$1" | xxd -r -p | sha256sum | cut -d' ' -f1)
	inv=$(l2 addholdinvoice "$hash" --amt "$2" | jq -r .payment_request)
	docker exec -d sp-lf sh -c "lncli --network=regtest --rpcserver=127.0.0.1:10009 payinvoice --force $inv > /tmp/hold-$2.log 2>&1"
	wait_for "HTLC of $2 in flight" 60 sh -c "[ \"\$(docker exec sp-lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 lookupinvoice $hash | jq -r .state)\" = ACCEPTED ]"
	echo "$hash"
}

step "htlc: two nodes"
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
pass "a channel of 1,000,000 sat"

step "htlc: an HTLC of 40,000 held, then sp-lf adds 250,000"
pre1=$(head -c 32 /dev/urandom | xxd -p -c 64)
hash1=$(hold "$pre1" 40000)
[ "$(pending_htlcs)" = 1 ] || fail "no HTLC in flight"
local_before=$(c1 local_balance)
splice_on sp-lf a.log in --chan_point "$(c1 channel_point)" --amt 250000 --sat_per_vbyte 2
[ "$(pending_htlcs)" = 1 ] || fail "the HTLC left the channel during the splice"
mine_b2b 6; both_synced
wait_for "locked at 1,250,000" 60 locked 1250000
[ "$(pending_htlcs)" = 1 ] || fail "the HTLC isn't on the spliced channel"
pass "the HTLC stayed in flight through the splice; locked at 1,250,000"

step "htlc: sp-lf2 settles it on the new funding"
l2 settleinvoice "$pre1" >/dev/null
wait_for "settled" 60 sh -c "[ \"\$(docker exec sp-lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 lookupinvoice $hash1 | jq -r .state)\" = SETTLED ]"
wait_for "HTLC gone" 60 sh -c "[ \"\$(docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -r '.channels[0].pending_htlcs | length')\" = 0 ]"
# Our side: what it had before, plus the 250,000 added, less the 40,000 paid.
# The local balance shown before already left the HTLC out.
after=$(c1 local_balance)
[ $(( after - local_before - 250000 )) -le 1000 ] && [ $(( after - local_before - 250000 )) -ge -1000 ] \
	|| fail "local balance $after, expected about $((local_before + 250000))"
pass "settled; sp-lf's balance $after"

step "htlc: another held while sp-lf moves 100,000 out, then cancelled"
pre2=$(head -c 32 /dev/urandom | xxd -p -c 64)
hash2=$(hold "$pre2" 25000)
local_before=$(c1 local_balance)
splice_on sp-lf b.log out --chan_point "$(c1 channel_point)" --amt 100000 --sat_per_vbyte 2
mine_b2b 6; both_synced
wait_for "locked" 60 sh -c "[ \"\$(docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -r '.channels[0].pending_splice')\" = null ]"
[ "$(pending_htlcs)" = 1 ] || fail "the HTLC isn't on the spliced channel"
l2 cancelinvoice "$hash2" >/dev/null
wait_for "HTLC gone" 60 sh -c "[ \"\$(docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -r '.channels[0].pending_htlcs | length')\" = 0 ]"
after=$(c1 local_balance)
# Back: the 25,000 of the cancelled HTLC; out: 100,000 and the fee.
moved=$(( local_before + 25000 - after ))
[ "$moved" -ge 100000 ] && [ "$moved" -le 102000 ] \
	|| fail "local balance $after: $moved went out, expected 100,000 and a fee"
pass "cancelled on the new funding; $moved left with the move out"

echo "htlc scenario: all steps passed"
