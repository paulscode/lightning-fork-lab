#!/usr/bin/env bash
# The flag day for a channel that already exists.
#
# scenario-flagday.sh starts every node fresh. Monday is not like that: nodes
# with open channels stop on 68/70 and start on 512/514, and both sides have
# something to get right. Core Lightning stores the raw channel_type bitmap
# and must rewrite bit 70 to 514 as it upgrades its database (and must be
# willing to upgrade it at all -- privkeyio/lightning#19 was the release
# refusing to). Lightning Fork stores its own channel-type flag, unrelated to
# the wire number, and so claims to need no migration. If either is wrong the
# channel comes back signing without SIGHASH_UNIFIED on one side, and every
# signature it sends is rejected.
#
# So: open a unified_sigs channel between the old builds, move value, stop
# both, start the new builds on the same data, and check that the channel
# resumes, still reads as unified, pays both ways, and closes cooperatively
# with 0x21 in both signatures of the closing witness.
#
#   LND_OLD_IMAGE (default lightning-fork:old)  LND_NEW_IMAGE (lightning-fork:new)
#   CLN_OLD_IMAGE (default cln-rel4:release)    CLN_NEW_IMAGE (cln-rel5:release)
source "$(dirname "$0")/lib.sh"

LND_OLD_IMAGE="${LND_OLD_IMAGE:-lightning-fork:old}"
LND_NEW_IMAGE="${LND_NEW_IMAGE:-lightning-fork:new}"
CLN_OLD_IMAGE="${CLN_OLD_IMAGE:-cln-rel4:release}"
CLN_NEW_IMAGE="${CLN_NEW_IMAGE:-cln-rel5:release}"
NET="${NET:-lightning-fork-lab_lab}"
P="fdu"

exec 9>/tmp/scenario-flagday-upgrade.lock
flock -n 9 || fail "another scenario-flagday-upgrade run holds the lock"

