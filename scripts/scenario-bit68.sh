#!/usr/bin/env bash
# What actually stops Core Lightning and Lightning Fork forming one network?
#
# They follow the same chain. There are three candidate barriers and the only
# way to tell which of them bite is to remove them one at a time:
#
#   1. chain_hash   the init networks list. Taken out of the picture here by
#                   running both on the same regtest chain.
#   2. bit 68       option_blake2b. 24d027310 stopped Core Lightning
#                   *requiring* it from a peer, but common/features.c still
#                   declares it FEATURE_REPRESENT for INIT_FEATURE, so it is
#                   still *sent* as even, and BOLT 9 obliges a peer that does
#                   not know it to close the connection.
#   3. bit 70       option_unified_sigs, inside channel_type. Peering is not
#                   affected; opening a channel is.
#
# Three builds, each one line further on than the last:
#
#   asis       upstream/blake2b-unified @ 24d027310 + the chain-identity series
#   expt68     the same, plus FEATURE_REPRESENT -> FEATURE_REPRESENT_AS_OPTIONAL
#              for INIT_FEATURE only
#   negotiate  the same again, plus desired_channel_type() proposing unified
#              sigs on feature_negotiated (both sides) rather than
#              feature_offered (us alone), and channel_type_accept() no longer
#              refusing a type that lacks the bit
#
# Same base commit, same patch series otherwise, same peer, same chain. Build
# them with Dockerfile.cln-unified-run and PATCHDIR=build/cln-patches-{unified,
# expt68,negotiate}.
#
# Note on what `negotiate` demonstrates and what it does not. It shows the
# barrier is the negotiation and not anything deeper: with the bit negotiated
# rather than assumed, the two open a standard [12,22] anchors channel and pay
# over it. It does not show that dropping unified signatures is the right
# choice. Unified signatures are replay protection, and a channel without them
# relies on the funding output existing on only one chain.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

N=$(docker network ls --format '{{.Name}}' | grep -m1 lightning-fork-lab)
lf1_pub=$(pubkey_of lf1)

# A fresh node has to catch up with the chain before it can see a payment to
# itself, and on a lab chain with a few thousand blocks that is not instant.
wait_synced() {
	local node=$1 i h t
	for i in $(seq 1 30); do
		h=$(docker exec "$node" lightning-cli --network=regtest --lightning-dir=/data getinfo | jq -r .blockheight)
		t=$(b2b getblockcount)
		[ "$h" = "$t" ] && return 0
		sleep 10
	done
	return 1
}

run_variant() {
	local tag=$1 node=$2
	docker rm -f "$node" >/dev/null 2>&1 || true
	docker volume rm -f "$node-data" >/dev/null 2>&1 || true

	docker run -d --name "$node" --network "$N" -v "$node-data:/data" \
		"cln-unified-run:$tag" \
		--network=regtest --lightning-dir=/data \
		--bitcoin-rpcconnect=knots-b2b --bitcoin-rpcport=18443 \
		--bitcoin-rpcuser=lab --bitcoin-rpcpassword=lab \
		--bind-addr=0.0.0.0:9735 --announce-addr="$node:9735" --alias="$node" \
		--log-level=debug --disable-plugin=cln-grpc --disable-plugin=clnrest \
		--disable-plugin=cln-bip353 >/dev/null

	cli() { docker exec "$node" lightning-cli --network=regtest --lightning-dir=/data "$@"; }
	wait_for "$node up" 180 sh -c \
		"docker exec $node lightning-cli --network=regtest --lightning-dir=/data getinfo >/dev/null 2>&1"
	mine_b2b 2
	wait_synced "$node" || { echo "  $node never caught up with the chain"; }

	local ver pub initfeat
	ver=$(cli getinfo | jq -r .version)
	pub=$(cli getinfo | jq -r .id)
	# What it puts on the wire, rather than what the source says it does.
	initfeat=$(cli getinfo | jq -r '.our_features.init // "?"')
	echo "  build     : $ver  ($tag)"
	echo "  init feat : $initfeat"

	cli connect "$lf1_pub@lf1:9735" >/dev/null 2>&1 || true
	lf1 connect "$pub@$node:9735" >/dev/null 2>&1 || true
	sleep 6

	local peered_lf
	peered_lf=$(lf1 listpeers | jq "[.peers[] | select(.pub_key == \"$pub\")] | length")
	echo "  peered (Lightning Fork sees it) : $peered_lf"
	record "bit68-$tag" peered "$peered_lf"

	if [ "$peered_lf" = 0 ]; then
		echo "  --- why ---"
		$COMPOSE logs --since 90s lf1 2>&1 \
			| grep -oE "unknown required features: \[[0-9]+\]" | tail -1 \
			| sed 's/^/  /' || true
		RESULT=0; CHAN=0; PAID=no
		unset -f cli
		return
	fi

	# Peering is a low bar: two nodes can finish init and still be unable to
	# do anything. Opening a channel is the question that matters.
	ensure_b2b_funds 2
	local addr
	addr=$(cli newaddr | jq -r .bech32)
	b2b -rpcwallet=lab sendtoaddress "$addr" 1 >/dev/null
	mine_b2b 6
	wait_for "$node to see funds" 180 sh -c \
		"[ \"\$(docker exec $node lightning-cli --network=regtest --lightning-dir=/data listfunds | jq '[.outputs[] | select(.status==\"confirmed\")] | length')\" != 0 ]"

	# 3000perkw rather than `normal`: the lab's estimator sometimes lands a
	# few sat under this backend's min relay fee, which fails the broadcast
	# for reasons that have nothing to do with what is being tested.
	local out
	if ! out=$(cli fundchannel "$lf1_pub" 1000000 3000perkw 2>&1); then
		echo "  channel   : refused"
		echo "$out" | jq -r '.message // .' 2>/dev/null | head -2 | sed 's/^/    /'
		# lnd's wire error is generic ("funding failed due to internal
		# error"); the reason it decided that is only in its own log.
		$COMPOSE logs --since 120s lf1 2>&1 \
			| grep -oE "channel type negotiation failed: .*" | tail -1 \
			| sed 's/^/    lnd: /' || true
		record "bit68-$tag" channel refused
		RESULT=$peered_lf; CHAN=0; PAID=no
		unset -f cli
		return
	fi

	local ctype
	ctype=$(echo "$out" | jq -c '.channel_type.bits // []' 2>/dev/null)
	mine_b2b 6

	# Poll rather than sleep a fixed amount: how long the channel takes to
	# go active depends on how far behind the node was when it started, and
	# a short fixed wait reports a working channel as a broken one.
	local active=0 i
	for i in $(seq 1 24); do
		active=$(lf1 listchannels | jq "[.channels[] | select(.remote_pubkey == \"$pub\" and .active)] | length")
		[ "$active" != 0 ] && break
		sleep 10
	done
	echo "  channel   : opened, type $ctype, active from Lightning Fork: $active"
	record "bit68-$tag" channel "opened $ctype"
	record "bit68-$tag" channel_active "$active"

	# The channel was funded from this side, so all the liquidity is here and
	# only this direction can be paid. That is enough to show the channel
	# carries value.
	# A payment attempted in the first seconds after a channel goes active
	# can fail while the channel_update exchange completes, so try a few
	# times before calling it a failure. Each attempt gets its own invoice:
	# a failed pay can leave the first one in an unpayable state.
	PAID=no
	if [ "$active" != 0 ]; then
		local inv st j
		st=failed
		for j in $(seq 1 8); do
			inv=$(lf1 addinvoice --amt 5000 | jq -r .payment_request)
			# `pay` prints progress lines beginning with # to stdout
			# ahead of its JSON whenever it retries internally.
			# Feeding those to jq makes a successful payment read as
			# a failed one, which is how this first got measured.
			st=$(cli pay "$inv" 2>/dev/null | grep -v '^#' \
				| jq -r .status 2>/dev/null || echo failed)
			[ "$st" = complete ] && break
			sleep 10
		done
		echo "  payment   : CLN -> Lightning Fork, 5000 sat: $st"
		record "bit68-$tag" payment "$st"
		[ "$st" = complete ] && PAID=yes
	fi

	RESULT=$peered_lf; CHAN=$active
	unset -f cli
}

