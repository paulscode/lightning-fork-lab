#!/usr/bin/env bash
# What hash type do Lightning Fork and Core Lightning actually agree on for a
# second-level HTLC transaction?
#
# scenario-unified-sigs.sh already answers this for the funding output: it
# closes a channel both ways and reads 0x21 off the witness, which is
# SIGHASH_ALL with the unified opt-in, agreed by two implementations rather
# than asserted by one.
#
# The second-level HTLC transaction is the case it does not reach, because it
# closes with nothing in flight. On a channel with anchors that signature is
# SIGHASH_SINGLE|SIGHASH_ANYONECANPAY, so the opt-in should make it 0xa3, and
# that value is currently agreed only by one implementation reading another's
# source. This forces a close with an HTLC held open, waits for the timeout
# transaction, and reads the byte off the chain.
#
# It is the difference between "my code and my reading of your code agree" and
# "your node signed it and mine accepted it".
#
# STATUS: this reaches 0x21 and not yet 0xa3, and the reason is the topology.
# The HTLC here is one Lightning Fork *receives*, so there is no pre-signed
# second-level transaction on this side to broadcast: Core Lightning sweeps the
# timed-out output directly, with a single signature, and that carries 0x21.
# The 0xa3 case needs an HTLC that Lightning Fork *offers* and then times out,
# which needs somewhere for it to go: lf1 -> cln -> lf2, with lf2 holding it.
# Adding the second channel and routing through is what remains.
#
# What it does confirm, on chain and against an unmodified build: both
# signatures on the commitment carry 0x21, and a unilateral sweep of an HTLC
# output does too.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/lib.sh

N=$(docker network ls --format '{{.Name}}' | grep -m1 lightning-fork-lab)
NODE=cln-htlc-peer
IMG=cln-unified-run:asis

cli() { docker exec $NODE lightning-cli --network=regtest --lightning-dir=/data "$@"; }

docker rm -f $NODE >/dev/null 2>&1 || true
docker volume rm -f $NODE-data >/dev/null 2>&1 || true

step "htlc: start the unmodified privkeyio build"
docker run -d --name $NODE --network "$N" -v "$NODE-data:/data" "$IMG" \
	--network=regtest --lightning-dir=/data \
	--bitcoin-rpcconnect=knots-b2b --bitcoin-rpcport=18443 \
	--bitcoin-rpcuser=lab --bitcoin-rpcpassword=lab \
	--bind-addr=0.0.0.0:9735 --announce-addr="$NODE:9735" --alias=$NODE \
	--log-level=debug --disable-plugin=cln-grpc --disable-plugin=clnrest \
	--disable-plugin=cln-bip353 >/dev/null
wait_for "$NODE up" 180 sh -c \
	"docker exec $NODE lightning-cli --network=regtest --lightning-dir=/data getinfo >/dev/null 2>&1"
mine_b2b 2

for i in $(seq 1 30); do
	h=$(cli getinfo | jq -r .blockheight)
	[ "$h" = "$(b2b getblockcount)" ] && break
	sleep 10
done

cln_pub=$(cli getinfo | jq -r .id)
echo "  Core Lightning : $(cli getinfo | jq -r .version)"

step "htlc: a channel from Lightning Fork, funded and active"
lf1 connect "$cln_pub@$NODE:9735" >/dev/null 2>&1 || true
lf1 openchannel --node_key "$cln_pub" --local_amt 1000000 >/dev/null 2>&1
mine_b2b 6 >/dev/null 2>&1

cp=""
for i in $(seq 1 24); do
	cp=$(lf1 listchannels | jq -r \
		".channels[] | select(.remote_pubkey == \"$cln_pub\" and .active) | .channel_point" \
		| head -1)
	[ -n "$cp" ] && break
	mine_b2b 1 >/dev/null 2>&1 || true
	sleep 10
done
[ -n "$cp" ] || { echo "FAIL: no active channel"; exit 1; }

# The type matters: without anchors the second-level signature is plain
# SIGHASH_ALL and the interesting value never appears.
ctype=$(lf1 listchannels | jq -r \
	".channels[] | select(.channel_point == \"$cp\") | .commitment_type")
echo "  channel        : $cp"
echo "  commitment     : $ctype"
record htlc commitment_type "$ctype"

step "htlc: give Core Lightning something to pay with"
# Lightning Fork opened the channel, so all of it is on this side and Core
# Lightning cannot originate a payment. The HTLC has to be held by the side
# that did not fund, because the invoice that holds it is on the funder.
# Comfortably above the channel reserve, which is one percent of the channel
# and is not spendable: a push smaller than it leaves Core Lightning holding a
# balance it cannot send, which reads as "max is 0msat" rather than as a
# reserve problem.
back=$(cli invoice 100000000msat "fund-$RANDOM" back 2>/dev/null | jq -r .bolt11)
[ -n "$back" ] && [ "$back" != null ] || { echo "FAIL: no invoice from CLN"; exit 1; }

paid=no
for i in $(seq 1 12); do
	if lf1 payinvoice --force --timeout 60s "$back" >/dev/null 2>&1; then
		paid=yes
		break
	fi
	sleep 5
done
echo "  pushed to CLN  : $paid"
record htlc pushed "$paid"
[ "$paid" = yes ] || { echo "FAIL: could not give CLN outbound"; exit 1; }

