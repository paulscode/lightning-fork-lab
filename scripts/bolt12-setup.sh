#!/usr/bin/env bash
# Leaves lf1 and lf2 connected with an active channel, for BOLT 12 checks.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

mine_b2b 1
wait_for "lf1 synced" 180 lnd_synced lf1
wait_for "lf2 synced" 180 lnd_synced lf2
lf1_pub=$(pubkey_of lf1)
lf2_pub=$(pubkey_of lf2)

if [ "$(lf1 listchannels | jq '[.channels[] | select(.active)] | length')" -ge 1 ]; then
	# After a restart lf2's side of the channel can lag behind lf1's, and
	# a payment from lf2 before its link is up fails for lack of balance.
	wait_for "channel active on lf2" 90 sh -c "[ \"\$($COMPOSE exec -T lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq '[.channels[] | select(.active)] | length')\" -ge 1 ]"
	pass "lf1 and lf2 already share an active channel"
	exit 0
fi

step "bolt12-setup: fund lf1, connect and open a channel to lf2"
fund_lf lf1 2
wait_for "lf1 synced after funding" 120 lnd_synced lf1
wait_for "lf2 synced after funding" 120 lnd_synced lf2
lf1 connect "$lf2_pub@lf2:9735" >/dev/null 2>&1 || true
wait_for "lf1<->lf2 connected" 30 sh -c "$COMPOSE exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listpeers | jq -e '.peers[] | select(.pub_key == \"$lf2_pub\")' >/dev/null"
lf1 openchannel --node_key="$lf2_pub" --local_amt=1000000 --push_amt=300000 >/dev/null
mine_b2b 6
wait_for "channel active on lf1" 90 sh -c "[ \"\$($COMPOSE exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq '[.channels[] | select(.active)] | length')\" = 1 ]"
wait_for "channel active on lf2" 90 sh -c "[ \"\$($COMPOSE exec -T lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq '[.channels[] | select(.active)] | length')\" = 1 ]"
pass "lf1 and lf2 share an active channel"
