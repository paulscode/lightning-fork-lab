#!/usr/bin/env bash
# A splice-in by Core Lightning from a taproot coin, and Lightning Fork
# holding the coins it put in: a payment from Core Lightning that would
# spend them is failed back until the splice has 36 confirmations
# (protocol.splice-peer-input-confs), then goes through.
#
#   LF_IMAGE=lightning-fork:splice CLN_IMAGE=cln-blake2b-release:v7 \
#     bash scripts/scenario-splice-hold.sh
set -euo pipefail
source "$(dirname "$0")/splice-lib.sh"

lf_chan()  { lf listchannels | jq -r ".channels[0].$1"; }
cln_chan() { cln listpeerchannels | jq -r "[.channels[] | select(.state == \"CHANNELD_NORMAL\")][0].$1"; }

locked() {
	[ "$(lf_chan capacity)" = "$1" ] && [ "$(lf_chan pending_splice)" = null ]
}

# cln_pays SATS: whether Core Lightning pays an invoice of Lightning Fork's.
cln_pays() {
	local inv
	inv=$(lf addinvoice --amt "$1" | jq -r .payment_request)
	cln pay "$inv" 2>/dev/null | grep -q '"status": "complete"'
}

step "hold: fresh nodes, Core Lightning funded with a taproot coin"
for n in sp-lf sp-cln; do docker rm -f $n >/dev/null 2>&1 || true; docker volume rm -f $n-data >/dev/null 2>&1 || true; done
start_lf; start_cln; sleep 5
mine_b2b 1; wait_synced
ensure_b2b_funds 5
b2b -rpcwallet=lab sendtoaddress "$(lf newaddress p2wkh | jq -r .address)" 2 >/dev/null
taproot=$(cln newaddr p2tr | jq -r .p2tr)
case "$taproot" in bcrt1p*) ;; *) fail "no taproot address from Core Lightning: $taproot" ;; esac
b2b -rpcwallet=lab sendtoaddress "$taproot" 1 >/dev/null
mine_b2b 6; wait_synced
wait_for "Core Lightning sees its coin" 60 sh -c "docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data listfunds | jq -e '[.outputs[] | select(.status == \"confirmed\")] | length == 1' >/dev/null"
coin=$(cln listfunds | jq -r '.outputs[0] | "\(.txid):\(.output)"')
lf connect "$(cln getinfo | jq -r .id)@sp-cln:9735" >/dev/null
sleep 2
# Core Lightning has nothing on its side before the splice.
lf openchannel --node_key "$(cln getinfo | jq -r .id)" --local_amt 1000000 --sat_per_vbyte 2 >/dev/null
mine_b2b 6; wait_synced
wait_for "channel open" 60 sh -c "[ \"\$(docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq -r '.channels[0].state')\" = CHANNELD_NORMAL ]"
pass "a channel of 1,000,000 sat, all on Lightning Fork's side; Core Lightning's one coin $coin is P2TR"

step "hold: Core Lightning adds 300,000 sat from its taproot coin"
txid=$(docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data -J splicein "$(cln_chan channel_id)" 300000 | jq -r .txid)
[ -n "$txid" ] && [ "$txid" != null ] || fail "Core Lightning's splice-in failed"
mine_b2b 1; wait_synced
b2b getrawtransaction "$txid" true | jq -e --arg c "$coin" '[.vin[] | "\(.txid):\(.vout)"] | index($c)' >/dev/null \
	|| fail "the splice doesn't spend Core Lightning's taproot coin"
# 300,000 sat of the peer's: locked at 7.
mine_b2b 6; wait_synced
wait_for "locked at 1,300,000" 60 locked 1300000
pass "locked; the splice spent the P2TR coin, its key path signature accepted"

step "hold: a payment from Core Lightning drawing on what it put in"
lf connect "$(cln getinfo | jq -r .id)@sp-cln:9735" >/dev/null 2>&1 || true
wait_for "channel active" 60 sh -c "docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -e '.channels[0].active' >/dev/null"
! cln_pays 100000 || fail "Core Lightning spent its spliced-in coins at 7 confirmations"
docker logs sp-lf 2>&1 | grep -q "draws on the peer's coins in a splice not yet deep enough" \
	|| fail "no hold in Lightning Fork's log"
pass "failed back at 7 confirmations, the hold in Lightning Fork's log"

step "hold: 36 confirmations later"
mine_b2b 29; wait_synced
ok=
for i in 1 2 3 4 5; do
	if cln_pays 100000; then ok=1; break; fi
	sleep 3
done
[ -n "$ok" ] || fail "Core Lightning still can't pay at 36 confirmations"
pass "paid once the splice is 36 deep"

echo "hold scenario: all steps passed"
