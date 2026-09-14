#!/usr/bin/env bash
# Lightning Fork against a Core Lightning node that carries the BLAKE2b chain
# identity (the privkeyio port plus the chain-identity patch): peering,
# channels opened from each side, invoices paid each way, a payment routed
# through lf1 to lf2, BOLT 12 offers each way, and closes of both kinds.
# The CLN node runs outside the compose file: CLN_CONTAINER names it.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

CLN_CONTAINER=${CLN_CONTAINER:-lightning-fork-lab-cln-1}
CLN_HOST=${CLN_HOST:-cln}
cln() { docker exec "$CLN_CONTAINER" lightning-cli --network=regtest --lightning-dir=/data "$@"; }
# Core Lightning polls bitcoind rather than listening to ZMQ, so after mining
# it lags the tip for up to its poll interval; a payment sent meanwhile is
# refused by the other side for the height difference.
cln_synced() { [ "$(cln getinfo | jq -r .blockheight)" = "$(b2b getblockcount)" ]; }
wait_cln_synced() { wait_for "cln at the tip" 90 cln_synced; }
# cln_pay INVOICE: pay, trying again for a while, since a payment right after
# a block can fail on a transient height disagreement.
cln_pay() {
	local i out
	for i in $(seq 1 8); do
		if out=$(cln pay "$1" 2>&1) && [ "$(echo "$out" | jq -r .status 2>/dev/null)" = complete ]; then
			echo "$out"; return 0
		fi
		sleep 5
	done
	echo "$out"; return 1
}
json_field() { grep -m1 "\"$1\"" | sed 's/.*"'"$1"'": *"\{0,1\}\([^",]*\)"\{0,1\}.*/\1/'; }

step "cln-interop: both nodes up and synced"
# lnd calls a backend whose tip is hours old "not synced"; a fresh block fixes that.
mine_b2b 1
wait_for "lf1 synced" 180 lnd_synced lf1
wait_cln_synced
lf1_pub=$(pubkey_of lf1)
lf2_pub=$(pubkey_of lf2)
cln_pub=$(cln getinfo | jq -r .id)
# The chain-identity series adds this option; an unpatched node lacks it.
cln listconfigs | jq -e '.configs["allow-peers-without-networks"]' >/dev/null || fail "cln is not the patched build"
pass "lf1 $lf1_pub, cln $cln_pub ($(cln getinfo | jq -r .version), chain identity applied)"

step "cln-interop: peering both ways"
# Core Lightning reports a peer connected only once init is exchanged, so
# its view is checked for both directions.
# On a rerun the two already share a channel and Core Lightning reconnects
# on its own, so an existing connection counts; each side's own dial has to
# be accepted or answered "already connected", never refused.
cln_sees_lf1() { cln listpeers | jq -e ".peers[] | select(.id == \"$lf1_pub\" and .connected)" >/dev/null; }
out=$(lf1 connect "$cln_pub@$CLN_HOST:9735" 2>&1 || true)
echo "$out" | grep -qE 'initiated|already connected' || fail "lf1 connect: $out"
wait_for "cln sees lf1" 30 cln_sees_lf1
res=$(cln connect "$lf1_pub@lf1:9735")
[ "$(echo "$res" | jq -r .id)" = "$lf1_pub" ] || fail "cln connect: $res"
pass "connected from each side (cln's connection is $(echo "$res" | jq -r .direction)bound)"

step "cln-interop: a stock lnd, which names no networks, is dropped"
sha_pub=$(pubkey_of lnd-sha)
lndsha connect "$cln_pub@$CLN_HOST:9735" >/dev/null 2>&1 || true
sleep 3
if lndsha listpeers | jq -e ".peers[] | select(.pub_key == \"$cln_pub\")" >/dev/null; then
	fail "cln kept a peer that names no networks"
fi
docker logs --since 30s "$CLN_CONTAINER" 2>&1 | grep -q "Peer names no networks" || fail "cln did not say why it dropped lnd-sha"
pass "lnd-sha dropped at init"