step "htlc: hold an HTLC open across the close"
# An invoice Core Lightning will never settle, so the HTLC is still live on
# the commitment when the channel is forced shut. CLN's holdinvoice plugin is
# not present here, so the HTLC is held by paying an invoice whose preimage
# the payer never learns: a hodl invoice on the Lightning Fork side paid by
# Core Lightning does the same job in the other direction.
preimage=$(openssl rand -hex 32)
pre_hash=$(printf '%s' "$preimage" | xxd -r -p | sha256sum | cut -d' ' -f1)

inv=$(lf1 addholdinvoice "$pre_hash" 50000 2>/dev/null | jq -r .payment_request)
[ -n "$inv" ] && [ "$inv" != null ] || { echo "FAIL: no hold invoice"; exit 1; }

# Pay it from Core Lightning in the background: it will not return, because
# the invoice never settles, which is the point.
( cli pay "$inv" >/tmp/htlc-pay.out 2>&1 || true ) &
pay_pid=$!

held=no
for i in $(seq 1 30); do
	st=$(lf1 lookupinvoice "$pre_hash" 2>/dev/null | jq -r .state)
	[ "$st" = ACCEPTED ] && { held=yes; break; }
	sleep 5
done
echo "  invoice state  : $(lf1 lookupinvoice "$pre_hash" 2>/dev/null | jq -r .state)"
record htlc htlc_held "$held"
[ "$held" = yes ] || { echo "FAIL: the HTLC never locked in"; kill $pay_pid 2>/dev/null; exit 1; }

step "htlc: force close with the HTLC still live"
out=$(lf1 closechannel --force --funding_txid "${cp%%:*}" --output_index "${cp##*:}" 2>&1 || true)
ftx=$(echo "$out" | grep -oE '[a-f0-9]{64}' | tail -1)
echo "  commitment tx  : $ftx"
kill $pay_pid 2>/dev/null || true

# The commitment spends the funding output, which is the 0x21 case the other
# scenario already covers. Recorded here too, as a control: if this one is not
# 21 the run says nothing about the HTLC byte.
sleep 10; mine_b2b 3 >/dev/null 2>&1; sleep 10
commit_byte=$(b2b getrawtransaction "$ftx" true 2>/dev/null \
	| jq -r '.vin[0].txinwitness[1]' | tail -c 3)
echo "  commitment byte: $commit_byte"
record htlc commit_byte "$commit_byte"

step "htlc: mine past the timeout and find the second-level transaction"
# The HTLC-timeout transaction cannot be broadcast until the HTLC's CLTV has
# passed, so this mines and then looks for any transaction spending an output
# of the commitment.
htlc_tx=""
htlc_byte=""
for i in $(seq 1 40); do
	mine_b2b 10 >/dev/null 2>&1 || true
	sleep 6

	tip=$(b2b getblockcount)
	for h in $(seq $((tip - 12)) "$tip"); do
		[ "$h" -lt 1 ] && continue
		bh=$(b2b getblockhash "$h" 2>/dev/null) || continue
		for tx in $(b2b getblock "$bh" 1 2>/dev/null | jq -r '.tx[]'); do
			[ "$tx" = "$ftx" ] && continue
			raw=$(b2b getrawtransaction "$tx" true 2>/dev/null) || continue
			parent=$(printf '%s' "$raw" | jq -r '.vin[0].txid // empty')
			[ "$parent" = "$ftx" ] || continue

			# A second-level HTLC transaction is spent by both
			# parties, so its witness carries two signatures. A
			# unilateral sweep of the same output carries one, and
			# matching that instead is what made the first version
			# of this report 0x21 from a transaction that was never
			# the one in question.
			sigs=$(printf '%s' "$raw" \
				| jq '[.vin[0].txinwitness[] | select(length > 100)] | length')
			if [ "${sigs:-0}" -ge 2 ]; then
				htlc_tx=$tx
				break 3
			fi
		done
	done
done

if [ -z "$htlc_tx" ]; then
	echo "  no transaction spending the commitment appeared"
	record htlc htlc_byte none
	echo
	echo "  INCONCLUSIVE: the second-level transaction was not broadcast."
	echo "  That is a lab result, not a finding about the hash type."
	exit 1
fi

echo "  second-level   : $htlc_tx"
b2b getrawtransaction "$htlc_tx" true 2>/dev/null | jq -r '.vin[0].txinwitness[]' \
	| while read -r w; do
		[ ${#w} -gt 100 ] && echo "    witness sig ends: ...$(printf '%s' "$w" | tail -c 2)"
	done

htlc_byte=$(b2b getrawtransaction "$htlc_tx" true 2>/dev/null \
	| jq -r '.vin[0].txinwitness[1]' | tail -c 3)
echo "  second-level byte: $htlc_byte"
record htlc htlc_byte "$htlc_byte"

step "htlc: verdict"
case "$htlc_byte" in
a3)
	echo "  0xa3 on the second-level HTLC transaction, on a channel between"
	echo "  Lightning Fork and an unmodified Core Lightning. That is"
	echo "  SIGHASH_SINGLE|SIGHASH_ANYONECANPAY with the unified opt-in, and"
	echo "  it is now agreed by two implementations rather than by one"
	echo "  reading the other's source."
	;;
21)
	echo "  0x21, not 0xa3. Either this channel has no anchors (see the"
	echo "  commitment type above) or the second-level signature does not"
	echo "  carry SIGHASH_SINGLE|SIGHASH_ANYONECANPAY here. Worth knowing"
	echo "  before it goes in a specification."
	;;
*)
	echo "  hash type byte $htlc_byte, which was not predicted. The draft"
	echo "  should not be sent until this is understood."
	;;
esac
