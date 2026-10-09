#!/usr/bin/env bash
# Lightning Fork (this release's code) against Core Lightning's BLAKE2b port
# (a prebuilt image, CLN_IMAGE): both open to each other, pay both ways, close
# cooperatively. Needs `make up` and a funded lab wallet; uses lf1 and a
# throwaway CLN container on the lab network. Run before a release, against
# the CLN release build peers will run.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
NET=${NET:-$(docker network ls --format '{{.Name}}' | grep -m1 '^lightning-fork-lab')}
CLN_IMAGE=${CLN_IMAGE:-cln-rel5:release}

docker rm -f lfint-cln >/dev/null 2>&1 || true
docker run -d --name lfint-cln --network "$NET" "$CLN_IMAGE" \
	--network=regtest --lightning-dir=/data \
	--bitcoin-rpcconnect=knots-b2b --bitcoin-rpcport=18443 \
	--bitcoin-rpcuser=lab --bitcoin-rpcpassword=lab \
	--bind-addr=0.0.0.0:9735 --announce-addr=lfint-cln:9735 \
	--alias=lfint-cln --log-level=debug >/dev/null
C() { docker exec lfint-cln lightning-cli --network=regtest --lightning-dir=/data "$@"; }
wait_for "CLN up" 60 sh -c "docker exec lfint-cln lightning-cli --network=regtest --lightning-dir=/data getinfo"

tip() { b2b getblockcount; }
cln_synced() { [ "$(C getinfo | jq -r .blockheight)" -ge "$(tip)" ]; }
mine() { mine_b2b "$1"; wait_for "CLN at tip" 90 cln_synced; wait_for "lf1 synced" 90 lnd_synced lf1; }

step "bits: CLN advertises 512/514"
bits=$(C getinfo | jq -r '.our_features.init')
python3 - "$bits" <<'PY'
import sys
v = int(sys.argv[1], 16)
for b in (512, 514):
    assert v >> b & 1 or v >> (b + 1) & 1, f"bit {b} missing"
print("CLN init has 512/514")
PY
lf1 getinfo | jq -e '.features | has("512") or has("513")' >/dev/null && pass "lf1 advertises option_blake2b"

step "fund both"
fund_lf lf1 2
ensure_b2b_funds 2
addr=$(C newaddr | jq -r '.bech32 // .p2tr')
b2b -rpcwallet=lab sendtoaddress "$addr" 2 >/dev/null
mine 6
wait_for "CLN funds" 90 sh -c "[ \"\$(docker exec lfint-cln lightning-cli --network=regtest --lightning-dir=/data listfunds | jq '[.outputs[] | select(.status==\"confirmed\")] | length')\" -ge 1 ]"
pass "both funded"

cln_id=$(C getinfo | jq -r .id)
lf1_id=$(pubkey_of lf1)
lf1 connect "$cln_id@lfint-cln:9735" >/dev/null 2>&1 || true
wait_for "connected" 30 sh -c "docker compose exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listpeers | jq -e '.peers[] | select(.pub_key == \"$cln_id\")' >/dev/null"
pass "lf1 and CLN connected"

step "lf1 opens to CLN (Lightning Fork funds, CLN accepts)"
lf1 openchannel --node_key="$cln_id" --local_amt=1000000 --push_amt=100000 >/dev/null
mine 6
# Only the channels with CLN count: lf1 may have others in the lab.
cln_chans() { docker compose exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq --arg c "$cln_id" '[.channels[] | select(.remote_pubkey == $c)]'; }
wait_for "lf1->CLN active" 120 sh -c "[ \"\$(docker compose exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq --arg c $cln_id '[.channels[] | select(.active and .remote_pubkey == \$c)] | length')\" -ge 1 ]"
cln_chans | jq -e 'length == 1 and .[0].unified_sigs == true' >/dev/null || fail "lf1->CLN channel not unified"
pass "channel open, unified sigs"

step "CLN opens to lf1 (CLN funds, Lightning Fork accepts)"
C fundchannel "$lf1_id" 800000 >/dev/null
mine 6
wait_for "CLN->lf1 active" 120 sh -c "[ \"\$(docker compose exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq --arg c $cln_id '[.channels[] | select(.active and .remote_pubkey == \$c)] | length')\" -ge 2 ]"
cln_chans | jq -e 'map(select(.unified_sigs == true)) | length == 2' >/dev/null || fail "not both channels unified"
pass "both channels unified"

step "payments both ways"
mine 1
inv=$(C invoice 50000000 "lf-to-cln-$RANDOM" "lf1 pays CLN" | jq -r .bolt11)
lf1 payinvoice --force --json "$inv" | jq -e '.status == "SUCCEEDED"' >/dev/null || fail "lf1 could not pay CLN"
pass "lf1 paid CLN"
inv=$(lf1 addinvoice --amt 40000 | jq -r .payment_request)
# pay prints a "# ->" progress line before its JSON.
C pay "$inv" | sed '/^#/d' | jq -e '.status == "complete"' >/dev/null || fail "CLN could not pay lf1"
pass "CLN paid lf1"

step "cooperative close from each side"
chan=$(cln_chans | jq -r '[.[] | select(.initiator == true)][0].channel_point')
lf1 closechannel --funding_txid="${chan%:*}" --output_index="${chan#*:}" >/dev/null &
sleep 5; mine 1; wait
other=$(C listpeerchannels | jq -r '[.channels[] | select(.opener == "local" and .state == "CHANNELD_NORMAL")][0].short_channel_id')
C close "$other" >/dev/null
mine 6
wait_for "both closed" 120 sh -c "[ \"\$(docker compose exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq --arg c $cln_id '[.channels[] | select(.remote_pubkey == \$c)] | length')\" = 0 ]"
lf1 closedchannels | jq -e --arg c "$cln_id" '[.channels[] | select(.remote_pubkey == $c and .close_type == "COOPERATIVE_CLOSE")] | length == 2' >/dev/null || fail "not both closed cooperatively"
pass "both closed cooperatively"
echo "INTEROP PASS"