step "cln-interop: funding the Core Lightning wallet"
if [ "$(cln listfunds | jq '[.outputs[] | select(.status == "confirmed")] | length')" = 0 ]; then
	ensure_b2b_funds 2
	addr=$(cln newaddr | jq -r .bech32)
	b2b -rpcwallet=lab sendtoaddress "$addr" 1 >/dev/null
	mine_b2b 6
	wait_for "cln sees funds" 60 sh -c "[ \"\$(docker exec $CLN_CONTAINER lightning-cli --network=regtest --lightning-dir=/data listfunds | jq '[.outputs[] | select(.status == \"confirmed\")] | length')\" != 0 ]"
fi
if [ "$(lf1 walletbalance | jq -r .confirmed_balance)" -lt 3000000 ]; then
	fund_lf lf1 1
fi
pass "both wallets funded"

step "cln-interop: channel opened by Core Lightning toward lf1"
if ! lf1 listchannels | jq -e "[.channels[] | select(.remote_pubkey == \"$cln_pub\" and .initiator == false)] | length >= 1" >/dev/null; then
	wait_cln_synced
	cln fundchannel "$lf1_pub" 1000000 normal true >/dev/null
	mine_b2b 6
fi
wait_for "lf1 sees the channel from cln active" 120 sh -c "$COMPOSE exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -e '[.channels[] | select(.remote_pubkey == \"$cln_pub\" and .active and .initiator == false)] | length >= 1' >/dev/null"
pass "channel from cln active"

step "cln-interop: channel opened by lf1 toward Core Lightning"
if ! lf1 listchannels | jq -e "[.channels[] | select(.remote_pubkey == \"$cln_pub\" and .initiator == true)] | length >= 1" >/dev/null; then
	lf1 openchannel --node_key="$cln_pub" --local_amt=1000000 --push_amt=300000 >/dev/null
	mine_b2b 6
fi
wait_for "lf1's channel to cln active" 120 sh -c "$COMPOSE exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -e '[.channels[] | select(.remote_pubkey == \"$cln_pub\" and .active and .initiator == true)] | length >= 1' >/dev/null"
wait_for "two channels normal on cln" 120 sh -c "[ \"\$(docker exec $CLN_CONTAINER lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq '[.channels[] | select(.state == \"CHANNELD_NORMAL\")] | length')\" -ge 2 ]"
pass "channel from lf1 active"

step "cln-interop: gossip reaches both graphs"
mine_b2b 6
wait_cln_synced
wait_for "lf1's graph has the cln node" 120 sh -c "$COMPOSE exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 describegraph | jq -e '.nodes[] | select(.pub_key == \"$cln_pub\")' >/dev/null"
wait_for "cln's graph has lf2 (learned through lf1)" 180 sh -c "docker exec $CLN_CONTAINER lightning-cli --network=regtest --lightning-dir=/data listnodes | jq -e '.nodes[] | select(.nodeid == \"$lf2_pub\")' >/dev/null"
pass "cln alias on lf1: $(lf1 describegraph | jq -r ".nodes[] | select(.pub_key == \"$cln_pub\") | .alias"); lf1 alias on cln: $(cln listnodes | jq -r ".nodes[] | select(.nodeid == \"$lf1_pub\") | .alias")"

step "cln-interop: lf1 pays a Core Lightning invoice (lnblakert)"
label="lab-$(date +%s)"
b11=$(cln invoice 100000 "$label" "from lf1" | jq -r .bolt11)
[[ "$b11" == lnblakert* ]] || fail "cln invoice prefix: ${b11:0:12}"
retry_pay lf1 payinvoice --force --json "$b11" >/dev/null
[ "$(cln listinvoices "$label" | jq -r '.invoices[0].status')" = paid ] || fail "cln invoice not paid"
pass "paid 100 sat to cln"

step "cln-interop: Core Lightning pays an lf1 invoice"
b11=$(lf1 addinvoice --amt 200 --memo "from cln" | jq -r .payment_request)
[[ "$b11" == lnblakert* ]] || fail "lf1 invoice prefix: ${b11:0:12}"
res=$(cln_pay "$b11") || fail "cln pay: $res"
pass "cln paid 200 sat to lf1"

step "cln-interop: Core Lightning pays lf2 through lf1"
b11=$(lf2 addinvoice --amt 50 --memo "routed via lf1" | jq -r .payment_request)
res=$(cln_pay "$b11") || fail "cln routed pay: $res"
pass "routed payment complete, $(echo "$res" | jq -r .amount_sent_msat) msat sent"