step "bit68: blake2b-unified + chain-identity series, as it stands"
run_variant asis cln-b68-asis
ASIS=$RESULT; ASIS_CHAN=$CHAN

step "bit68: the same build, with bit 68 optional in init"
run_variant expt68 cln-b68-opt
OPT=$RESULT; OPT_CHAN=$CHAN

step "bit68: the same again, with unified sigs negotiated rather than required"
run_variant negotiate cln-b68-neg
NEG=$RESULT; NEG_CHAN=$CHAN; NEG_PAID=$PAID

step "bit68: verdict"
printf "  %-10s %-8s %s\n" variant peered channel
printf "  %-10s %-8s %s\n" asis "$ASIS" "$ASIS_CHAN"
printf "  %-10s %-8s %s\n" expt68 "$OPT" "$OPT_CHAN"
printf "  %-10s %-8s %s  (payment: %s)\n" negotiate "$NEG" "$NEG_CHAN" "$NEG_PAID"
echo

if [ "$ASIS" = 0 ] && [ "$OPT" != 0 ] && [ "$OPT_CHAN" = 0 ] && [ "$NEG_CHAN" != 0 ]; then
	cat <<EOF
  Two barriers, one line each, and they are independent.

  As it stands the two cannot peer: Lightning Fork refuses the node with
  "unknown required features: [68]", because option_blake2b is still sent
  as even even though peers are no longer required to send it back.

  With bit 68 optional in init they peer, and still cannot open a channel:
  option_unified_sigs is added to the proposed channel_type on the strength
  of what this node offers rather than what the peer negotiated, so lnd is
  asked for a type it never claimed to understand and refuses, and
  channel_type_accept refuses lnd's [12,22] in the other direction.

  With that bit negotiated rather than assumed, they open a standard
  [12,22] anchors channel, and a payment over it: $NEG_PAID.

  Same base commit, same patch series, same peer, same chain throughout.
EOF
	if [ "$NEG_PAID" != yes ]; then
		cat <<EOF

  The channel opened and went active but the payment did not complete
  within the retries. That is worth chasing before the channel result is
  quoted anywhere: an open channel that cannot route is not interop.
EOF
	fi
else
	cat <<EOF
  The results do not match the expected pattern, so something else is in
  the way and this run has not isolated it. Expected: asis does not peer,
  expt68 peers but opens no channel, negotiate opens a channel.

  Check first that both nodes are on the same regtest chain, and that the
  three images were all built from the same CLN_REF.
EOF
fi

echo
echo "  (leaving the nodes running; docker rm -f cln-b68-asis cln-b68-opt cln-b68-neg)"
