#!/usr/bin/env bash
# A watchtower client while a splice is pending: the peer has a commitment
# on each funding output at a height, so every revoked height is backed up
# once per commitment. sp-lf (the client, with sp-tower as its tower) and
# sp-lf2 make the same payments before, during and after a splice; the
# backups they cause double while it is pending and go back after the lock.
#
#   LF_IMAGE=lightning-fork:splice bash scripts/scenario-splice-tower.sh
set -euo pipefail
source "$(dirname "$0")/splice-lib.sh"

l2() { docker exec sp-lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 "$@"; }
tw() { docker exec sp-tower lncli --network=regtest --rpcserver=127.0.0.1:10009 "$@"; }
c1() { lf listchannels | jq -r ".channels[0].$1"; }
c2() { l2 listchannels | jq -r ".channels[0].$1"; }
synced2() { [ "$(l2 getinfo 2>/dev/null | jq -r .synced_to_chain)" = true ]; }
synced_tw() { [ "$(tw getinfo 2>/dev/null | jq -r .synced_to_chain)" = true ]; }
all_synced() {
	wait_for "sp-lf synced" 120 lf_synced
	wait_for "sp-lf2 synced" 120 synced2
	wait_for "sp-tower synced" 120 synced_tw
}
locked() {
	[ "$(c1 capacity)" = "$1" ] && [ "$(c2 capacity)" = "$1" ] &&
		[ "$(c1 pending_splice)" = null ] && [ "$(c2 pending_splice)" = null ]
}
active() {
	wait_for "channel active" 60 sh -c "docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -e '.channels[0].active' >/dev/null && docker exec sp-lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -e '.channels[0].active' >/dev/null"
}
backups() { lf wtclient stats | jq -r .num_backups; }
settled() { [ "$(lf wtclient stats | jq -r .num_pending_backups)" = 0 ]; }
# rounds N: N payments each way; prints the backups they caused.
rounds() {
	local before inv i
	active
	wait_for "backups settled" 60 settled
	before=$(backups)
	for i in $(seq 1 "$1"); do
		inv=$(l2 addinvoice --amt 5000 | jq -r .payment_request)
		lf payinvoice --force "$inv" 2>&1 | grep -q SUCCEEDED || fail "sp-lf could not pay"
		inv=$(lf addinvoice --amt 2000 | jq -r .payment_request)
		l2 payinvoice --force "$inv" 2>&1 | grep -q SUCCEEDED || fail "sp-lf2 could not pay"
	done
	sleep 3
	wait_for "backups settled" 60 settled
	echo $(( $(backups) - before ))
}

step "splice-tower: a tower, its client and a peer"
for n in sp-lf sp-lf2 sp-tower; do docker rm -f $n >/dev/null 2>&1 || true; docker volume rm -f $n-data >/dev/null 2>&1 || true; done
start_lf sp-lf --wtclient.active
start_lf sp-lf2
start_lf sp-tower --watchtower.active --watchtower.listen=0.0.0.0:9911 --watchtower.externalip=sp-tower:9911
sleep 5
mine_b2b 1; all_synced
ensure_b2b_funds 5
b2b -rpcwallet=lab sendtoaddress "$(lf newaddress p2wkh | jq -r .address)" 2 >/dev/null
mine_b2b 6; all_synced
lf wtclient add "$(tw tower info | jq -r '.uris[0]')" >/dev/null
p2=$(l2 getinfo | jq -r .identity_pubkey)
lf connect "$p2@sp-lf2:9735" >/dev/null; sleep 2
lf openchannel --node_key "$p2" --local_amt 1000000 --push_amt 300000 --sat_per_vbyte 2 >/dev/null
mine_b2b 6; all_synced; active
[ "$(lf wtclient towers | jq -r '.towers | length')" = 1 ] || fail "the tower isn't added"
pass "a channel of 1,000,000 sat; sp-lf backs up to sp-tower"

step "splice-tower: payments before the splice"
before=$(rounds 3)
[ "$before" -gt 0 ] || fail "no backups for the payments"
pass "$before backups"

step "splice-tower: the same payments while sp-lf's splice is pending"
docker exec -d sp-lf sh -c "lncli --network=regtest --rpcserver=127.0.0.1:10009 splice in --chan_point $(c1 channel_point) --amt 250000 --sat_per_vbyte 2 > /tmp/t.log 2>&1"
wait_for "splice broadcast" 60 sh -c "docker exec sp-lf grep -q '\"broadcast\"' /tmp/t.log"
pending=$(rounds 3)
[ "$pending" = $((before * 2)) ] || fail "$pending backups while pending, expected $((before * 2))"
[ "$(lf wtclient stats | jq -r .num_failed_backups)" = 0 ] || fail "failed backups"
pass "$pending backups, one per commitment"

step "splice-tower: after the lock"
mine_b2b 7; all_synced  # sp-lf2 locks a splice of sp-lf's coins at 7
wait_for "locked at 1,250,000" 120 locked 1250000
after=$(rounds 3)
# The height signed last before the lock has a commitment on both fundings,
# and is revoked by the first payment after it: one more backup.
[ "$after" -ge "$before" ] && [ "$after" -le $((before + 1)) ] ||
	fail "$after backups after the lock, expected $before or one more"
pass "$after backups, as before the splice"

echo "splice-tower scenario: all steps passed"
