#!/usr/bin/env bash
# What hash type does a second-level HTLC transaction actually carry?
#
# scenario-unified-sigs.sh answers this for the funding output: it closes a
# channel both ways and reads 0x21 off the witness, which is SIGHASH_ALL with
# the unified opt-in, agreed by two implementations rather than asserted by
# one. The second-level HTLC transaction is the case it does not reach, because
# it closes with nothing in flight. On a channel with anchors that signature is
# SIGHASH_SINGLE|SIGHASH_ANYONECANPAY, so the opt-in should make it 0xa3, and
# the BOLT 3 draft currently has that value on one implementation's word.
#
# Getting to it needs an HTLC the closing node *offers*. An earlier version of
# this scenario held an HTLC that Lightning Fork received, which has no
# pre-signed second-level transaction on this side at all: the counterparty
# swept the timed-out output directly, with one signature, carrying 0x21. That
# is a correct answer to a different question.
#
# So two parts:
#
#   A. lf1 -> lf2, lf2 holds. Lightning Fork on both sides. This says only that
#      my own implementation puts 0xa3 on chain, which the draft does not yet
#      have in any form, and it exercises the transaction finder against a case
#      that is known to exist before the harder one runs.
#
#   B. lf1 -> cln -> lf2, lf2 holds. The HTLC lf1 offers is on a channel with
#      an unmodified privkeyio build, so the remote signature in the timeout
#      transaction is one Core Lightning computed. If that transaction is valid
#      and confirms, the two implementations agree on 0xa3 by construction
#      rather than by my reading of full_channel.c.
#
# SKIP_A=1 runs part B alone.
#
# Core Lightning has no hold invoice of its own, which is why it is in the
# middle rather than at the end: it will keep the incoming HTLC live while it
# waits on lf2, and lf2 is an lnd that can hold one.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/lib.sh

N=$(docker network ls --format '{{.Name}}' | grep -m1 lightning-fork-lab)
NODE=cln-htlc-peer
# The privkeyio release, with none of my patches on it. That is what the claim
# below needs: "their node computed this signature" means nothing if their node
# is running my series.
#
# cln-vanilla:lab is blake2b-unified @ 24d027310 with nothing applied; the
# image carries the commit at /cln-commit and the build refuses a dirty tree,
# so what it is can be checked rather than remembered.
#
# Two other images were tried and are worth recording as dead ends.
# cln-unified-run:asis carries the chain-identity series, whose regtest
# chain_hash is 2594d57b...ab1a, and since Lightning Fork adopted the reversal
# it advertises the shared genesis 0f9188f1...2206 instead: the two hang up at
# init with "no common chain", the old design meeting the new one. The
# v26.06.7-blake2b.3 release peers, but negotiates a channel without
# option_unified_sigs, giving a 01 01 commitment and an 83 21 HTLC-timeout:
# BOLT 3's own hash types, valid on chain, and a different question.
IMG=${CLN_IMAGE:-cln-vanilla:lab}

cli() { docker exec $NODE lightning-cli --network=regtest --lightning-dir=/data "$@"; }

# sigs_in TXID: the last byte of every DER signature on input 0, in stack
# order. Read as a list rather than by index, because the position of the
# signatures differs between a second-level transaction and a direct sweep, and
# indexing is how the first version of this reported a byte from the wrong
# stack slot.
#
# "Long enough to be a signature" is not enough of a filter: a witness script
# is longer still, and picking it up reported the last opcode as a hash type
# (0xae, OP_CHECKMULTISIG, off the commitment's 2-of-2; 0x68, OP_ENDIF, off the
# HTLC script). A DER signature starts with 0x30 and is 71 to 74 bytes once the
# hash type byte is on it, which no witness script here matches.
DER='[.vin[0].txinwitness[] | select(startswith("30") and length >= 140 and length <= 150)]'

sigs_in() {
	b2b getrawtransaction "$1" true 2>/dev/null \
		| jq -r "$DER | map(.[-2:]) | .[]"
}

