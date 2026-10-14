#!/usr/bin/env bash
# A Lightning Fork node restored from a static channel backup after splices:
# taken before the latest splice, the backup names a funding output that
# splice spent, which the restored node doesn't take for a close; Core
# Lightning closes on the newest funding when the restored node reconnects
# having lost its state, and the restored node sweeps its balance there.
set -euo pipefail
source "$(dirname "$0")/splice-lib.sh"

la() { docker exec sp-lfa lncli --network=regtest "$@"; }
lb() { docker exec sp-lfb lncli --network=regtest "$@"; }
a_chan() { la listchannels | jq -r ".channels[0].$1"; }
# Core Lightning's channel with the seeded node: sp-cln may still have
# channels from an earlier scenario.
cln_ch() { cln listpeerchannels "$APUB" | jq -r "[.channels[] | select(.state == \"CHANNELD_NORMAL\")][0].$1"; }
cln_cid() { cln_ch channel_id; }
a_locked() {
	[ "$(a_chan capacity)" = "$1" ] && [ "$(a_chan pending_splice)" = null ] &&
		[ "$(cln_ch total_msat)" = "${1}000" ]
}

step "restore: a seeded node and Core Lightning"
for n in sp-lfa sp-lfb; do docker rm -f $n >/dev/null 2>&1 || true; docker volume rm -f $n-data >/dev/null 2>&1 || true; done
docker ps --format '{{.Names}}' | grep -qx sp-cln || start_cln
start_seeded sp-lfa
seed=$(docker exec sp-lfa curl -sk https://127.0.0.1:8080/v1/genseed | jq -c .cipher_seed_mnemonic)
init_wallet sp-lfa "$seed"
APUB=$(la getinfo | jq -r .identity_pubkey)
mine_b2b 1
wait_for "sp-lfa synced" 120 sh -c "[ \"\$(docker exec sp-lfa lncli --network=regtest getinfo | jq -r .synced_to_chain)\" = true ]"
ensure_b2b_funds 3
b2b -rpcwallet=lab sendtoaddress "$(la newaddress p2wkh | jq -r .address)" 2 >/dev/null
mine_b2b 6
wait_synced_a() { wait_for "sp-lfa synced" 120 sh -c "[ \"\$(docker exec sp-lfa lncli --network=regtest getinfo | jq -r .synced_to_chain)\" = true ]"; wait_for "sp-cln synced" 120 cln_synced; }
wait_synced_a
cpub=$(cln getinfo | jq -r .id)
la connect "$cpub@sp-cln:9735" >/dev/null
sleep 2
la openchannel --node_key "$cpub" --local_amt 800000 --push_amt 100000 --sat_per_vbyte 2 >/dev/null
mine_b2b 6; wait_synced_a
wait_for "channel active" 60 sh -c "docker exec sp-lfa lncli --network=regtest listchannels | jq -e '.channels[0].active' >/dev/null"
pass "a channel of 800,000 sat"

step "restore: our splice, then a backup, then the peer's splice"
docker exec -d sp-lfa sh -c "lncli --network=regtest splice in --chan_point $(a_chan channel_point) --amt 200000 --sat_per_vbyte 2 > /tmp/s.log 2>&1"
wait_for "our splice broadcast" 60 sh -c "docker exec sp-lfa grep -q '\"broadcast\"' /tmp/s.log"
mine_b2b 6; wait_synced_a
wait_for "locked at 1,000,000" 120 a_locked 1000000
la exportchanbackup --all --output_file /root/.lnd/stale.backup >/dev/null
docker cp sp-lfa:/root/.lnd/stale.backup /tmp/splice-lab/stale.backup
cln_reserve_p2wsh
cln_splicein "$(cln_cid)" 150000 >/dev/null
mine_b2b 7; wait_synced_a
wait_for "locked at 1,150,000" 120 a_locked 1150000
local_bal=$(a_chan local_balance)
pass "spliced twice; the backup knows only the first; local balance $local_bal"

step "restore: the node loses its data and is restored from the stale backup"
docker rm -f sp-lfa >/dev/null; docker volume rm -f sp-lfa-data >/dev/null
start_seeded sp-lfb
init_wallet sp-lfb "$seed" /tmp/splice-lab/stale.backup
wait_for "sp-lfb synced" 180 sh -c "[ \"\$(docker exec sp-lfb lncli --network=regtest getinfo | jq -r .synced_to_chain)\" = true ]"
before=$(lb walletbalance | jq -r .confirmed_balance)
lb connect "$cpub@sp-cln:9735" >/dev/null 2>&1 || true
wait_for "Core Lightning closes" 120 sh -c "docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data listpeerchannels $APUB | jq -e '[.channels[] | select(.state == \"AWAITING_UNILATERAL\" or .state == \"ONCHAIN\" or .state == \"FUNDING_SPEND_SEEN\")] | length > 0' >/dev/null"
pass "Core Lightning closed on learning the restored node lost its state"

step "restore: the restored node sweeps its balance on the newest funding"
for i in $(seq 1 12); do mine_b2b 1; sleep 3; done
wait_for "swept" 180 sh -c "[ \$(( \$(docker exec sp-lfb lncli --network=regtest walletbalance | jq -r .confirmed_balance) - $before )) -gt $((local_bal - 5000)) ]"
after=$(lb walletbalance | jq -r .confirmed_balance)
pass "recovered $((after - before)) of $local_bal sat"

echo
echo "splice restore scenario: all steps passed"
