#!/usr/bin/env bash
# Can Lightning Fork and privkeyio's Core Lightning share one network yet?
#
# scenario-bit68.sh answered "no, and here are the two barriers", by changing
# their build. This answers the same question by changing ours instead, which
# is the half we control:
#
#   bit 68   option_blake2b, sent as even by both builds. lnd refuses an
#            unknown even bit, so naming it in lnwire is what stops this node
#            refusing them. Lightning Fork sent the odd form (69) until the
#            chain_hash reversal made that pointless, and now sends 68 like
#            they do; scenario-chain-separation.sh is about that bit.
#
#   bit 70   option_unified_sigs, inside channel_type. Their build requires it
#            on new channels, so a peer that cannot negotiate it is told
#            "Did not support channel_type [12,22]". Lightning Fork
#            negotiates it, on every channel type it opens.
#
# The Core Lightning side is cln-vanilla:lab: blake2b-unified at 24d027310
# with nothing applied on top, the commit recorded in the image at
# /cln-commit. That matters because "their node computed this signature" is
# the whole value of a scenario like this one, and it cannot be claimed from a
# build carrying my own patches.
#
# It used to run against cln-unified-run:asis, which is that commit plus my
# chain-identity series, and the header used to call that "UNMODIFIED". It was
# not. Nothing about the 0x21 results depends on the series, which touches
# chain identity and not signing, so those findings stood; the wording did
# not. That image also cannot peer with this node any more, since the series
# gives regtest a chain_hash of 2594d57b...ab1a while lf1 advertises the
# shared genesis 0f9188f1...2206.
#
# What is checked, in the order money would be at risk:
#   peer -> open -> negotiated type -> pay both ways -> coop close -> force
#   close, with the witness on chain inspected for the 0x21 hash type byte so
#   that a channel which silently fell back to SIGHASH_ALL is not reported as
#   a success.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

N=$(docker network ls --format '{{.Name}}' | grep -m1 lightning-fork-lab)
NODE=cln-unified-peer
IMG=${CLN_IMAGE:-cln-vanilla:lab}

cli() { docker exec $NODE lightning-cli --network=regtest --lightning-dir=/data "$@"; }

docker rm -f $NODE >/dev/null 2>&1 || true
docker volume rm -f $NODE-data >/dev/null 2>&1 || true

step "unified: start the unmodified privkeyio build"
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

# A node that started behind the tip cannot see a payment to itself.
for i in $(seq 1 30); do
	h=$(cli getinfo | jq -r .blockheight)
	[ "$h" = "$(b2b getblockcount)" ] && break
	sleep 10
done

cln_pub=$(cli getinfo | jq -r .id)
lf1_pub=$(pubkey_of lf1)
echo "  Core Lightning : $(cli getinfo | jq -r .version)"
echo "  init features  : $(cli getinfo | jq -r '.our_features.init')  (bit 68 even)"

step "unified: peer"
cli connect "$lf1_pub@lf1:9735" >/dev/null 2>&1 || true
lf1 connect "$cln_pub@$NODE:9735" >/dev/null 2>&1 || true
sleep 6
peered=$(lf1 listpeers | jq "[.peers[] | select(.pub_key == \"$cln_pub\")] | length")
echo "  Lightning Fork sees it: $peered"
record unified peered "$peered"
if [ "$peered" = 0 ]; then
	echo
	echo "  Still refused at init. Check that lnwire names bit 68:"
	$COMPOSE logs --since 90s lf1 2>&1 | grep -oE "unknown required features: \[[0-9]+\]" | tail -1
	exit 1
fi
pass "peered"

step "unified: open a channel"
if ! out=$(lf1 openchannel --node_key "$cln_pub" --local_amt 1000000 2>&1); then
	echo "  refused: $(echo "$out" | tail -1)"
	record unified channel refused
	exit 1
fi
mine_b2b 6
active=0
for i in $(seq 1 18); do
	active=$(lf1 listchannels | jq "[.channels[] | select(.remote_pubkey == \"$cln_pub\" and .active)] | length")
	[ "$active" != 0 ] && break
	sleep 10
