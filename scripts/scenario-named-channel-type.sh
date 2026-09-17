#!/usr/bin/env bash
# A channel opened by naming its commitment type must be bound to this chain,
# exactly as one opened by letting the nodes choose.
#
# It was not. `--channel_type anchors` between two Lightning Fork nodes opened a
# channel that closed with `01 01` in the witness, plain SIGHASH_ALL, while the
# default for that same commitment type closed with `21 21`. option_unified_sigs
# was added to the type only by implicit negotiation, and only in its anchors
# branch, so naming the type dropped it.
#
# Nothing reported it. listchannels says ANCHORS either way, and the only
# visible symptom was privkeyio's build refusing the type, which reads as an
# interop problem rather than as a missing bit.
#
# The negotiation itself is unit tested. This exists because that test pins what
# negotiateCommitmentType returns, and the thing that matters is whether the bit
# survives the rest of the path: through channeldb, into signing, and onto the
# chain. Only a close can answer that.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/lib.sh

# close_bytes FUNDING_TXID: cooperatively close and print the hash types on the
# closing transaction's witness.
#
# Run with mining underneath it: closechannel without --force blocks until the
# close confirms, and the close cannot confirm until something mines, so
# waiting for it without mining waits for a block that is waiting for us.
close_bytes() {
	local txid=$1 out ctx i pid
	out=$(mktemp)
	( lf1 closechannel --funding_txid "$txid" --output_index 0 \
		>"$out" 2>&1 || true ) &
	pid=$!
	ctx=""
	for i in $(seq 1 24); do
		mine_b2b 1 >/dev/null 2>&1 || true
		ctx=$(grep -oE '[a-f0-9]{64}' "$out" 2>/dev/null | tail -1)
		[ -n "$ctx" ] && [ "$ctx" != "$txid" ] && break
		sleep 6
	done
	kill $pid 2>/dev/null || true
	rm -f "$out"
	[ -n "$ctx" ] && [ "$ctx" != "$txid" ] || return 1

	echo "$ctx $(b2b getrawtransaction "$ctx" true 2>/dev/null \
		| jq -r '[.vin[0].txinwitness[] | select(startswith("30"))]
			 | map(.[-2:]) | join(" ")')"
}

# open_and_close LABEL [EXTRA ARGS...]
open_and_close() {
	local label=$1; shift
	local out txid ctype

	# Retried. A coop close that has only just finished can leave the peer
	# briefly unable to take a new reservation ("funding failed due to
	# internal error" from its side), and this scenario opens a channel
	# immediately after closing one. That is lab sequencing rather than
	# anything about the channel type, but a single attempt reports it as
	# though the type were refused.
	local attempt
	txid=""
	for attempt in $(seq 1 6); do
		out=$(lf1 openchannel --node_key "$lf2_pub" --local_amt 500000 \
			"$@" 2>&1) || true
		txid=$(echo "$out" | jq -r '.funding_txid // empty' 2>/dev/null)
		[ -n "$txid" ] && break
		sleep 15
	done
	[ -n "$txid" ] || {
		echo "  open failed after 6 attempts: $(echo "$out" | tail -1)"
		return 1
	}

	mine_b2b 6 >/dev/null 2>&1
	local i active=0
	for i in $(seq 1 20); do
		active=$(lf1 listchannels 2>/dev/null | jq --arg t "$txid" \
			'[.channels[] | select((.channel_point | startswith($t)) and .active)] | length')
		[ "${active:-0}" -ge 1 ] && break
		mine_b2b 1 >/dev/null 2>&1 || true
		sleep 8
	done
	[ "${active:-0}" -ge 1 ] || { echo "  channel never went active"; return 1; }

	ctype=$(lf1 listchannels 2>/dev/null | jq -r --arg t "$txid" \
		'.channels[] | select(.channel_point | startswith($t)) | .commitment_type')
	echo "  $label: commitment_type=$ctype"

	read -r ctx bytes < <(close_bytes "$txid") || {
		echo "  the close never confirmed"; return 1; }
	echo "  $label: closing tx $ctx, hash types [$bytes]"
	record namedtype "$label" "$bytes"

	[ "$bytes" = "21 21" ] || {
		echo "  FAIL: expected [21 21], got [$bytes]."
		echo "  01 means the channel fell back to plain SIGHASH_ALL: it"
		echo "  works, and its signatures are not bound to this chain."
		return 1
	}
	return 0
}

lf2_pub=$(pubkey_of lf2)
lf1 connect "$lf2_pub@lf2:9735" >/dev/null 2>&1 || true

step "named type: the default, which was always right"
# The control. If this one is not 21 21 the run says nothing about naming a
# type, because something more basic is wrong.
open_and_close default || fail "the default channel type is not bound to this
chain, which is a bigger problem than the one this scenario is about"
pass "a channel opened without naming a type closes with 21 21"

step "named type: --channel_type anchors, which was not"
open_and_close anchors --channel_type anchors ||
	fail "naming the commitment type produced a channel that is not bound
to this chain"
pass "naming the same commitment type now closes with 21 21 as well"

step "named type: verdict"
cat <<'EOF'
  Both channels have the same commitment type and both are bound to this chain.
  Before the fix the named one closed with 01 01 while the default closed with
  21 21, and listchannels reported ANCHORS for both.

  The negotiation is unit tested. What this adds is that the bit survives the
  rest of the path: it reaches channeldb, it reaches signing, and it reaches
  the witness. A test of negotiateCommitmentType alone cannot say that.
EOF
echo "PASS"
