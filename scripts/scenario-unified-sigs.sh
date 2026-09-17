#!/usr/bin/env bash
# Can Lightning Fork and privkeyio's Core Lightning share one network yet?
#
# scenario-bit68.sh answered "no, and here are the two barriers", by changing
# their build. This answers the same question by changing ours instead, which
# is the half we control:
#
#   bit 68   option_blake2b, sent as even. lnd refuses an unknown even bit, so
#            naming it in lnwire is enough to stop refusing them. We set the
#            odd form (69) rather than the even one.
#
#   bit 70   option_unified_sigs, inside channel_type. Their build requires it
#            on new channels, so a peer that cannot negotiate it is told
#            "Did not support channel_type [12,22]". Lightning Fork now
#            negotiates it.
#
# The Core Lightning side here is upstream/blake2b-unified plus the
# chain-identity series, the same cln-unified-run:asis image that
# scenario-bit68.sh shows refusing to peer at all.
#
# Earlier wording called that "UNMODIFIED", which it is not: the series is mine.
# Nothing about the 0x21 result below depends on the series, which touches chain
# identity and not signing, so the finding stands. But "their node computed this
# signature" is the whole value of a scenario like this one, and it cannot be
# claimed from a build carrying my patches. cln-vanilla:lab is that commit with
# nothing applied, and scenario-htlc-sighash.sh uses it for exactly this reason.
#
# Since Lightning Fork adopted the chain_hash reversal this image no longer
# peers with it at all: the series gives regtest a chain_hash of
# 2594d57b...ab1a while lf1 now advertises the shared genesis 0f9188f1...2206.
# Re-running this scenario needs cln-vanilla:lab via IMG.
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
inv=$(cli invoice 50000000 uni-$RANDOM "unified" | jq -r .bolt11)
st=failed
for i in $(seq 1 8); do
	lf1 payinvoice --force "$inv" 2>&1 | grep -qi SUCCEEDED && { st=ok; break; }
	sleep 8
done
echo "  Lightning Fork -> Core Lightning : $st"
record unified pay_out "$st"

inv=$(lf1 addinvoice --amt 20000 | jq -r .payment_request)
st2=failed
for i in $(seq 1 8); do
	# `pay` prints progress lines beginning with # ahead of its JSON.
	s=$(cli pay "$inv" 2>/dev/null | grep -v '^#' | jq -r .status 2>/dev/null || echo failed)
	[ "$s" = complete ] && { st2=ok; break; }
	sleep 8
done
echo "  Core Lightning -> Lightning Fork : $st2"
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
if [ "$peered" != 0 ] && [ "$st" = ok ] && [ "$st2" = ok ] \
	&& [ "$coop" = 21 ] && [ "$force" = 21 ]; then
	cat <<EOF

  One network, with no change on their side.

  The Core Lightning node in this run is the same image that
  scenario-bit68.sh shows refusing to peer at all. Lightning Fork now
  names bit 68 instead of refusing it, and negotiates bit 70 instead of
  being refused for lacking it.

  channel_type $ctype, paid both ways, and both closes confirmed with
  0x21 in the witness, which is SIGHASH_ALL|SIGHASH_UNIFIED. The
  signatures on this channel are bound to this chain and cannot be
  replayed on the SHA256d one.
EOF
else
	cat <<EOF

  Something did not hold. peered=$peered pay_out=$st pay_in=$st2
  coop=$coop force=$force (both closes should be 21).

  A close showing 01 means the channel fell back to plain SIGHASH_ALL:
  it works, but its signatures are not bound to this chain, which is the
  whole point of the channel type.
EOF
	exit 1
fi

echo
echo "  (leaving $NODE running; docker rm -f $NODE when done)"
