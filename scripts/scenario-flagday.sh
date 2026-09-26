#!/usr/bin/env bash
# The 28 September feature-bit flag day: option_blake2b 68 -> 512 and
# option_unified_sigs 70 -> 514, made by Lightning Fork and privkeyio's Core
# Lightning at the same hour.
#
# Four throwaway nodes on the lab's BLAKE2b regtest, one of each vintage:
#
#   LND_NEW  Lightning Fork on 512/514      LND_OLD  Lightning Fork on 68/70
#   CLN_NEW  Core Lightning on 512/514      CLN_OLD  Core Lightning on 68/70
#
# and the claims the flag day rests on:
#
#   1. each node advertises the bits its build says it does (read off the
#      wire, not off a version string, which the two lnd builds share)
#   2. same vintage peers, across vintages is refused, in both directions,
#      and the refusal names the unknown bit
#   3. the new pair opens a channel whose type carries unified_sigs, and pays
#      a BOLT 11 invoice both ways, each invoice carrying bit 512
#   4. the new lnd refuses a pre-flag-day invoice by name, instead of trying
#      it and failing for want of a route
#
# Images are parameters so the same run can be pointed at release builds on
# the day:
#
#   CLN_NEW_IMAGE=cln-mainline:flagday bash scripts/scenario-flagday.sh
#
# Needs `make up` (knots-b2b and the fee service). Leaves nothing behind.
source "$(dirname "$0")/lib.sh"

LND_NEW_IMAGE="${LND_NEW_IMAGE:-lightning-fork:new}"
LND_OLD_IMAGE="${LND_OLD_IMAGE:-lightning-fork:old}"
CLN_NEW_IMAGE="${CLN_NEW_IMAGE:-cln-new:flagday}"
CLN_OLD_IMAGE="${CLN_OLD_IMAGE:-cln-old:flagday}"
NET="${NET:-lightning-fork-lab_lab}"
P="fd"   # container name prefix

# Two runs share the container names, so one run's cleanup would tear down the
# other's nodes mid-scenario -- which is how a mainline run once died with
# "No such container: fd-lnd-new". Refuse to overlap instead.
exec 9>/tmp/scenario-flagday.lock
flock -n 9 || fail "another scenario-flagday run holds /tmp/scenario-flagday.lock"

