#!/usr/bin/env bash
# Do public channels opened under the withdrawn chain_hash still gossip after
# the upgrade?
#
# Releases up to v0.21.3-beta-blake2b.9 announced channels under a chain_hash
# of their own. channeldb migration 36 moves the channel state onto the genesis
# hash, but the graph keeps what was announced: the channel_announcement, whose
# signatures cover the old value, and the edge's stored chain hash, from which
# channel_updates are built. Every upgraded node drops gossip that does not name
# its own chain. scenario-chain-hash-migration.sh pays directly between the two
# ends of such a channel, which needs no gossip, so it cannot see this.
#
#   1. three .9 nodes: A with a public channel to B, C peered with A, so all
#      three hold the channel in their graphs
#   2. upgrade all three on their own data directories, and start a fresh node
#      D on the new build, peered with A
#   3. ask: does D learn the channel? does a fee change on A reach C? can D pay
#      B through A?
#   4. is an offer A minted on .9 no longer listed as live?
#   5. from .14: the announcement is signed again by A and B, since no other
#      implementation can check the old one; does a Core Lightning node E,
#      peered with A, learn the channel, and does no lnd node receive a
#      bad-signature warning? (Warnings from a peer with no channel are
#      logged only at PEER debug, which the nodes run with.)
#
# CLN_IMAGE is the Core Lightning release to use for E (on the new bits).
# Setting CLN_IMAGE= skips E, and with it the check that Core Lightning can
# read the channel; a build before .14 fails on the re-sign check anyway.
#
# DB_ARGS picks the database: empty for bbolt, as the Umbrel app runs, or
# "--db.backend=sqlite --db.use-native-sql" for what the StartOS package runs,
# where the graph is in SQL tables and stores no chain hash at all.
#
# The questions are reported rather than asserted one by one, so a run shows
# the whole picture. The verdict fails unless all of them hold.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/lib.sh

N=$(docker network ls --format '{{.Name}}' | grep -m1 lightning-fork-lab)
OLD_IMAGE=${OLD_IMAGE:-paulscode/lightning-fork:0.21.3-beta-blake2b.9}
NEW_IMAGE=${NEW_IMAGE:-lightning-fork:dev}
A=lg-a
B=lg-b
C=lg-c
D=lg-d
E=lg-e
CLN_IMAGE=${CLN_IMAGE-cln-rel5:release}
ALL="$A $B $C $D $E"

exec 9>/tmp/scenario-legacy-gossip.lock
flock -n 9 || fail "another run of this scenario holds the lock"

cleanup() {
	local rc=$?
	if [ "$rc" != 0 ]; then
		for n in $ALL; do
			echo "=== $n (last 15) ==="
			docker logs "$n" 2>&1 | tail -15 || true
		done
	fi
	docker rm -f $ALL >/dev/null 2>&1 || true
}
trap cleanup EXIT

start_node() {
	local name=$1 image=$2
	docker run -d --name "$name" --network "$N" -v "$name-data:/root/.lnd" \
		--platform linux/amd64 "$image" \
		--noseedbackup --bitcoin.regtest --bitcoin.node=bitcoind \
		--bitcoin.blake2b-activation-height="${ACTIVATION_HEIGHT:-20}" \
		--fee.url=http://fees:8080/fees.json \
		--bitcoind.rpchost=knots-b2b:18443 \
		--bitcoind.rpcuser=lab --bitcoind.rpcpass=lab \
		--bitcoind.zmqpubrawblock=tcp://knots-b2b:28332 \
		--bitcoind.zmqpubrawtx=tcp://knots-b2b:28333 \
		--rpclisten=0.0.0.0:10009 --listen=0.0.0.0:9735 \
		--externalip="$name":9735 --tlsextradomain="$name" \
		--trickledelay=500 ${DB_ARGS:-} \
		--alias="$name" --debuglevel=info,DISC=debug,PEER=debug >/dev/null
}

cli() {
	local name=$1; shift
	docker exec "$name" lncli --network=regtest \
		--rpcserver=127.0.0.1:10009 "$@"
}

wait_up() {
	wait_for "$1 up" 180 sh -c \
		"docker exec $1 lncli --network=regtest --rpcserver=127.0.0.1:10009 getinfo 2>/dev/null | grep -Eq '\"synced_to_chain\": +true'"
}

pub() { cli "$1" getinfo | jq -r .identity_pubkey; }

ecli() {
	docker exec "$E" lightning-cli --network=regtest --lightning-dir=/data "$@"
}

start_cln() {
	docker run -d --name "$E" --network "$N" "$CLN_IMAGE" \
		--network=regtest --lightning-dir=/data \
		--bitcoin-rpcconnect=knots-b2b --bitcoin-rpcport=18443 \
		--bitcoin-rpcuser=lab --bitcoin-rpcpassword=lab \
		--bind-addr=0.0.0.0:9735 --announce-addr="$E:9735" \
		--alias="$E" --log-level=debug >/dev/null
}