cleanup() {
	docker rm -f "$P-lnd" "$P-cln" >/dev/null 2>&1 || true
	docker volume rm "$P-lnd-data" "$P-cln-data" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

lnd_run() { # image
	docker run -d --name "$P-lnd" --network "$NET" -v "$P-lnd-data:/root/.lnd" "$1" \
		--noseedbackup --bitcoin.regtest --bitcoin.node=bitcoind \
		--bitcoin.blake2b-activation-height="${ACTIVATION_HEIGHT:-20}" \
		--fee.url=http://fees:8080/fees.json \
		--bitcoind.rpchost=knots-b2b:18443 --bitcoind.rpcuser=lab --bitcoind.rpcpass=lab \
		--bitcoind.zmqpubrawblock=tcp://knots-b2b:28332 \
		--bitcoind.zmqpubrawtx=tcp://knots-b2b:28333 \
		--rpclisten=0.0.0.0:10009 --listen=0.0.0.0:9735 \
		--externalip="$P-lnd:9735" --tlsextradomain="$P-lnd" \
		--alias="$P-lnd" --debuglevel=info >/dev/null
}
cln_run() { # image
	docker run -d --name "$P-cln" --network "$NET" -v "$P-cln-data:/data" "$1" \
		--network=regtest --lightning-dir=/data \
		--bitcoin-rpcconnect=knots-b2b --bitcoin-rpcport=18443 \
		--bitcoin-rpcuser=lab --bitcoin-rpcpassword=lab \
		--bind-addr=0.0.0.0:9735 --announce-addr="$P-cln:9735" \
		--alias="$P-cln" --log-level=debug >/dev/null
}
L() { docker exec "$P-lnd" lncli --network=regtest "$@"; }
C() { docker exec "$P-cln" lightning-cli --network=regtest --lightning-dir=/data "$@"; }
b2bcli() { docker exec lightning-fork-lab-knots-b2b-1 bitcoin-cli -regtest -rpcuser=lab -rpcpassword=lab "$@"; }

lnd_ready() { wait_for "lnd synced" 180 sh -c "docker exec $P-lnd lncli --network=regtest getinfo 2>/dev/null | jq -e .synced_to_chain >/dev/null"; }
cln_ready() { wait_for "cln up" 180 sh -c "docker exec $P-cln lightning-cli --network=regtest --lightning-dir=/data getinfo >/dev/null 2>&1"; }
at_tip() {
	local tip; tip=$(b2bcli getblockcount)
	wait_for "cln at the tip ($tip)" 120 sh -c "[ \"\$(docker exec $P-cln lightning-cli --network=regtest --lightning-dir=/data getinfo | jq -r .blockheight)\" -ge $tip ]"
	wait_for "lnd at the tip ($tip)" 120 sh -c "[ \"\$(docker exec $P-lnd lncli --network=regtest getinfo | jq -r .block_height)\" -ge $tip ]"
}
chan_up() {
	wait_for "channel active on lnd" 240 sh -c "docker exec $P-lnd lncli --network=regtest listchannels | jq -e '.channels[0].active' >/dev/null"
	wait_for "cln CHANNELD_NORMAL" 240 sh -c "docker exec $P-cln lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq -e '.channels[0].state == \"CHANNELD_NORMAL\" and .channels[0].peer_connected' >/dev/null"
}
ctype() { C listpeerchannels | jq -r '.channels[0].channel_type | "\(.names | join(",")) bits=\(.bits | join(","))"'; }

# lnd pays cln a fixed amount, retrying only the transient that
# scenario-flagday.sh documents, and saying so if it happens.
lnd_pays_cln() { # sat label
	local inv attempt=1 out reason
	inv=$(C invoice "$(( $1 * 1000 ))" "$2-$(date +%s)" "$2" | jq -r .bolt11)
	while :; do
		out=$(L payinvoice --force --pay_req "$inv" --timeout 60s 2>&1 || true)
		echo "$out" | grep -q SUCCEEDED && break
		reason=$(echo "$out" | grep -oE "FAILURE_REASON_[A-Z_]+" | tail -1 || true)
		[ "$reason" = FAILURE_REASON_INSUFFICIENT_BALANCE ] && [ "$attempt" -lt 4 ] \
			|| fail "lnd could not pay cln ($2): $(echo "$out" | tail -2 | tr '\n' ' ')"
		attempt=$((attempt + 1)); sleep 5
	done
	[ "$attempt" = 1 ] || echo "  - TRANSIENT: lnd->cln refused with INSUFFICIENT_BALANCE, paid on attempt $attempt"
}
cln_pays_lnd() { # sat label
	local inv out
	inv=$(L addinvoice --amt "$1" --memo "$2" | jq -r .payment_request)
	out=$(C pay "$inv" 2>&1 || true)
	echo "$out" | sed -n '/^{/,$p' | jq -e '.status == "complete"' >/dev/null 2>&1 \
		|| fail "cln could not pay lnd ($2): $(echo "$out" | grep -E '"message"' | head -1)"
}

# ----------------------------------------------------------------- step 0 --
step "0. before the flag day: $LND_OLD_IMAGE and $CLN_OLD_IMAGE"
lnd_run "$LND_OLD_IMAGE"; cln_run "$CLN_OLD_IMAGE"
b2bcli -generate 1 >/dev/null
lnd_ready; cln_ready
CLN_ID=$(C getinfo | jq -r .id); LND_ID=$(L getinfo | jq -r .identity_pubkey)
echo "  - lnd $(L getinfo | jq -r .version), cln $(C getinfo | jq -r .version)"

addr=$(L newaddress p2wkh | jq -r .address)
b2bcli -rpcwallet=lab sendtoaddress "$addr" 0.05 >/dev/null || fail "could not fund lnd"
b2bcli -generate 1 >/dev/null
wait_for "lnd funded" 120 sh -c "[ \"\$(docker exec $P-lnd lncli --network=regtest walletbalance | jq -r .confirmed_balance)\" != 0 ]"
L connect "$CLN_ID@$P-cln:9735" >/dev/null 2>&1 || true
sleep 4
out=$(L openchannel --node_key "$CLN_ID" --local_amt 2000000 --sat_per_vbyte 1 2>&1) \
	|| fail "could not open the pre-flag-day channel: $(echo "$out" | tail -1)"
sleep 5; b2bcli -generate 6 >/dev/null
chan_up
before=$(ctype)
echo "  - channel type before: $before"
echo "$before" | grep -q "unified_sigs/even" || fail "the old builds did not negotiate unified_sigs"
echo "$before" | grep -qE "(^|[,= ])70(,|$)" || fail "the old channel type does not carry bit 70: $before"
CHAN_POINT=$(L listchannels | jq -r '.channels[0].channel_point')
at_tip
lnd_pays_cln 400000 "before"
cln_pays_lnd 50000 "before-back"
pass "a unified_sigs channel on bit 70, with value on both sides"

# ----------------------------------------------------------------- step 1 --
step "1. the flag day: stop both, start $LND_NEW_IMAGE and $CLN_NEW_IMAGE on the same data"
docker stop "$P-lnd" "$P-cln" >/dev/null
docker rm "$P-lnd" "$P-cln" >/dev/null
lnd_run "$LND_NEW_IMAGE"; cln_run "$CLN_NEW_IMAGE"
# No --database-upgrade here on purpose: an operator following the release
# notes will not pass it, and #19 exists because the release refused without.
# wait_for exits on timeout, so poll here instead: if the database upgrade is
# refused, the reason is in cln's log and should be printed, not lost.
for _ in $(seq 1 90); do C getinfo >/dev/null 2>&1 && break; sleep 2; done
if ! C getinfo >/dev/null 2>&1; then
	docker logs --tail 20 "$P-cln" 2>&1 | sed 's/^/    /'
	fail "cln did not start on the upgraded database"
fi
lnd_ready
echo "  - lnd $(L getinfo | jq -r .version), cln $(C getinfo | jq -r .version)"
docker logs "$P-cln" 2>&1 | grep -iE "Updating database|migration|db version" | tail -3 | sed 's/^/    /' || true
L connect "$CLN_ID@$P-cln:9735" >/dev/null 2>&1 || true
chan_up
after=$(ctype)
echo "  - channel type after:  $after"
echo "$after" | grep -q "unified_sigs/even" || fail "the channel lost unified_sigs across the upgrade"
echo "$after" | grep -qE "(^|[,= ])514(,|$)" || fail "the stored channel type was not moved to bit 514: $after"
echo "$after" | grep -qE "(^|[,= ])70(,|$)" && fail "bit 70 is still in the stored channel type: $after"
[ "$(L listchannels | jq -r '.channels[0].channel_point')" = "$CHAN_POINT" ] \
	|| fail "lnd's channel is not the one opened before the upgrade"
# Builds from 0.21.3-beta-blake2b.13 report it and must say true; earlier
# ones have no field.
unified=$(L listchannels | jq -r '.channels[0].unified_sigs | if . == null then "absent" else tostring end')
reports=$(L getinfo | jq -r .version | sed -n 's/.*-blake2b\.\([0-9][0-9]*\).*/\1/p')
echo "  - lnd reports unified_sigs: $unified"
if [ "${reports:-0}" -ge 13 ]; then
	[ "$unified" = true ] || fail "lnd reports the unified channel as unified_sigs=$unified"
else
	[ "$unified" = absent ] || [ "$unified" = true ] \
		|| fail "lnd reports the unified channel as unified_sigs=$unified"
fi
pass "the same channel resumed, stored type moved 70 -> 514, unified_sigs kept"

# ----------------------------------------------------------------- step 2 --
step "2. the upgraded channel signs, both ways"
b2bcli -generate 1 >/dev/null; at_tip
lnd_pays_cln 100000 "after"
cln_pays_lnd 75000 "after-back"
pass "payments both ways: every commitment signature was accepted by the other side"

# ----------------------------------------------------------------- step 3 --
step "3. close cooperatively, and read the sighash bytes on chain"
out=$(L closechannel --chan_point "$CHAN_POINT" --sat_per_vbyte 1 2>&1) \
	|| fail "cooperative close failed: $(echo "$out" | tail -2 | tr '\n' ' ')"
closing=$(echo "$out" | jq -r '.closing_txid // empty' 2>/dev/null || true)
[ -n "$closing" ] || closing=$(echo "$out" | grep -oE '[0-9a-f]{64}' | head -1)
[ -n "$closing" ] || fail "no closing txid in: $(echo "$out" | tail -3 | tr '\n' ' ')"
b2bcli -generate 1 >/dev/null
wit=$(b2bcli getrawtransaction "$closing" 1 | jq -r '.vin[0].txinwitness | map(.[-2:]) | join(" ")')
echo "  - closing tx $closing"
echo "  - witness element trailing bytes: $wit"
# Witness is <empty> <sig> <sig> <script>: the two signatures are items 2 and 3.
sighashes=$(b2bcli getrawtransaction "$closing" 1 | jq -r '.vin[0].txinwitness[1:3] | map(.[-2:]) | join(",")')
[ "$sighashes" = "21,21" ] \
	|| fail "closing signatures carry sighash bytes $sighashes, expected 21,21 (SIGHASH_ALL|UNIFIED)"
pass "both closing signatures are 0x21: unified signing survived the renumber on both sides"

echo
echo "FLAG DAY UPGRADE SCENARIO PASSED ($LND_OLD_IMAGE + $CLN_OLD_IMAGE -> $LND_NEW_IMAGE + $CLN_NEW_IMAGE)"