# second_level COMMITMENT_TXID: find a confirmed transaction spending an output
# of the commitment that carries two signatures. Two is what distinguishes the
# pre-signed second-level transaction from a unilateral sweep of the same
# output, which carries one.
#
# Counted with the same DER test sigs_in uses. Counting "witness items over 100
# characters" instead picks up the witness script, which makes a single
# signature look like two, and a force close produces several one-signature
# sweeps (the anchor, to_local) for every second-level transaction. This
# matched one of those and reported its 0x21 as the answer.
second_level() {
	local ftx=$1 tip h bh tx raw parent sigs
	tip=$(b2b getblockcount)
	for h in $(seq $((tip - 25)) "$tip"); do
		[ "$h" -lt 1 ] && continue
		bh=$(b2b getblockhash "$h" 2>/dev/null) || continue
		for tx in $(b2b getblock "$bh" 1 2>/dev/null | jq -r '.tx[]'); do
			[ "$tx" = "$ftx" ] && continue
			raw=$(b2b getrawtransaction "$tx" true 2>/dev/null) || continue
			parent=$(printf '%s' "$raw" | jq -r '.vin[0].txid // empty')
			[ "$parent" = "$ftx" ] || continue
			sigs=$(printf '%s' "$raw" | jq "$DER | length")
			if [ "${sigs:-0}" -ge 2 ]; then
				echo "$tx"
				return 0
			fi
		done
	done
	return 1
}

# hunt COMMITMENT_TXID: mine forward until the timeout transaction appears.
hunt() {
	local ftx=$1 i tx
	for i in $(seq 1 40); do
		mine_b2b 10 >/dev/null 2>&1 || true
		sleep 6
		if tx=$(second_level "$ftx"); then
			echo "$tx"
			return 0
		fi
	done
	return 1
}

# hold_on_lf2 AMOUNT_SAT: a hold invoice on lf2, printed as "hash bolt11".
hold_on_lf2() {
	local preimage pre_hash inv
	preimage=$(openssl rand -hex 32)
	pre_hash=$(printf '%s' "$preimage" | xxd -r -p | sha256sum | cut -d' ' -f1)
	inv=$(lf2 addholdinvoice "$pre_hash" "$1" 2>/dev/null | jq -r .payment_request)
	[ -n "$inv" ] && [ "$inv" != null ] || return 1
	echo "$pre_hash $inv"
}

# scid_of CHANNEL_POINT: the short channel id, for pinning a route.
scid_of() {
	lf1 listchannels | jq -r \
		".channels[] | select(.channel_point == \"$1\") | .scid"
}