# cln_scid SCID -> the same short channel id in Core Lightning's notation.
cln_scid() {
	local s=$1
	echo "$((s >> 40))x$(((s >> 16) & 0xFFFFFF))x$((s & 0xFFFF))"
}

fund() {
	local name=$1 addr
	addr=$(cli "$name" newaddress p2tr | jq -r .address)
	b2b -rpcwallet=lab sendtoaddress "$addr" 0.05 >/dev/null
	mine_b2b 6 >/dev/null 2>&1
	wait_for "$name funded" 120 sh -c \
		"[ \"\$(docker exec $name lncli --network=regtest --rpcserver=127.0.0.1:10009 walletbalance | jq -r .confirmed_balance)\" != 0 ]"
}

peer() {
	local from=$1 to=$2 p n
	p=$(pub "$to")
	for i in $(seq 1 18); do
		cli "$from" connect "$p@$to:9735" >/dev/null 2>&1 || true
		n=$(cli "$from" listpeers | jq --arg p "$p" \
			'[.peers[] | select(.pub_key == $p)] | length')
		[ "${n:-0}" -ge 1 ] && return 0
		sleep 5
	done
	fail "$from could not peer with $to"
}

# open_public FROM TO AMT -> prints the channel point once active
open_public() {
	local from=$1 to=$2 amt=$3 p cp=""
	p=$(pub "$to")
	# Retried: a node that has just seen blocks refuses to open until its
	# wallet has caught up with them.
	for i in $(seq 1 12); do
		cli "$from" openchannel --node_key "$p" --local_amt "$amt" \
			>/dev/null 2>&1 && break
		sleep 5
	done
	mine_b2b 6 >/dev/null 2>&1
	for i in $(seq 1 24); do
		cp=$(cli "$from" listchannels | jq -r --arg p "$p" \
			'.channels[] | select(.remote_pubkey == $p and .active) | .channel_point' | head -1)
		[ -n "$cp" ] && [ "$cp" != null ] && break
		mine_b2b 1 >/dev/null 2>&1 || true
		sleep 5
	done
	[ -n "$cp" ] && [ "$cp" != null ] || fail "no active channel $from -> $to"
	echo "$cp"
}

# knows NODE SCID -> 0/1: whether NODE's graph has the edge
knows() {
	cli "$1" getchaninfo --chan_id "$2" >/dev/null 2>&1 && echo 1 || echo 0
}

# base_fee NODE SCID PUB -> the base fee NODE's graph has for PUB's side
base_fee() {
	cli "$1" getchaninfo --chan_id "$2" 2>/dev/null | jq -r --arg p "$3" \
		'if .node1_pub == $p then .node1_policy.fee_base_msat else .node2_policy.fee_base_msat end' \
		2>/dev/null || echo none
}

cleanup
for n in $ALL; do docker volume rm -f "$n-data" >/dev/null 2>&1 || true; done

step "legacy gossip: three nodes on the release that announced under the old chain hash"
for n in $A $B $C; do start_node $n "$OLD_IMAGE"; done
for n in $A $B $C; do wait_up $n; done
echo "  running: $(cli $A getinfo | jq -r .version)"
fund $A
peer $A $B
peer $C $A
cp=$(open_public $A $B 1000000)
# The short channel id as the graph has it, which is what getchaninfo takes.
scid=""
for i in $(seq 1 24); do
	scid=$(cli $A describegraph | jq -r --arg c "$cp" \
		'.edges[] | select(.chan_point == $c) | .channel_id' | head -1)
	[ -n "$scid" ] && [ "$scid" != null ] && break
	sleep 5
done
[ -n "$scid" ] && [ "$scid" != null ] || fail "A never put its own channel in its graph"
echo "  channel        : $cp ($scid)"
mine_b2b 6 >/dev/null 2>&1

wait_for "C learns the A-B channel on .9" 180 sh -c \
	"docker exec $C lncli --network=regtest --rpcserver=127.0.0.1:10009 getchaninfo --chan_id $scid >/dev/null 2>&1"
pass "the channel is public and known to a third node before the upgrade"

# An offer minted by the old release, as a miner would have given a pool.
old_offer=$(cli $A offer create --description "minted by .9" | jq -r '.offer.bolt12')
echo "  offer minted on .9: ${old_offer:0:24}..."

step "legacy gossip: upgrade A, B and C, and start a fresh node D"
for n in $A $B $C; do docker rm -f $n >/dev/null; done
for n in $A $B $C; do start_node $n "$NEW_IMAGE"; done
start_node $D "$NEW_IMAGE"
for n in $A $B $C $D; do wait_up $n; done
peer $A $B
peer $C $A
peer $D $A
if [ -n "$CLN_IMAGE" ]; then
	start_cln
	wait_for "E up" 180 sh -c \
		"docker exec $E lightning-cli --network=regtest --lightning-dir=/data getinfo >/dev/null 2>&1"
	for i in $(seq 1 18); do
		ecli connect "$(pub $A)@$A:9735" >/dev/null 2>&1 && break
		sleep 5
	done
	echo "  E (Core Lightning $(ecli getinfo | jq -r .version)) peered with A"
