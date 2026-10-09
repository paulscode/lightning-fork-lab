#!/usr/bin/env bash
# A previous release's data (OLD_IMAGE), with a channel, restarted on this
# build (NEW_IMAGE): the channel is the same, pays, and closes. EXTRA_FLAGS
# picks the backend, e.g. "--db.backend=sqlite --db.use-native-sql" as
# StartOS runs it (the build needs the kvdb_sqlite tag).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
NET=${NET:-$(docker network ls --format '{{.Name}}' | grep -m1 '^lightning-fork-lab')}
run() { # image
	docker rm -f lfm-up >/dev/null 2>&1 || true
	docker run -d --name lfm-up --network "$NET" -v lfm-up-data:/root/.lnd "$1" \
		--noseedbackup --bitcoin.regtest --bitcoin.node=bitcoind \
		--bitcoin.blake2b-activation-height="${ACTIVATION_HEIGHT:-20}" ${EXTRA_FLAGS:-} \
		--fee.url=http://fees:8080/fees.json \
		--bitcoind.rpchost=knots-b2b:18443 --bitcoind.rpcuser=lab --bitcoind.rpcpass=lab \
		--bitcoind.zmqpubrawblock=tcp://knots-b2b:28332 --bitcoind.zmqpubrawtx=tcp://knots-b2b:28333 \
		--rpclisten=0.0.0.0:10009 --listen=0.0.0.0:9735 \
		--externalip=lfm-up:9735 --tlsextradomain=lfm-up --alias=lfm-up >/dev/null
	wait_for "up" 90 sh -c "docker exec lfm-up lncli --network=regtest getinfo"
}
U() { docker exec lfm-up lncli --network=regtest "$@"; }
docker rm -f lfm-up >/dev/null 2>&1 || true
docker volume rm lfm-up-data >/dev/null 2>&1 || true
run "${OLD_IMAGE:-paulscode/lightning-fork:0.21.3-beta-blake2b.17}"
mine_b2b 1
wait_for "synced" 120 sh -c "[ \"\$(docker exec lfm-up lncli --network=regtest getinfo | jq -r .synced_to_chain)\" = true ]"
lf1_id=$(pubkey_of lf1)
ensure_b2b_funds 2
b2b -rpcwallet=lab sendtoaddress "$(U newaddress p2tr | jq -r .address)" 2 >/dev/null
mine_b2b 6
wait_for "funded" 90 sh -c "[ \"\$(docker exec lfm-up lncli --network=regtest walletbalance | jq -r .confirmed_balance)\" != 0 ]"
U connect "$lf1_id@lf1:9735" >/dev/null 2>&1 || true
U openchannel --node_key="$lf1_id" --local_amt=900000 >/dev/null
mine_b2b 6
wait_for "active on .17" 120 sh -c "[ \"\$(docker exec lfm-up lncli --network=regtest listchannels | jq '[.channels[] | select(.active)] | length')\" -ge 1 ]"
before=$(U listchannels | jq -c '.channels[0] | {chan_id, capacity, unified_sigs}')
pass ".17 has $before"

step "restart the same data on this build"
docker stop lfm-up >/dev/null
run "${NEW_IMAGE:-lightning-fork:dev}"
U getinfo | jq -r .version
mine_b2b 1
wait_for "synced after upgrade" 120 sh -c "[ \"\$(docker exec lfm-up lncli --network=regtest getinfo | jq -r .synced_to_chain)\" = true ]"
U connect "$lf1_id@lf1:9735" >/dev/null 2>&1 || true
wait_for "active after upgrade" 120 sh -c "[ \"\$(docker exec lfm-up lncli --network=regtest listchannels | jq '[.channels[] | select(.active)] | length')\" -ge 1 ]"
after=$(U listchannels | jq -c '.channels[0] | {chan_id, capacity, unified_sigs}')
[ "$before" = "$after" ] || fail "channel changed: $before -> $after"
pass "same channel after upgrade: $after"
inv=$(lf1 addinvoice --amt 30000 | jq -r .payment_request)
U payinvoice --force --json "$inv" | jq -e '.status == "SUCCEEDED"' >/dev/null || fail "could not pay after upgrade"
pass "paid over it after upgrade"
cp=$(U listchannels | jq -r '.channels[0].channel_point')
U closechannel --funding_txid="${cp%:*}" --output_index="${cp#*:}" --block=false >/dev/null
mine_b2b 6
wait_for "closed" 120 sh -c "[ \"\$(docker exec lfm-up lncli --network=regtest listchannels | jq '.channels | length')\" = 0 ]"
pass "closed cooperatively after upgrade"
docker rm -f lfm-up >/dev/null; docker volume rm lfm-up-data >/dev/null
echo "UPGRADE PASS"