# assert_htlc_on CLOSING_TXID: the commitment just broadcast must actually
# carry the HTLC. Without this the scenario can close a channel the payment
# never used and then hunt forever for a second-level transaction that was
# never going to exist, which is what happened when the route was left to
# pathfinding and there was more than one channel to lf2.
assert_htlc_on() {
	local n
	n=$(lf1 pendingchannels 2>/dev/null | jq -r \
		"[.pending_force_closing_channels[]
		  | select(.closing_txid == \"$1\")] | first | .pending_htlcs | length")
	echo "  HTLCs on the commitment: ${n:-0}"
	[ "${n:-0}" -ge 1 ] || fail "the commitment carries no HTLC, so there is no
second-level transaction to wait for. The payment went somewhere else."
}

# await_accepted HASH: the HTLC is locked in all the way to lf2.
await_accepted() {
	local i st
	for i in $(seq 1 36); do
		st=$(lf2 lookupinvoice "$1" 2>/dev/null | jq -r .state)
		[ "$st" = ACCEPTED ] && return 0
		sleep 5
	done
	return 1
}

# report LABEL TXID: print every signature's hash type and set $BYTES.
report() {
	local b
	echo "  $1: $2"
	BYTES=$(sigs_in "$2" | tr '\n' ' ' | sed 's/ *$//')
	for b in $BYTES; do echo "    signature hash type: 0x$b"; done
}

# expect_commit_sigs BYTES: both signatures on the commitment must carry the
# opt-in, which is the cheapest proof that the channel negotiated
# option_unified_sigs. Checked before the long mining loop, because a channel
# that did not negotiate it can never produce 0xa3 and waiting eight minutes to
# discover that wastes the run and buries the reason.
#
# Seen for real: against the v26.06.7-blake2b.3 release the commitment came out
# 01 01 and the HTLC-timeout 83 21, which is BOLT 3's own hash types with this
# node opting in only its own half. Valid, confirmed on chain, and not what
# this scenario is asking about.
expect_commit_sigs() {
	[ "$1" = "21 21" ] || fail "commitment carries [$1], expected [21 21].
The channel did not negotiate option_unified_sigs, so there is no 0xa3 to find
here. Use a Core Lightning build that has it (cln-vanilla:lab)."
}

# expect_timeout_sigs BYTES: the HTLC-timeout witness is
#
#     <> <remotehtlcsig> <localhtlcsig> <> <witness script>
#
# so the hash types arrive remote first. On a channel with anchors the two are
# *not* the same value, which is the thing this scenario turned up and the
# reason it is worth running: only the signature sent to the peer carries
# SIGHASH_SINGLE|SIGHASH_ANYONECANPAY, since that is what lets the broadcaster
# attach fees to a transaction someone else signed. The signature the
# broadcaster then makes for itself is an ordinary SIGHASH_ALL, and with the
# opt-in that is 0x21. A draft table giving one value for "the second-level
# HTLC signature" is wrong twice over: wrong about the local one, and silent
# about there being two.
expect_timeout_sigs() {
	[ "$1" = "a3 21" ] || fail "HTLC-timeout carries [$1], expected [a3 21]:
remote 0xa3 (SIGHASH_SINGLE|SIGHASH_ANYONECANPAY with the unified opt-in) then
local 0x21 (SIGHASH_ALL with it)"
}

# Needed by both parts, so it cannot live inside part A: SKIP_A=1 would leave
# it unset and part B fails on the first reference.
lf2_pub=$(pubkey_of lf2)

####################################################################### part A
#
# SKIP_A=1 runs only part B, which is where the interesting failure modes are.
# Part A is deterministic once it works and costs about eight minutes.
tx_a="(skipped)"
part_a() {
	step "htlc A: a channel from lf1 to lf2, so lf1 is the one offering"
	lf1 connect "$lf2_pub@lf2:9735" >/dev/null 2>&1 || true
	lf1 openchannel --node_key "$lf2_pub" --local_amt 2000000 >/dev/null 2>&1 || true
	mine_b2b 6 >/dev/null 2>&1

	cp_a=""
	for i in $(seq 1 24); do
		cp_a=$(lf1 listchannels | jq -r \
			".channels[] | select(.remote_pubkey == \"$lf2_pub\" and .active) | .channel_point" \
			| head -1)
		[ -n "$cp_a" ] && [ "$cp_a" != null ] && break
		mine_b2b 1 >/dev/null 2>&1 || true
		sleep 8
	done
	[ -n "$cp_a" ] && [ "$cp_a" != null ] || fail "no active lf1 to lf2 channel"

	ctype=$(lf1 listchannels | jq -r \
		".channels[] | select(.channel_point == \"$cp_a\") | .commitment_type")
	echo "  channel    : $cp_a"
	echo "  commitment : $ctype"
	record htlc a_commitment_type "$ctype"
	[ "$ctype" = ANCHORS ] ||
		fail "without anchors the second-level signature is plain SIGHASH_ALL and 0xa3 never appears"

	step "htlc A: lf2 holds an HTLC that lf1 offered"
	# Pinned to the channel about to be closed. The lab accumulates lf1 to lf2
	# channels, pathfinding is free to pick any of them, and a payment over one
	# channel followed by a force close of another leaves a commitment with no
	# HTLC on it.
	scid_a=$(scid_of "$cp_a")
	echo "  outgoing channel: $scid_a"
	read -r hash_a inv_a < <(hold_on_lf2 50000) || fail "no hold invoice on lf2"
	( lf1 payinvoice --force --timeout 600s --outgoing_chan_id "$scid_a" \
		"$inv_a" >/tmp/htlc-a.out 2>&1 || true ) &
	pay_a=$!
	await_accepted "$hash_a" || {
		# || true: the payment may already have given up, and a failing kill
		# under set -e aborts the script before fail can say why.
		kill $pay_a 2>/dev/null || true
		echo "  --- last payment attempt ---"; tail -20 /tmp/htlc-a.out 2>/dev/null
		fail "the HTLC never locked in on lf2"
	}
	echo "  lf2 invoice: ACCEPTED, so the HTLC is live on lf1's commitment"
	record htlc a_htlc_held yes

	step "htlc A: force close from lf1, with the HTLC still live"
	out=$(lf1 closechannel --force --funding_txid "${cp_a%%:*}" --output_index "${cp_a##*:}" 2>&1 || true)
	ftx_a=$(echo "$out" | grep -oE '[a-f0-9]{64}' | tail -1)
	kill $pay_a 2>/dev/null || true
	[ -n "$ftx_a" ] || fail "no commitment txid from the force close"
	sleep 10; mine_b2b 3 >/dev/null 2>&1; sleep 10
	assert_htlc_on "$ftx_a"
	report "commitment" "$ftx_a"
	record htlc a_commit_bytes "$BYTES"
expect_commit_sigs "$BYTES"

	step "htlc A: mine past the timeout and read the second-level transaction"
	tx_a=$(hunt "$ftx_a") || {
		record htlc a_htlc_byte none
		fail "INCONCLUSIVE: no second-level transaction appeared. That is a lab
	result, not a finding about the hash type."
	}
	report "second-level" "$tx_a"
	record htlc a_htlc_bytes "$BYTES"
	expect_timeout_sigs "$BYTES"
	pass "0xa3 remote and 0x21 local on an HTLC-timeout transaction, on chain.
	      Both signatures are Lightning Fork's here, so this pins my own
	      implementation and nothing more."
}
[ "${SKIP_A:-0}" = 1 ] || part_a

####################################################################### part B

step "htlc B: start the unmodified privkeyio build"
docker rm -f $NODE >/dev/null 2>&1 || true
docker volume rm -f $NODE-data >/dev/null 2>&1 || true
docker run -d --name $NODE --network "$N" -v "$NODE-data:/data" "$IMG" \
	--network=regtest --lightning-dir=/data \
	--bitcoin-rpcconnect=knots-b2b --bitcoin-rpcport=18443 \
	--bitcoin-rpcuser=lab --bitcoin-rpcpassword=lab \
	--bind-addr=0.0.0.0:9735 --announce-addr="$NODE:9735" --alias=$NODE \
	--log-level=debug --disable-plugin=cln-grpc \
	--disable-plugin=clnrest >/dev/null
wait_for "$NODE up" 180 sh -c \
	"docker exec $NODE lightning-cli --network=regtest --lightning-dir=/data getinfo >/dev/null 2>&1"
mine_b2b 2 >/dev/null 2>&1
for i in $(seq 1 30); do
	[ "$(cli getinfo | jq -r .blockheight)" = "$(b2b getblockcount)" ] && break
	sleep 10
done
cln_pub=$(cli getinfo | jq -r .id)
echo "  Core Lightning: $(cli getinfo | jq -r .version)"

step "htlc B: give Core Lightning coins, so it can fund its own channel to lf2"
# It has to be the funder of the second channel: the HTLC has to leave Core
# Lightning towards lf2, and it cannot forward what it does not have.
addr=$(cli newaddr bech32 | jq -r '.bech32 // .address')
b2b -rpcwallet=lab sendtoaddress "$addr" 0.05 >/dev/null
mine_b2b 6 >/dev/null 2>&1
for i in $(seq 1 30); do
	funds=$(cli listfunds | jq '[.outputs[] | select(.status == "confirmed")] | length')
	[ "${funds:-0}" -gt 0 ] && break
	sleep 5
done
[ "${funds:-0}" -gt 0 ] || fail "Core Lightning never saw its coins"
echo "  confirmed outputs: $funds"

step "htlc B: peer with Core Lightning, both ways"
# Retried rather than fired once with the error discarded. A single-shot
# connect against a node that is still starting leaves no peer, the open that
# follows fails for want of one, and the run then waits out its whole loop
# looking for a channel nothing ever tried to build. That failure looks like
# "no active channel" and says nothing about why.
peered=no
for i in $(seq 1 24); do
	err=$(lf1 connect "$cln_pub@$NODE:9735" 2>&1 || true)
	if lf1 listpeers 2>/dev/null | jq -e \
		".peers[] | select(.pub_key == \"$cln_pub\")" >/dev/null; then
		peered=yes
		break
	fi
	sleep 5
done
[ "$peered" = yes ] || fail "lf1 never peered with Core Lightning. Last error:
$err"
pass "lf1 and Core Lightning are peers"

step "htlc B: lf1 -> cln and cln -> lf2"
# Both opens retried for the same reason, and both errors kept.
for i in $(seq 1 12); do
	cp_b=$(lf1 listchannels 2>/dev/null | jq -r \
		".channels[] | select(.remote_pubkey == \"$cln_pub\") | .channel_point" \
		| head -1)
	[ -n "$cp_b" ] && [ "$cp_b" != null ] && break
	pending=$(lf1 pendingchannels 2>/dev/null | jq -r \
		"[.pending_open_channels[] | select(.channel.remote_node_pub == \"$cln_pub\")] | length")
	if [ "${pending:-0}" -eq 0 ]; then
		open_err=$(lf1 openchannel --node_key "$cln_pub" \
			--local_amt 2000000 2>&1 || true)
	fi
	mine_b2b 3 >/dev/null 2>&1 || true
	sleep 10
done
[ -n "${cp_b:-}" ] && [ "$cp_b" != null ] || fail "no lf1 to cln channel. Last
openchannel said: ${open_err:-nothing}"

for i in $(seq 1 12); do
	onward=$(cli listpeerchannels 2>/dev/null \
		| jq -r "[.channels[] | select(.peer_id == \"$lf2_pub\")] | length")
	[ "${onward:-0}" -ge 1 ] && break
	cli connect "$lf2_pub" lf2 9735 >/dev/null 2>&1 || true
	fund_err=$(cli fundchannel "$lf2_pub" 2000000 2>&1 || true)
	mine_b2b 3 >/dev/null 2>&1 || true
	sleep 10
done
[ "${onward:-0}" -ge 1 ] || fail "Core Lightning never opened a channel to lf2.
Last fundchannel said: ${fund_err:-nothing}"

# Now wait for both to be usable, which is a later state than existing.
ready=no
for i in $(seq 1 30); do
	active=$(lf1 listchannels 2>/dev/null | jq -r \
		"[.channels[] | select(.channel_point == \"$cp_b\" and .active)] | length")
	normal=$(cli listpeerchannels 2>/dev/null \
		| jq -r '[.channels[] | select(.state == "CHANNELD_NORMAL")] | length')
	if [ "${active:-0}" -ge 1 ] && [ "${normal:-0}" -ge 2 ]; then
		ready=yes
		break
	fi
	mine_b2b 1 >/dev/null 2>&1 || true
	sleep 10
done
[ "$ready" = yes ] || fail "channels not usable: lf1 side active=${active:-0},
Core Lightning has ${normal:-0} of 2 in CHANNELD_NORMAL"

ctype=$(lf1 listchannels | jq -r \
	".channels[] | select(.channel_point == \"$cp_b\") | .commitment_type")
echo "  lf1 to cln : $cp_b ($ctype)"
record htlc b_commitment_type "$ctype"
[ "$ctype" = ANCHORS ] || fail "the lf1 to cln channel has no anchors, so 0xa3 never appears"

step "htlc B: lf1 pays lf2 through Core Lightning, and lf2 holds"
# Pinned to the channel rather than left to pathfinding. Any other lf1 to lf2
# channel still standing would be a cheaper route, and taking it would put lf2
# on the other end of the commitment being closed: part B would then be part A
# with more steps, and would look like it passed.
scid_b=$(scid_of "$cp_b")
echo "  outgoing channel: $scid_b"

read -r hash_b inv_b < <(hold_on_lf2 50000) || fail "no hold invoice on lf2"
routed=no
for i in $(seq 1 20); do
	( lf1 payinvoice --force --timeout 600s --outgoing_chan_id "$scid_b" \
		"$inv_b" >/tmp/htlc-b.out 2>&1 || true ) &
	pay_b=$!
	if await_accepted "$hash_b"; then routed=yes; break; fi
	kill $pay_b 2>/dev/null || true
	mine_b2b 1 >/dev/null 2>&1 || true
	sleep 10
done
record htlc b_routed "$routed"
[ "$routed" = yes ] || {
	echo "  --- last payment attempt ---"; tail -20 /tmp/htlc-b.out 2>/dev/null
	fail "the HTLC never reached lf2 through Core Lightning"
}

# Belt and braces on the same point: read back which node the HTLC actually
# left towards. --include_incomplete, because this payment is deliberately
# still in flight and the default listing omits it.
hop=$(lf1 listpayments --include_incomplete 2>/dev/null | jq -r \
	"[.payments[] | select(.payment_hash == \"$hash_b\")] | last | .htlcs[0].route.hops[0].pub_key" 2>/dev/null)
echo "  first hop  : $hop"
record htlc b_first_hop "$hop"
[ "$hop" = "$cln_pub" ] ||
	fail "the payment's first hop is $hop, not Core Lightning, so the remote signature is not theirs"

step "htlc B: force close the lf1 to cln channel, with the HTLC still live"
out=$(lf1 closechannel --force --funding_txid "${cp_b%%:*}" --output_index "${cp_b##*:}" 2>&1 || true)
ftx_b=$(echo "$out" | grep -oE '[a-f0-9]{64}' | tail -1)
kill $pay_b 2>/dev/null || true
[ -n "$ftx_b" ] || fail "no commitment txid from the force close"
sleep 10; mine_b2b 3 >/dev/null 2>&1; sleep 10
assert_htlc_on "$ftx_b"
report "commitment" "$ftx_b"
record htlc b_commit_bytes "$BYTES"
expect_commit_sigs "$BYTES"

step "htlc B: mine past the timeout and read the second-level transaction"
tx_b=$(hunt "$ftx_b") || {
	record htlc b_htlc_byte none
	fail "INCONCLUSIVE: no second-level transaction appeared."
}
report "second-level" "$tx_b"
record htlc b_htlc_bytes "$BYTES"
expect_timeout_sigs "$BYTES"

step "htlc: verdict"
cat <<EOF
  The HTLC-timeout transaction spending lf1's commitment against an unmodified
  Core Lightning carries two signatures with two different hash types:

    remote 0xa3  SIGHASH_SINGLE|SIGHASH_ANYONECANPAY with the unified opt-in.
                 Core Lightning computed this one and sent it in
                 commitment_signed; this node only appended the byte.
    local  0x21  SIGHASH_ALL with the opt-in, made by this node at broadcast.

  The transaction confirmed, so their digest and mine matched on the 0xa3 half.
  That value is now agreed by two implementations rather than by one reading
  the other's source, which is what the BOLT 3 draft needed.

  It also corrects the draft. A table row reading "second-level HTLC, channel
  with option_anchors -> 0xa3" says one value for a transaction that carries
  two, and is wrong about the one the broadcaster makes.

  part A (lf1 -> lf2)        : $tx_a
  part B (lf1 -> cln -> lf2) : $tx_b
EOF
echo "PASS"