fi
a_pub=$(pub $A)

step "legacy gossip: 1. does the fresh node learn the channel?"
d_knows=0
for i in $(seq 1 24); do
	d_knows=$(knows $D "$scid")
	[ "$d_knows" = 1 ] && break
	sleep 5
done
echo "  D has the A-B edge: $d_knows"

step "legacy gossip: 2. does a fee change on A reach C?"
cli $A updatechanpolicy --base_fee_msat 7777 --fee_rate_ppm 1 \
	--time_lock_delta 80 --chan_point "$cp" >/dev/null 2>&1 || echo "  (updatechanpolicy returned an error)"
c_fee=none
for i in $(seq 1 24); do
	c_fee=$(base_fee $C "$scid" "$a_pub")
	[ "$c_fee" = 7777 ] && break
	sleep 5
done
echo "  C's base fee for A's side: $c_fee"

step "legacy gossip: 3. can the fresh node pay B through A?"
fund $D
open_public $D $A 500000 >/dev/null
mine_b2b 6 >/dev/null 2>&1
sleep 10
inv=$(cli $B addinvoice --amt 1000 | jq -r .payment_request)
paid=no
out=""
for i in $(seq 1 6); do
	out=$(cli $D payinvoice --force --timeout 30s "$inv" 2>&1 || true)
	if echo "$out" | grep -q SUCCEEDED; then paid=yes; break; fi
	sleep 10
done
echo "  D paid B: $paid"
[ "$paid" = yes ] || echo "$out" | grep -oE "FAILURE_REASON_[A-Z_]+|unable to find a path[^\"]*" | tail -1 | sed 's/^/  why: /'

step "legacy gossip: 4. is the offer minted on .9 listed as live?"
# It sets no option_blake2b, so no upgraded payer will request an invoice for
# it: it must not be listed as active, or it gets handed out again.
old_active=$(cli $A offer list | jq -r --arg b "$old_offer" \
	'[.offers[] | select(.bolt12 == $b) | .active | tostring] | first // "missing"')
echo "  offer minted on .9 active: $old_active"
new_offer=$(cli $A offer create --description "minted by .9" | jq -r '.offer.bolt12')
[ "$new_offer" != "$old_offer" ] || old_active=same-string
echo "  minting it again gives a new string: $([ "$new_offer" != "$old_offer" ] && echo yes || echo no)"

step "legacy gossip: 5. is the announcement signed again, and readable by all?"
resigned=0
for i in $(seq 1 24); do
	resigned=$(docker logs $A 2>&1 | grep -c "Replaced the proof of channel" || true)
	[ "$resigned" -ge 1 ] && break
	sleep 5
done
for n in $A $B; do
	echo "  $n: $(docker logs $n 2>&1 | grep -cE "Signing the proof of channel .* again" || true) re-sign request(s), $(docker logs $n 2>&1 | grep -c "Replaced the proof of channel" || true) replacement(s)"
done
e_knows=skipped
if [ -n "$CLN_IMAGE" ]; then
	e_knows=0
	escid=$(cln_scid "$scid")
	for i in $(seq 1 36); do
		n=$(ecli listchannels "$escid" 2>/dev/null | jq '.channels | length')
		[ "${n:-0}" -ge 1 ] && { e_knows=1; break; }
		mine_b2b 1 >/dev/null 2>&1 || true
		sleep 5
	done
	echo "  E (Core Lightning) has the A-B channel $escid: $e_knows"
fi
warned=0
for n in $A $B $C $D; do
	w=$(docker logs $n 2>&1 | grep -c "Bad node_signature" || true)
	warned=$((warned + w))
done
echo "  bad-signature warnings received by the lnd nodes: $warned"

step "legacy gossip: what the upgraded nodes said about it"
for n in $A $B $C $D; do
	c=$(docker logs $n 2>&1 | grep -cE "ignoring Channel(Announcement1|Update) from chain" || true)
	v=$(docker logs $n 2>&1 | grep -ciE "invalid signature|unable to validate channel ann" || true)
	echo "  $n: wrong-chain rejections $c, signature rejections $v"
done

step "legacy gossip: verdict"
if [ "$d_knows" = 1 ] && [ "$c_fee" = 7777 ] && [ "$paid" = yes ] &&
	[ "$old_active" = false ] && [ "$resigned" -ge 1 ] &&
	[ "$e_knows" != 0 ] && [ "$warned" = 0 ]; then
	echo "PASS"
else
	echo "FAIL: learned=$d_knows fee_propagated=$c_fee paid=$paid old_offer_active=$old_active resigned=$resigned cln_learned=$e_knows warnings=$warned"
	exit 1
fi