done
ctype=$(cli listpeerchannels | jq -c '[.channels[] | select(.state=="CHANNELD_NORMAL")][0].channel_type.bits')
echo "  active: $active, channel_type: $ctype"
record unified channel "$ctype"
[ "$active" = 0 ] && { echo "  channel never went active"; exit 1; }
[ "$ctype" = "[12,22,70]" ] || echo "  NOTE: expected [12,22,70], got $ctype"
pass "channel open, type $ctype"

step "unified: pay both ways"
# Against an unmodified build this does not succeed, and the reason is the
# finding rather than a fault. Their build keeps `bcrt` as its lightning_hrp
# and mints lnbcrt invoices; this one uses lnblakert. Each side refuses the
# other's invoice on the prefix, before any route is considered.
#
# So two nodes that peer, negotiate option_unified_sigs, gossip, and close both
# ways cannot pay each other. The channel is fine. The string a user pastes is
# what is broken, and it is the open question in the reply on the PR.
#
# An earlier version of this scenario ran the payment against a Core Lightning
# built with my own prefix patch, where both sides said lnblakert and it
# passed. That measured my patch talking to itself.
inv=$(cli invoice 50000000 uni-$RANDOM "unified" | jq -r .bolt11)
echo "  their invoice  : ${inv:0:22}..."
out=$(lf1 payinvoice --force --timeout 60s "$inv" 2>&1 || true)
if echo "$out" | grep -qi SUCCEEDED; then
	st=ok
elif echo "$out" | grep -qi "prefix"; then
	st=refused-by-prefix
else
	st=failed
fi
echo "  Lightning Fork -> Core Lightning : $st"
[ "$st" = refused-by-prefix ] && echo "    $(echo "$out" | tail -1)"
record unified pay_out "$st"

inv=$(lf1 addinvoice --amt 20000 | jq -r .payment_request)
echo "  our invoice    : ${inv:0:22}..."
out2=$(cli pay "$inv" 2>&1 | grep -v '^#' || true)
if [ "$(echo "$out2" | jq -r .status 2>/dev/null)" = complete ]; then
	st2=ok
elif echo "$out2" | grep -qi "prefix"; then
	st2=refused-by-prefix
else
	st2=failed
fi
echo "  Core Lightning -> Lightning Fork : $st2"
[ "$st2" = refused-by-prefix ] && echo "    $(echo "$out2" | jq -r .message 2>/dev/null)"
record unified pay_in "$st2"

# hash_byte_of TXID: the trailing byte of the first witness signature, which
# is the hash type both parties signed under. 21 is SIGHASH_ALL|SIGHASH_UNIFIED
# and 01 is plain SIGHASH_ALL, so this distinguishes a channel that really
# negotiated the opt-in from one that quietly did not.
hash_byte_of() {
	b2b getrawtransaction "$1" true 2>/dev/null \
		| jq -r '.vin[0].txinwitness[1]' | tail -c 3
}

step "unified: cooperative close"
cp=$(lf1 listchannels | jq -r ".channels[] | select(.remote_pubkey == \"$cln_pub\") | .channel_point" | head -1)

# `closechannel` without --force blocks until the close confirms, and the
# close cannot confirm until something mines. Run it in the background and
# mine underneath it, rather than waiting for a block that is waiting for us.
# It can also stall in CLOSINGD_SIGEXCHANGE when the two sides disagree about
# the fee, which on this regtest is a lab problem rather than a channel one,
# so give it a bound and say so instead of hanging.
: >/tmp/unified-coop.out
( lf1 closechannel --funding_txid "${cp%%:*}" --output_index "${cp##*:}" \
	>/tmp/unified-coop.out 2>&1 || true ) &