cleanup() {
	docker rm -f "$P-lnd-new" "$P-lnd-old" "$P-cln-new" "$P-cln-old" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

lnd_start() { # name image
	docker run -d --name "$P-lnd-$1" --network "$NET" "$2" \
		--noseedbackup --bitcoin.regtest --bitcoin.node=bitcoind \
		--bitcoin.blake2b-activation-height="${ACTIVATION_HEIGHT:-20}" \
		--fee.url=http://fees:8080/fees.json \
		--bitcoind.rpchost=knots-b2b:18443 --bitcoind.rpcuser=lab --bitcoind.rpcpass=lab \
		--bitcoind.zmqpubrawblock=tcp://knots-b2b:28332 \
		--bitcoind.zmqpubrawtx=tcp://knots-b2b:28333 \
		--rpclisten=0.0.0.0:10009 --listen=0.0.0.0:9735 \
		--externalip="$P-lnd-$1:9735" --tlsextradomain="$P-lnd-$1" \
		--alias="$P-lnd-$1" --debuglevel=info,PEER=debug >/dev/null
}
cln_start() { # name image
	docker run -d --name "$P-cln-$1" --network "$NET" "$2" \
		--network=regtest --lightning-dir=/data \
		--bitcoin-rpcconnect=knots-b2b --bitcoin-rpcport=18443 \
		--bitcoin-rpcuser=lab --bitcoin-rpcpassword=lab \
		--bind-addr=0.0.0.0:9735 --announce-addr="$P-cln-$1:9735" \
		--alias="$P-cln-$1" --log-level=debug >/dev/null
}
L() { local n=$1; shift; docker exec "$P-lnd-$n" lncli --network=regtest "$@"; }
C() { local n=$1; shift; docker exec "$P-cln-$n" lightning-cli --network=regtest --lightning-dir=/data "$@"; }
b2bcli() { docker exec lightning-fork-lab-knots-b2b-1 bitcoin-cli -regtest -rpcuser=lab -rpcpassword=lab "$@"; }

# The feature bits a node advertises in init, from its own getinfo, limited
# to the two pairs the flag day moves: 68-71 before it, 512-515 after. Other
# bits in between (lnd advertises 261, for one) are nothing to do with it.
FD_BITS='68 69 70 71 512 513 514 515'
lnd_bits() { L "$1" getinfo | jq -r --arg b "$FD_BITS" '($b | split(" ") | map(tonumber)) as $fd | [.features | keys[] | tonumber | select(. as $x | $fd | index($x))] | sort | join(",")'; }
cln_bits() {
	local hex; hex=$(C "$1" getinfo | jq -r '.our_features.init')
	python3 - "$hex" <<'PY'
import sys
v = bytes.fromhex(sys.argv[1]); n = len(v) * 8
bits = [i for i in range(n) if v[len(v) - 1 - i // 8] >> (i % 8) & 1]
print(",".join(str(b) for b in bits if b in (68, 69, 70, 71, 512, 513, 514, 515)))
PY
}

# What the two new nodes thought of each other when a payment failed: enough
# to tell a disconnect from a balance problem from a height problem.
pay_diag() {
	echo "  --- diagnostics ---"
	echo "  lnd channel: $(L new listchannels | jq -c '[.channels[] | {active, local_balance, remote_balance, commit_fee, fee_per_kw, local_chan_reserve_sat, chan_status_flags}]')"
	echo "  lnd peers:   $(L new listpeers | jq -c '[.peers[] | .pub_key[0:12]]')"
	echo "  cln channel: $(C new listpeerchannels | jq -c '[.channels[] | {state, peer_connected, to_us_msat, spendable_msat, receivable_msat}]')"
	echo "  heights:     tip=$(b2bcli getblockcount) lnd=$(L new getinfo | jq -r .block_height) cln=$(C new getinfo | jq -r .blockheight)"
	echo "  cln log (disconnects, warnings, errors):"
	docker logs --tail 400 "$P-cln-new" 2>&1 | grep -iE "disconnect|warning|peer_err|sent ERROR|WIRE_ERROR|WIRE_WARNING|UNUSUAL|BROKEN|update_fee|feerate" | tail -12 | sed 's/^/    /' || true
	echo "  lnd log (peer, link, htlc, fee):"
	docker logs --tail 600 "$P-lnd-new" 2>&1 | grep -iE "disconnect|link.*(stop|inactive|fail)|received error|warning from|bandwidth|insufficient|unable to (add|send)|update_fee|UpdateFee|fee update|commit.*fee" | tail -12 | sed 's/^/    /' || true
}

drop_all_peers() {
	for v in new old; do
		for p in $(L "$v" listpeers 2>/dev/null | jq -r '.peers[].pub_key'); do
			L "$v" disconnect "$p" >/dev/null 2>&1 || true
		done
		for p in $(C "$v" listpeers 2>/dev/null | jq -r '.peers[] | select(.connected) | .id'); do
			C "$v" disconnect "$p" true >/dev/null 2>&1 || true
		done
	done
	sleep 4
}

# ----------------------------------------------------------------- step 0 --
step "0. four nodes"
echo "  - lnd new $LND_NEW_IMAGE, lnd old $LND_OLD_IMAGE"
echo "  - cln new $CLN_NEW_IMAGE, cln old $CLN_OLD_IMAGE"
lnd_start new "$LND_NEW_IMAGE"; lnd_start old "$LND_OLD_IMAGE"
cln_start new "$CLN_NEW_IMAGE"; cln_start old "$CLN_OLD_IMAGE"
# lnd calls a backend whose tip is stale "not synced"; a fresh block fixes it.
b2bcli -generate 2 >/dev/null
for v in new old; do
	wait_for "lnd $v synced" 180 sh -c "docker exec $P-lnd-$v lncli --network=regtest getinfo 2>/dev/null | jq -e .synced_to_chain >/dev/null"
	wait_for "cln $v up" 180 sh -c "docker exec $P-cln-$v lightning-cli --network=regtest --lightning-dir=/data getinfo >/dev/null 2>&1"
done
LN_NEW=$(L new getinfo | jq -r .identity_pubkey); LN_OLD=$(L old getinfo | jq -r .identity_pubkey)
CL_NEW=$(C new getinfo | jq -r .id);             CL_OLD=$(C old getinfo | jq -r .id)
pass "four nodes up"

# ----------------------------------------------------------------- step 1 --
step "1. the bits on the wire"
for n in "lnd new:$(lnd_bits new):512,515" "lnd old:$(lnd_bits old):68,71" \
         "cln new:$(cln_bits new):512,515" "cln old:$(cln_bits old):68,71"; do
	IFS=: read -r who got want <<<"$n"
	[ "$got" = "$want" ] || fail "$who advertises $got, expected $want"
	echo "  - $who: $got"
done
pass "each build advertises its own pair and nothing else in that range"

# ----------------------------------------------------------------- step 2 --
step "2. peering, both directions"
matrix_fail=0
lnd_to_cln() { # lndv clnpub clnv expect
	drop_all_peers
	L "$1" connect "$2@$P-cln-$3:9735" --timeout 20s >/dev/null 2>&1 || true
	sleep 8
	local n; n=$(L "$1" listpeers | jq --arg k "$2" '[.peers[] | select(.pub_key == $k)] | length')
	local got; got=$([ "$n" = 1 ] && echo PEERED || echo REFUSED)
	# No match is the expected case when they peer, so it must not end the run.
	local why; why=$(docker logs --tail 40 "$P-lnd-$1" 2>&1 | grep -oE "unknown required features: \[[0-9]+\]" | tail -1 || true)
	# The log is shared across attempts, so a reason is only this attempt's
	# when this attempt was refused.
	[ "$got" = REFUSED ] || why=""
	printf "  - lnd %-3s -> cln %-3s : %-8s %s\n" "$1" "$3" "$got" "$why"
	[ "$got" = "$4" ] || matrix_fail=1
}
cln_to_lnd() { # clnv lndpub lndv expect
	drop_all_peers
	C "$1" connect "$2" "$P-lnd-$3" 9735 >/dev/null 2>&1 || true
	sleep 8
	local n; n=$(C "$1" listpeers | jq --arg k "$2" '[.peers[] | select(.id == $k and .connected)] | length')
	local got; got=$([ "$n" = 1 ] && echo PEERED || echo REFUSED)
	printf "  - cln %-3s -> lnd %-3s : %s\n" "$1" "$3" "$got"
	[ "$got" = "$4" ] || matrix_fail=1
}
lnd_to_cln new "$CL_NEW" new PEERED;  lnd_to_cln new "$CL_OLD" old REFUSED
lnd_to_cln old "$CL_NEW" new REFUSED; lnd_to_cln old "$CL_OLD" old PEERED
cln_to_lnd new "$LN_NEW" new PEERED;  cln_to_lnd new "$LN_OLD" old REFUSED
cln_to_lnd old "$LN_NEW" new REFUSED; cln_to_lnd old "$LN_OLD" old PEERED
[ "$matrix_fail" = 0 ] || fail "the peering matrix is not what the flag day promises"
pass "same vintage peers, across vintages is refused, both directions"

# ----------------------------------------------------------------- step 3 --
step "3. a channel and payments between the new pair"
drop_all_peers
# Funded from the lab wallet rather than by mining coinbases to lnd. Regtest
# halves the subsidy every 150 blocks, so on a lab chain a few thousand blocks
# tall three coinbases no longer cover a 1,000,000 sat channel -- a batch of
# runs found that by exhausting it. A payment also needs no 100-block maturity
# wait, and keeps each run from adding a hundred blocks to the chain.
addr=$(L new newaddress p2wkh | jq -r .address)
b2bcli -rpcwallet=lab sendtoaddress "$addr" 0.05 >/dev/null \
	|| fail "the lab wallet could not fund lnd new"
b2bcli -generate 1 >/dev/null
wait_for "lnd new funded" 120 sh -c "[ \"\$(docker exec $P-lnd-new lncli --network=regtest walletbalance | jq -r .confirmed_balance)\" != 0 ]"
L new connect "$CL_NEW@$P-cln-new:9735" >/dev/null 2>&1 || true
sleep 4
openout=$(L new openchannel --node_key "$CL_NEW" --local_amt 1000000 --sat_per_vbyte 1 2>&1) \
	|| fail "lnd new could not open a channel to cln new: $(echo "$openout" | tail -1)"
sleep 5; b2bcli -generate 6 >/dev/null
wait_for "channel active on lnd new" 180 sh -c "docker exec $P-lnd-new lncli --network=regtest listchannels | jq -e '.channels[0].active' >/dev/null"
wait_for "cln new CHANNELD_NORMAL" 180 sh -c "docker exec $P-cln-new lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq -e '.channels[0].state == \"CHANNELD_NORMAL\"' >/dev/null"
ctype=$(C new listpeerchannels | jq -r '.channels[0].channel_type.names | join(",")')
echo "  - channel type: $ctype"
echo "$ctype" | grep -q "unified_sigs/even" || fail "the channel did not negotiate option_unified_sigs"
pass "channel open with unified_sigs"

# Core Lightning polls bitcoind, so it can be behind the tip lnd already
# sees. A payee behind the tip refuses an HTLC whose expiry it computes from a
# height it has not reached, which fails the payment for a reason that has
# nothing to do with the flag day.
tip=$(b2bcli getblockcount)
wait_for "cln new at the tip ($tip)" 120 sh -c "[ \"\$(docker exec $P-cln-new lightning-cli --network=regtest --lightning-dir=/data getinfo | jq -r .blockheight)\" -ge $tip ]"
wait_for "lnd new at the tip ($tip)" 120 sh -c "[ \"\$(docker exec $P-lnd-new lncli --network=regtest getinfo | jq -r .block_height)\" -ge $tip ]"

# lnd pays cln, then cln pays back once it has something above its reserve.
inv=$(C new invoice 300000000 "fd-$(date +%s)-a" "flag day" | jq -r .bolt11)
L new decodepayreq --pay_req "$inv" | jq -e '.features["512"]' >/dev/null \
	|| fail "cln's invoice does not carry bit 512"
# lnd has been seen to refuse this first payment with INSUFFICIENT_BALANCE on a
# channel that plainly had the balance: active, 999,056 sat local, peer
# connected, every node at the tip. It happened in two runs of seven, only
# while the script mined 101 blocks in a burst just before paying, with Core
# Lightning logging "Ignoring fee limits!" at that moment; since funding moved
# to a wallet payment it has not happened in six. So it looks like lnd still
# digesting the burst rather than anything about the flag day. That reason,
# and only that reason, is retried, and the first failure is always reported
# with diagnostics, so if it comes back it is visible rather than absorbed.
attempt=1
while :; do
	payout=$(L new payinvoice --force --pay_req "$inv" --timeout 60s 2>&1 || true)
	echo "$payout" | grep -q SUCCEEDED && break
	reason=$(echo "$payout" | grep -oE "FAILURE_REASON_[A-Z_]+" | tail -1 || true)
	if [ "$attempt" = 1 ]; then
		echo "  - attempt 1 failed: ${reason:-$(echo "$payout" | tail -1)}"
		pay_diag
	fi
	[ "$reason" = FAILURE_REASON_INSUFFICIENT_BALANCE ] && [ "$attempt" -lt 4 ] \
		|| fail "lnd new could not pay cln new: $(echo "$payout" | grep -iE "fail|error|reason" | tail -2 | tr '\n' ' ')"
	attempt=$((attempt + 1)); sleep 5
done
[ "$attempt" = 1 ] || echo "  - TRANSIENT: refused with INSUFFICIENT_BALANCE, paid on attempt $attempt"
echo "  - lnd -> cln: paid an invoice carrying 512"
inv=$(L new addinvoice --amt 50000 --memo "flag day back" | jq -r .payment_request)
hasbit=$(python3 - "$(C new decode "$inv" | jq -r .features)" <<'PY2'
import sys
v = bytes.fromhex(sys.argv[1])
print(len(v) * 8 > 512 and v[len(v) - 1 - 512 // 8] >> (512 % 8) & 1 == 1)
PY2
)
[ "$hasbit" = True ] || fail "lnd's invoice does not carry bit 512"
payout=$(C new pay "$inv" 2>&1 || true)
echo "$payout" | sed -n '/^{/,$p' | jq -e '.status == "complete"' >/dev/null 2>&1 \
	|| { pay_diag; fail "cln new could not pay lnd new: $(echo "$payout" | grep -E '"message"|"code"' | tr -d '\n' | cut -c1-200)"; }
echo "  - cln -> lnd: paid an invoice carrying 512"
pass "BOLT 11 payments both ways"

# ----------------------------------------------------------------- step 4 --
step "4. a pre-flag-day invoice"
old=$(C old invoice 1000 "fd-$(date +%s)-old" "before the flag day" | jq -r .bolt11)
out=$(L new payinvoice --force --pay_req "$old" --timeout 20s 2>&1 || true)
echo "$out" | grep -q "does not set option_blake2b" \
	|| fail "lnd new did not refuse an invoice without 512 by name: $(echo "$out" | tail -1)"
pass "lnd new refuses it by name rather than failing for want of a route"

echo
echo "FLAG DAY SCENARIO PASSED (cln new = $CLN_NEW_IMAGE)"
