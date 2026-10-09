#!/usr/bin/env bash
# The previous release (OLD_IMAGE) against this build (lf1, or NEW_IMAGE for
# the in-place upgrade): open both ways, pay both ways, close cooperatively.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
OLD_IMAGE=${OLD_IMAGE:-paulscode/lightning-fork:0.21.3-beta-blake2b.17}
NET=${NET:-$(docker network ls --format '{{.Name}}' | grep -m1 '^lightning-fork-lab')}
docker rm -f lfm-old >/dev/null 2>&1 || true
docker run -d --name lfm-old --network "$NET" "$OLD_IMAGE" \
	--noseedbackup --bitcoin.regtest --bitcoin.node=bitcoind \
	--bitcoin.blake2b-activation-height="${ACTIVATION_HEIGHT:-20}" \
	--fee.url=http://fees:8080/fees.json \
	--bitcoind.rpchost=knots-b2b:18443 --bitcoind.rpcuser=lab --bitcoind.rpcpass=lab \
	--bitcoind.zmqpubrawblock=tcp://knots-b2b:28332 --bitcoind.zmqpubrawtx=tcp://knots-b2b:28333 \
	--rpclisten=0.0.0.0:10009 --listen=0.0.0.0:9735 \
	--externalip=lfm-old:9735 --tlsextradomain=lfm-old --alias=lfm-old >/dev/null
O() { docker exec lfm-old lncli --network=regtest "$@"; }
wait_for "old up" 90 sh -c "docker exec lfm-old lncli --network=regtest getinfo"
O getinfo | jq -r .version
mine_b2b 1
wait_for "old synced" 120 sh -c "[ \"\$(docker exec lfm-old lncli --network=regtest getinfo | jq -r .synced_to_chain)\" = true ]"
old_id=$(O getinfo | jq -r .identity_pubkey); lf1_id=$(pubkey_of lf1)
ensure_b2b_funds 2
b2b -rpcwallet=lab sendtoaddress "$(O newaddress p2tr | jq -r .address)" 2 >/dev/null
mine_b2b 6
wait_for "old funded" 90 sh -c "[ \"\$(docker exec lfm-old lncli --network=regtest walletbalance | jq -r .confirmed_balance)\" != 0 ]"
lf1 connect "$old_id@lfm-old:9735" >/dev/null 2>&1 || true
sleep 3
oldchans() { docker exec lfm-old lncli --network=regtest listchannels | jq --arg c "$lf1_id" '[.channels[] | select(.remote_pubkey == $c)]'; }

step "new (0.21.4) opens to old (0.21.3)"
lf1 openchannel --node_key="$old_id" --local_amt=1000000 --push_amt=100000 >/dev/null
mine_b2b 6
wait_for "new->old active" 120 sh -c "[ \"\$(docker exec lfm-old lncli --network=regtest listchannels | jq --arg c $lf1_id '[.channels[] | select(.active and .remote_pubkey == \$c)] | length')\" -ge 1 ]"
pass "open, type $(oldchans | jq -r '.[0].commitment_type'), unified $(oldchans | jq -r '.[0].unified_sigs')"

step "old (0.21.3) opens to new (0.21.4)"
O openchannel --node_key="$lf1_id" --local_amt=800000 >/dev/null
mine_b2b 6
wait_for "old->new active" 120 sh -c "[ \"\$(docker exec lfm-old lncli --network=regtest listchannels | jq --arg c $lf1_id '[.channels[] | select(.active and .remote_pubkey == \$c)] | length')\" -ge 2 ]"
oldchans | jq -e 'map(select(.unified_sigs == true)) | length == 2' >/dev/null || fail "not both unified"
pass "both channels open, both unified"

step "payments both ways"
mine_b2b 1; sleep 5
inv=$(O addinvoice --amt 50000 | jq -r .payment_request)
lf1 payinvoice --force --json "$inv" | jq -e '.status == "SUCCEEDED"' >/dev/null || fail "new could not pay old"
pass "new paid old"
inv=$(lf1 addinvoice --amt 40000 | jq -r .payment_request)
O payinvoice --force --json "$inv" | jq -e '.status == "SUCCEEDED"' >/dev/null || fail "old could not pay new"
pass "old paid new"

step "cooperative closes"
for cp in $(oldchans | jq -r '.[].channel_point'); do
	O closechannel --funding_txid="${cp%:*}" --output_index="${cp#*:}" --block=false >/dev/null
done
mine_b2b 6
wait_for "closed" 120 sh -c "[ \"\$(docker exec lfm-old lncli --network=regtest listchannels | jq --arg c $lf1_id '[.channels[] | select(.remote_pubkey == \$c)] | length')\" = 0 ]"
O closedchannels | jq -e --arg c "$lf1_id" '[.channels[] | select(.remote_pubkey == $c and .close_type == "COOPERATIVE_CLOSE")] | length == 2' >/dev/null || fail "not both cooperative"
pass "both closed cooperatively"
docker rm -f lfm-old >/dev/null
echo "MIXED PASS"