coop_pid=$!
ctx=""
for i in $(seq 1 24); do
	mine_b2b 1 >/dev/null 2>&1 || true
	ctx=$(grep -oE '[a-f0-9]{64}' /tmp/unified-coop.out 2>/dev/null | tail -1)
	if [ -n "$ctx" ] && [ "$(hash_byte_of "$ctx")" != "" ]; then
		break
	fi
	sleep 10
done
kill $coop_pid 2>/dev/null || true
wait $coop_pid 2>/dev/null || true

if [ -z "$ctx" ]; then
	echo "  no closing tx after 4 minutes; channel state:"
	cli listpeerchannels | jq -c '[.channels[] | .state]'
	echo "  CLOSINGD_SIGEXCHANGE here is the lab fee negotiation, not the"
	echo "  channel type: see the fees service in docker-compose.yml."
	record unified coop_close stalled
	coop_byte=stalled
else
	coop_byte=$(hash_byte_of "$ctx")
	echo "  closing tx $ctx, hash type byte: $coop_byte"
	record unified coop_close "$coop_byte"
fi

step "unified: force close"
lf1 connect "$cln_pub@$NODE:9735" >/dev/null 2>&1 || true
lf1 openchannel --node_key "$cln_pub" --local_amt 1000000 >/dev/null 2>&1
mine_b2b 6 >/dev/null 2>&1
for i in $(seq 1 18); do
	cp=$(lf1 listchannels | jq -r ".channels[] | select(.remote_pubkey == \"$cln_pub\" and .active) | .channel_point" | head -1)
	[ -n "$cp" ] && break
	sleep 10
done
out=$(lf1 closechannel --force --funding_txid "${cp%%:*}" --output_index "${cp##*:}" 2>&1 || true)
ftx=$(echo "$out" | grep -oE '[a-f0-9]{64}' | tail -1)
sleep 12; mine_b2b 3 >/dev/null 2>&1; sleep 12
echo "  commitment tx $ftx, hash type byte: $(hash_byte_of "$ftx")"
record unified force_close "$(hash_byte_of "$ftx")"

step "unified: verdict"
coop=$coop_byte; force=$(hash_byte_of "$ftx")

# What has to hold for the channel type to be working: they peer, the type
# carries bit 70, and both closes put 0x21 in the witness. Payment is reported
# but is not one of these, because with an unmodified build it cannot succeed
# for a reason that has nothing to do with signing.
ok=yes
[ "$peered" != 0 ] || ok=no
[ "$coop" = 21 ] || ok=no
[ "$force" = 21 ] || ok=no
case "$st:$st2" in
ok:ok|refused-by-prefix:refused-by-prefix) ;;
*) ok=no ;;
esac

if [ "$ok" = yes ]; then
	cat <<EOF

  One network, with no change on their side.

  channel_type $ctype, and both closes confirmed with 0x21 in the witness,
  which is SIGHASH_ALL|SIGHASH_UNIFIED. The signatures on this channel are
  bound to this chain and cannot be replayed on the SHA256d one. Their node
  computed half of each of those signatures.

  Payments: $st out, $st2 in.
EOF
	if [ "$st" = refused-by-prefix ]; then
		cat <<EOF

  That is the state of things rather than a fault in this run. Their build
  mints lnbcrt and this one mints lnblakert, so each refuses the other's
  invoice on the prefix before a route is considered. Everything below the
  invoice works: peering, channel_type, gossip, both closes. What two correct
  nodes cannot currently do is pay each other, and settling the prefix is what
  fixes it. That is the open question in the reply on privkeyio/lightning#1.
EOF
	fi
else
	cat <<EOF

  Something did not hold. peered=$peered pay_out=$st pay_in=$st2
  coop=$coop force=$force (both closes should be 21).

  A close showing 01 means the channel fell back to plain SIGHASH_ALL:
  it works, but its signatures are not bound to this chain, which is the
  whole point of the channel type.

  Payments must be ok in both directions or refused-by-prefix in both. One of
  each means something other than the prefix is wrong.
EOF
	exit 1
fi

echo
echo "  (leaving $NODE running; docker rm -f $NODE when done)"