step "cln-interop: lf1 pays a Core Lightning offer (BOLT 12)"
lno=$(cln offer any "cln offer" | jq -r .bolt12)
lf1 offer decode "$lno" | jq -e '.for_this_chain == true' >/dev/null || fail "cln offer not for this chain"
inv=$(lf1 offer fetchinvoice "$lno" --amount_msat 12000 --payer_note "lab")
lni=$(echo "$inv" | json_field bolt12)
[[ "$lni" == lni1* ]] || fail "no invoice from cln: $inv"
paid=$(lf1 offer pay --invoice "$lni")
[ "$(echo "$paid" | json_field amount_msat)" = 12000 ] || fail "offer pay: $paid"
pass "lf1 paid cln's offer, fee $(echo "$paid" | json_field fee_msat) msat"

step "cln-interop: Core Lightning pays an lf1 offer (BOLT 12)"
lno=$(lf1 offer create --description "lf1 offer" | json_field bolt12)
cln decode "$lno" | jq -e '.valid == true' >/dev/null || fail "lf1 offer invalid on cln"
lni=$(cln fetchinvoice "$lno" 13000 | jq -r .invoice)
[[ "$lni" == lni1* ]] || fail "no invoice from lf1"
res=$(cln_pay "$lni") || fail "cln pays lf1 offer: $res"
wait_for "lf1 records the offer invoice settled" 30 sh -c "$COMPOSE exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 offer invoices | jq -e '.invoices[] | select(.state == \"SETTLED\" and .amount_msat == \"13000\")' >/dev/null"
pass "cln paid lf1's offer"

step "cln-interop: cooperative close from Core Lightning, force close from lf1"
# The first channel closes cooperatively from Core Lightning's side, every
# other one is force closed from lf1's; each side has to record the kind.
coop=""; forced=""
for cp in $(lf1 listchannels | jq -r "[.channels[] | select(.remote_pubkey == \"$cln_pub\")] | .[].channel_point"); do
	if [ -z "$coop" ]; then
		cid=$(cln listpeerchannels | jq -r ".channels[] | select(.funding_txid == \"${cp%%:*}\") | .short_channel_id // .channel_id")
		res=$(cln close "$cid" 30)
		[ "$(echo "$res" | jq -r .type)" = mutual ] || fail "cln close was not mutual: $res"
		coop=$cp
	else
		lf1 closechannel --force --funding_txid="${cp%%:*}" --output_index="${cp##*:}" >/dev/null || fail "lf1 could not force close $cp"
		forced="$forced $cp"
	fi
done
[ -n "$coop" ] && [ -n "$forced" ] || fail "expected one channel of each kind, got coop='$coop' forced='$forced'"
mine_b2b 6
mine_b2b 160
wait_for "no channels left with cln on lf1" 180 sh -c "$COMPOSE exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -e '[.channels[] | select(.remote_pubkey == \"$cln_pub\")] | length == 0' >/dev/null"
wait_for "no pending channels on lf1" 240 sh -c "$COMPOSE exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 pendingchannels | jq -e '[.pending_open_channels[], .pending_force_closing_channels[], .waiting_close_channels[]] | length == 0' >/dev/null"
wait_for "cln channels settled on chain" 240 sh -c "[ \"\$(docker exec $CLN_CONTAINER lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq '[.channels[] | select(.state != \"ONCHAIN\" and .state != \"CLOSED\")] | length')\" = 0 ]"
closed=$(lf1 closedchannels)
[ "$(echo "$closed" | jq -r ".channels[] | select(.channel_point == \"$coop\") | .close_type")" = COOPERATIVE_CLOSE ] || fail "lf1 did not record the cooperative close"
for cp in $forced; do
	[ "$(echo "$closed" | jq -r ".channels[] | select(.channel_point == \"$cp\") | .close_type")" = LOCAL_FORCE_CLOSE ] || fail "lf1 did not record the force close of $cp"
done
pass "both channels closed: cln states $(cln listpeerchannels | jq -c '[.channels[].state]'), lf1 close types $(echo "$closed" | jq -c '[.channels[] | select(.remote_pubkey == "'"$cln_pub"'") | .close_type]'), cln funds $(cln listfunds | jq '[.outputs[] | select(.status == "confirmed") | .amount_msat] | add') msat"

echo; echo "CLN INTEROP PASSED"
