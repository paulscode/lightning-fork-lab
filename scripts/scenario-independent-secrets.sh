#!/usr/bin/env bash
# option_independent_secrets (feature 266/267, channel_type add-on 266)
# between Lightning Fork and the Core Lightning port, on a BLAKE2b regtest of
# its own (isec-knots, a fresh chain for every scenario) on the lab network.
# Nothing here touches the lab's own chain or nodes.
#
#   LND_IMAGE      the build under test (protocol.independent-secrets,
#                  lightning-fork#7)
#   LND_INT_IMAGE  the same tree built with the integration tag, for
#                  --dev.independent-secrets-sender. An integration build
#                  never opts into SIGHASH_UNIFIED (input/sighash_dev.go), so
#                  it doesn't set option_unified_sigs, which the Core
#                  Lightning port requires: no channel opens. Build it with
#                  DefaultUnifiedSigHash() in input/sighash_dev.go returning
#                  true (a lab-only change).
#   LND_REL_IMAGE  the previous release, which doesn't know the option
#   CLN_IMAGE      the Core Lightning port with --independent-secrets
#                  (privkeyio/lightning#48), built from a tree (any build:
#                  --developer is a runtime option)
#
#   bash scripts/scenario-independent-secrets.sh [1 2 3 4 5a 5b 5d 6 7]
#
# 1 negotiation, 2 normal operation, 3 Core Lightning (non-shachain sender)
# breaches and lnd punishes, 4 lnd (non-shachain sender) breaches and Core
# Lightning punishes, 5 splice then breach (5a/5d lnd punishes, 5b Core
# Lightning punishes), 6 an lnd tower punishes for an offline lnd, 7 a peer
# setting 266 in init.
#
# Not a failure, but reported (the NUDGE lines): Core Lightning's HTLC
# penalty is refused at the 253 perkw floor (privkeyio/lightning#49).
#
# A Core Lightning breach uses its dev-sign-last-tx (a commitment signed then,
# broadcast later); an lnd breach restores a copy of its data taken earlier and
# force closes while the peer is down.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

N=lightning-fork-lab_lab
LND_IMAGE=${LND_IMAGE:-isec-lnd:pr}
LND_INT_IMAGE=${LND_INT_IMAGE:-isec-lnd:pr-int}
LND_REL_IMAGE=${LND_REL_IMAGE:-paulscode/lightning-fork:0.21.4-beta-blake2b.21}
CLN_IMAGE=${CLN_IMAGE:-isec-cln:pr48}
# An integration build has anchors off unless asked, unlike a release build.
INT="--protocol.anchors --protocol.independent-secrets --dev.independent-secrets-sender"
EVID=${EVID:-results/independent-secrets}
mkdir -p "$EVID"

ev() { echo "  $*"; echo "$(date -u +%T) $*" >> "$EVID/evidence.log"; }

K() { docker exec isec-knots bitcoin-cli -datadir=/data -rpcuser=lab -rpcpassword=lab "$@"; }
L() { local n=$1; shift; docker exec "$n" lncli --network=regtest --rpcserver=127.0.0.1:10009 "$@"; }
C() { local n=$1; shift; docker exec "$n" lightning-cli --network=regtest --lightning-dir=/data "$@"; }

ALL_LND=""
ALL_CLN=""

cleanup_all() {
	local c
	for c in $(docker ps -a --format '{{.Names}}' | grep '^isec-' || true); do
		docker rm -f "$c" >/dev/null 2>&1 || true
	done
	for c in $(docker volume ls --format '{{.Name}}' | grep '^isec-' || true); do
		docker volume rm -f "$c" >/dev/null 2>&1 || true
	done
	docker network rm isec-aux >/dev/null 2>&1 || true
	ALL_LND=""; ALL_CLN=""
}

# fresh_chain: a new BLAKE2b regtest, past activation, with mature coins.
# The mempool isn't kept across a restart, which scenario 5 relies on.
fresh_chain() {
	cleanup_all
	docker run -d --name isec-knots --network $N -v isec-knots-data:/data \
		-e CHAIN=regtest -e RPC_USER=lab -e RPC_PASSWORD=lab \
		-e "BLAKE2B_HEADLINE=Lightning Fork lab" -e BLAKE2B_ACTIVATION_HEIGHT=20 \
		-e RPC_ALLOW_IP=0.0.0.0/0 knots-blake2b:final-zmq \
		-zmqpubrawblock=tcp://0.0.0.0:28332 -zmqpubrawtx=tcp://0.0.0.0:28333 \
		-txindex=1 -persistmempool=0 >/dev/null
	wait_for "isec-knots up" 60 sh -c "docker exec isec-knots bitcoin-cli -datadir=/data -rpcuser=lab -rpcpassword=lab getblockchaininfo"
	K createwallet lab >/dev/null
	K generatetoaddress 150 "$(K -rpcwallet=lab getnewaddress)" >/dev/null
}

tip() { K getblockcount; }

lnd_at_tip() {
	local i; i=$(L "$1" getinfo 2>/dev/null) || return 1
	[ "$(echo "$i" | jq -r .synced_to_chain)" = true ] && [ "$(echo "$i" | jq -r .block_height)" = "$(tip)" ]
}
cln_at_tip() { [ "$(C "$1" getinfo 2>/dev/null | jq -r .blockheight)" = "$(tip)" ]; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

sync_all() {
	local n
	for n in $ALL_LND; do running "$n" && wait_for "$n at tip" 180 lnd_at_tip "$n"; done
	for n in $ALL_CLN; do running "$n" && wait_for "$n at tip" 180 cln_at_tip "$n"; done
	return 0
}

mine() {
	K generatetoaddress "$1" "$(K -rpcwallet=lab getnewaddress)" >/dev/null
	sync_all
}

# start_lnd NAME IMAGE [FLAGS...]
# --nobootstrap: once a peer's node announcement is in lnd's graph, the
# bootstrapper dials it again although it is connected, and the peer drops the
# connection it had, with any channel open on it.
start_lnd() {
	local n=$1 img=$2; shift 2
	docker run -d --name "$n" --network $N -v "$n-data:/root/.lnd" "$img" \
		--noseedbackup --nobootstrap --bitcoin.regtest --bitcoin.node=bitcoind \
		--bitcoin.blake2b-activation-height=20 \
		--fee.url=http://fees:8080/fees.json \
		--bitcoind.rpchost=isec-knots:18443 --bitcoind.rpcuser=lab --bitcoind.rpcpass=lab \
		--bitcoind.zmqpubrawblock=tcp://isec-knots:28332 --bitcoind.zmqpubrawtx=tcp://isec-knots:28333 \
		--rpclisten=0.0.0.0:10009 --listen=0.0.0.0:9735 --externalip="$n:9735" \
		--tlsextradomain="$n" --alias="$n" \
		--debuglevel=info,PEER=debug,FNDG=debug,BRAR=debug,CNCT=debug,LNWL=debug,HSWC=debug,WTCL=debug,WTWR=debug,CHDB=debug \
		--accept-keysend "$@" >/dev/null
	case " $ALL_LND " in *" $n "*) ;; *) ALL_LND="$ALL_LND $n";; esac
	wait_for "$n RPC" 90 sh -c "docker exec $n lncli --network=regtest getinfo"
}

# start_cln NAME [FLAGS...]
start_cln() {
	local n=$1; shift
	docker run -d --name "$n" --network $N -v "$n-data:/data" "$CLN_IMAGE" \
		--network=regtest --lightning-dir=/data --bitcoin-rpcconnect=isec-knots \
		--bitcoin-rpcport=18443 --bitcoin-rpcuser=lab --bitcoin-rpcpassword=lab \
		--bind-addr=0.0.0.0:9735 --announce-addr="$n:9735" --alias="$n" \
		--log-level=debug --developer "$@" >/dev/null
	case " $ALL_CLN " in *" $n "*) ;; *) ALL_CLN="$ALL_CLN $n";; esac
	wait_for "$n RPC" 90 sh -c "docker exec $n lightning-cli --network=regtest --lightning-dir=/data getinfo"
}

# restart_lnd NAME: keeps the container's arguments.
restart_lnd() {
	docker restart "$1" >/dev/null
	wait_for "$1 RPC" 90 sh -c "docker exec $1 lncli --network=regtest getinfo"
	wait_for "$1 at tip" 180 lnd_at_tip "$1"
}
restart_cln() {
	docker restart "$1" >/dev/null
	wait_for "$1 RPC" 90 sh -c "docker exec $1 lightning-cli --network=regtest --lightning-dir=/data getinfo"
	wait_for "$1 at tip" 180 cln_at_tip "$1"
}

fund_lnd() {
	K -rpcwallet=lab sendtoaddress "$(L "$1" newaddress p2wkh | jq -r .address)" "$2" >/dev/null
}
fund_cln() {
	K -rpcwallet=lab sendtoaddress "$(C "$1" newaddr bech32 | jq -r .bech32)" "$2" >/dev/null
}

lpub() { L "$1" getinfo | jq -r .identity_pubkey; }
cid()  { C "$1" getinfo | jq -r .id; }

# connect_lc LND CLN
connect_lc() {
	L "$1" connect "$(cid "$2")@$2:9735" >/dev/null 2>&1 || true
	wait_for "$1 sees $2" 30 sh -c "docker exec $1 lncli --network=regtest listpeers | jq -e --arg p $(cid "$2") '.peers[] | select(.pub_key == \$p)'"
}
connect_ll() {
	L "$1" connect "$(lpub "$2")@$2:9735" >/dev/null 2>&1 || true
	wait_for "$1 sees $2" 30 sh -c "docker exec $1 lncli --network=regtest listpeers | jq -e --arg p $(lpub "$2") '.peers[] | select(.pub_key == \$p)'"
}

# lchan LND PEER_PUB -> the channel JSON (first one with the peer)
lchans() { L "$1" listchannels | jq --arg p "$2" '[.channels[] | select(.remote_pubkey == $p)]'; }
lchan_by_point() { L "$1" listchannels | jq --arg c "$2" '.channels[] | select(.channel_point == $c)'; }
cchan_by_txid()  { C "$1" listpeerchannels | jq --arg t "$2" '.channels[] | select(.funding_txid == $t)'; }

# lnd_open FROM_LND TO_PUB AMT [ARGS] -> channel point once active
lnd_open() {
	local from=$1 to=$2 amt=$3; shift 3
	local out txid
	out=$(L "$from" openchannel --node_key "$to" --local_amt "$amt" --sat_per_vbyte 2 "$@")
	txid=$(echo "$out" | jq -r .funding_txid)
	mine 6
	wait_for "channel $txid active on $from" 120 sh -c "docker exec $from lncli --network=regtest listchannels | jq -e --arg t $txid '.channels[] | select(.active and (.channel_point | startswith(\$t)))'"
	L "$from" listchannels | jq -r --arg t "$txid" '.channels[] | select(.channel_point | startswith($t)) | .channel_point'
}

# cln_open FROM_CLN TO_PUB AMT [ARGS] -> funding txid once normal
cln_open() {
	local from=$1 to=$2 amt=$3; shift 3
	local txid
	txid=$(C "$from" fundchannel "$to" "$amt" "$@" | jq -r .txid)
	mine 6
	wait_for "channel $txid normal on $from" 120 sh -c "[ \"\$(docker exec $from lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq -r --arg t $txid '.channels[] | select(.funding_txid == \$t) | .state')\" = CHANNELD_NORMAL ]"
	echo "$txid"
}

has_addon_cln() { echo "$1" | jq -e '.channel_type.names | index("independent_secrets/even")' >/dev/null; }

# db_version LND -> the version lnd reported at its last start
db_version() {
	docker logs "$1" 2>&1 | grep -o 'Checking for schema update: latest_version=[0-9]*, db_version=[0-9]*' | tail -1 | sed 's/.*db_version=//'
}

# pay_lc LND CLN SAT: lnd pays a Core Lightning invoice
pay_lc() {
	local inv i
	inv=$(C "$2" invoice "${3}000" "lc-$RANDOM-$RANDOM" x | jq -r .bolt11)
	for i in 1 2 3 4 5; do
		L "$1" payinvoice --force --json "$inv" 2>/dev/null | jq -e '.status == "SUCCEEDED"' >/dev/null && return 0
		sleep 3
	done
	fail "$1 could not pay $2"
}
pay_cl() {
	local inv i
	inv=$(L "$1" addinvoice --amt "$3" | jq -r .payment_request)
	for i in 1 2 3 4 5; do
		C "$2" pay "$inv" 2>/dev/null | sed '/^#/d' | jq -e '.status == "complete"' >/dev/null && return 0
		sleep 3
	done
	fail "$2 could not pay $1"
}
pay_ll() {
	local inv i
	inv=$(L "$2" addinvoice --amt "$3" | jq -r .payment_request)
	for i in 1 2 3 4 5; do
		L "$1" payinvoice --force --json "$inv" 2>/dev/null | jq -e '.status == "SUCCEEDED"' >/dev/null && return 0
		sleep 3
	done
	fail "$1 could not pay $2"
}

# snap_vol NAME TAG: copy a stopped node's volume aside; restore_vol puts it back.
snap_vol() {
	docker run --rm -v "$1-data:/from" -v "isec-snap-$2:/to" debian:bookworm-slim sh -c 'rm -rf /to/* && cp -a /from/. /to/'
}
restore_vol() {
	docker run --rm -v "isec-snap-$2:/from" -v "$1-data:/to" debian:bookworm-slim sh -c 'rm -rf /to/* /to/.[!.]* 2>/dev/null; cp -a /from/. /to/'
}

lbal() { L "$1" walletbalance | jq -r .confirmed_balance; }
cbal() { C "$1" listfunds | jq '[.outputs[] | select(.status == "confirmed") | .amount_msat] | add // 0 | . / 1000 | floor'; }

feat_bits() { L "$1" getinfo | jq -c '.features | keys | map(tonumber) | map(select(. >= 260 and . < 270))'; }

########################################################################
s1() {
	step "1. negotiation"
	fresh_chain
	start_lnd isec-lon "$LND_IMAGE" --protocol.independent-secrets
	start_lnd isec-loff "$LND_IMAGE"
	start_lnd isec-lrel "$LND_REL_IMAGE"
	start_cln isec-con --independent-secrets
	start_cln isec-coff
	mine 1
	for n in isec-lon isec-loff isec-lrel; do fund_lnd $n 2; done
	for n in isec-con isec-coff; do fund_cln $n 2; done
	mine 6
	ev "lnd on bits: $(feat_bits isec-lon); lnd off bits: $(feat_bits isec-loff); release bits: $(feat_bits isec-lrel)"
	ev "CLN on: $(C isec-con getinfo | jq -r .our_features.init | python3 -c 'import sys; v=int(sys.stdin.read(),16); print([b for b in range(260,270) if v>>b&1])'); CLN off: $(C isec-coff getinfo | jq -r .our_features.init | python3 -c 'import sys; v=int(sys.stdin.read(),16); print([b for b in range(260,270) if v>>b&1])')"
	feat_bits isec-lon | jq -e 'index(267) and (index(266) | not)' >/dev/null || fail "lnd on doesn't signal 267 (alone of 266/267)"
	feat_bits isec-loff | jq -e '(index(266) or index(267)) | not' >/dev/null || fail "lnd off signals 266/267"

	local con coff lon loff lrel cp tx ch
	con=$(cid isec-con); coff=$(cid isec-coff)
	lon=$(lpub isec-lon); loff=$(lpub isec-loff); lrel=$(lpub isec-lrel)

	# lnd off: its version before any peer tries anything.
	restart_lnd isec-loff
	ev "lnd off db_version at start: $(db_version isec-loff)"

	step "1a. lnd(on) <-> CLN(on), each opening"
	connect_lc isec-lon isec-con
	cp=$(lnd_open isec-lon "$con" 1000000 --push_amt 100000)
	ch=$(lchan_by_point isec-lon "$cp")
	ev "lnd->CLN $cp: lnd independent_secrets=$(echo "$ch" | jq .independent_secrets) commitment_type=$(echo "$ch" | jq -r .commitment_type)"
	ev "  CLN channel_type: $(cchan_by_txid isec-con "${cp%:*}" | jq -c .channel_type.names)"
	echo "$ch" | jq -e '.independent_secrets == true' >/dev/null || fail "lnd-opened channel without the add-on (lnd)"
	has_addon_cln "$(cchan_by_txid isec-con "${cp%:*}")" || fail "lnd-opened channel without the add-on (CLN)"
	tx=$(cln_open isec-con "$lon" 800000)
	ch=$(L isec-lon listchannels | jq --arg t "$tx" '.channels[] | select(.channel_point | startswith($t))')
	ev "CLN->lnd $tx: lnd independent_secrets=$(echo "$ch" | jq .independent_secrets); CLN channel_type: $(cchan_by_txid isec-con "$tx" | jq -c .channel_type.names)"
	echo "$ch" | jq -e '.independent_secrets == true' >/dev/null || fail "CLN-opened channel without the add-on (lnd)"
	has_addon_cln "$(cchan_by_txid isec-con "$tx")" || fail "CLN-opened channel without the add-on (CLN)"
	pay_lc isec-lon isec-con 20000; pay_cl isec-lon isec-con 10000
	restart_lnd isec-lon
	ev "lnd on db_version after add-on channels: $(db_version isec-lon)"
	[ "$(db_version isec-lon)" = 39 ] || fail "lnd on not at 39"
	pass "1a: both directions carry independent_secrets/even, payments both ways, db at 39"

	step "1b. lnd(on) <-> CLN(off)"
	connect_lc isec-lon isec-coff
	cp=$(lnd_open isec-lon "$coff" 600000)
	ch=$(lchan_by_point isec-lon "$cp")
	ev "lnd(on)->CLN(off) $cp: independent_secrets=$(echo "$ch" | jq .independent_secrets); CLN: $(cchan_by_txid isec-coff "${cp%:*}" | jq -c .channel_type.names)"
	echo "$ch" | jq -e '.independent_secrets == false' >/dev/null || fail "add-on with CLN off"
	! has_addon_cln "$(cchan_by_txid isec-coff "${cp%:*}")" || fail "CLN off has the add-on"
	tx=$(cln_open isec-coff "$lon" 600000)
	ch=$(L isec-lon listchannels | jq --arg t "$tx" '.channels[] | select(.channel_point | startswith($t))')
	ev "CLN(off)->lnd(on) $tx: independent_secrets=$(echo "$ch" | jq .independent_secrets); CLN: $(cchan_by_txid isec-coff "$tx" | jq -c .channel_type.names)"
	echo "$ch" | jq -e '.independent_secrets == false' >/dev/null || fail "add-on with CLN off"
	pay_lc isec-lon isec-coff 10000
	pass "1b: normal channels both ways"

	step "1c. lnd(off) <-> CLN(on)"
	connect_lc isec-loff isec-con
	cp=$(lnd_open isec-loff "$con" 600000)
	ch=$(lchan_by_point isec-loff "$cp")
	ev "lnd(off)->CLN(on) $cp: independent_secrets=$(echo "$ch" | jq .independent_secrets); CLN: $(cchan_by_txid isec-con "${cp%:*}" | jq -c .channel_type.names)"
	echo "$ch" | jq -e '.independent_secrets == false' >/dev/null || fail "add-on with lnd off"
	tx=$(cln_open isec-con "$loff" 600000)
	ch=$(L isec-loff listchannels | jq --arg t "$tx" '.channels[] | select(.channel_point | startswith($t))')
	ev "CLN(on)->lnd(off) $tx: independent_secrets=$(echo "$ch" | jq .independent_secrets); CLN: $(cchan_by_txid isec-con "$tx" | jq -c .channel_type.names)"
	echo "$ch" | jq -e '.independent_secrets == false' >/dev/null || fail "add-on with lnd off"
	! has_addon_cln "$(cchan_by_txid isec-con "$tx")" || fail "CLN has the add-on with lnd off"
	# An explicit attempt: CLN names a channel type with 266 to lnd off.
	local ct out
	ct=$(cchan_by_txid isec-con "$tx" | jq -c '.channel_type.bits + [266]')
	out=$(C isec-con -k fundchannel id="$loff" amount=500000 channel_type="$ct" 2>&1 || true)
	ev "CLN fundchannel channel_type=$ct to lnd off: $(echo "$out" | tr -d '\n' | cut -c1-240)"
	echo "$out" | grep -q '"txid"' && fail "lnd off accepted a channel type with 266"
	restart_lnd isec-loff
	ev "lnd off db_version after the peer's attempts: $(db_version isec-loff)"
	[ "$(db_version isec-loff)" -lt 39 ] || fail "lnd off at 39"
	pass "1c: normal channels both ways, explicit 266 refused, db stays $(db_version isec-loff)"

	step "1d. release .21 <-> lnd(on)"
	connect_ll isec-lon isec-lrel
	cp=$(lnd_open isec-lon "$lrel" 600000)
	ev "lnd(on)->.21 $cp: on: independent_secrets=$(lchan_by_point isec-lon "$cp" | jq .independent_secrets); .21: $(lchan_by_point isec-lrel "$cp" | jq -c '{commitment_type, independent_secrets}')"
	lchan_by_point isec-lon "$cp" | jq -e '.independent_secrets == false' >/dev/null || fail "add-on with .21"
	cp=$(lnd_open isec-lrel "$lon" 600000)
	ev ".21->lnd(on) $cp: on: independent_secrets=$(lchan_by_point isec-lon "$cp" | jq .independent_secrets)"
	lchan_by_point isec-lon "$cp" | jq -e '.independent_secrets == false' >/dev/null || fail "add-on with .21"
	pay_ll isec-lon isec-lrel 5000; pay_ll isec-lrel isec-lon 2000
	pass "1d: normal channels both ways with the release, payments both ways"
}

# hold_htlc LND CLN SAT -> payment hash: CLN pays a hold invoice of lnd's, and
# the HTLC stays on the channel until settle_htlc/cancel.
hold_htlc() {
	local pre hash inv
	pre=$(openssl rand -hex 32); hash=$(printf %s "$pre" | xxd -r -p | sha256sum | cut -d' ' -f1)
	echo "$pre" > "/tmp/isec-work/pre-$hash"
	inv=$(L "$1" addholdinvoice "$hash" --amt "$3" --expiry 3600 | jq -r .payment_request)
	docker exec -d "$2" sh -c "lightning-cli --network=regtest --lightning-dir=/data pay $inv > /tmp/pay-$hash.log 2>&1"
	wait_for "hold invoice accepted" 60 sh -c "[ \"\$(docker exec $1 lncli --network=regtest lookupinvoice $hash | jq -r .state)\" = ACCEPTED ]"
	echo "$hash"
}
settle_htlc() { L "$1" settleinvoice "$(cat "/tmp/isec-work/pre-$2")" >/dev/null; }

pending_htlcs() { lchan_by_point "$1" "$2" | jq '.pending_htlcs | length'; }
cstored() { cchan_by_txid "$1" "$2" | jq -r '.independent_secrets_stored'; }

# lnd_resolved LND: nothing pending to sweep
lnd_resolved() { L "$1" pendingchannels | jq -e '(.pending_force_closing_channels | length) == 0 and (.waiting_close_channels | length) == 0' >/dev/null; }
# cln_resolved CLN TXID: the channel is gone from listpeerchannels, or its outputs all resolved
cln_resolved() {
	local st; st=$(C "$1" listpeerchannels | jq -r --arg t "$2" '.channels[] | select(.funding_txid == $t) | .state')
	[ -z "$st" ] || C "$1" listpeerchannels | jq -e --arg t "$2" '.channels[] | select(.funding_txid == $t) | .status | map(select(test("All outputs resolved"))) | length > 0' >/dev/null
}
mine_until() { # mine_until DESC MAXBLOCKS CMD...: one block at a time
	local what=$1 max=$2 i; shift 2
	for ((i=0; i<max; i+=2)); do
		"$@" >/dev/null 2>&1 && return 0
		mine 2
	done
	"$@" >/dev/null 2>&1 || fail "not $what after $max blocks"
}

s2() {
	step "2. normal operation, both ends sending non-shachain secrets"
	fresh_chain
	start_lnd isec-l "$LND_INT_IMAGE" $INT
	start_cln isec-c --independent-secrets --dev-independent-secrets-sender
	mine 1; fund_lnd isec-l 3; fund_cln isec-c 3; mine 6
	connect_lc isec-l isec-c
	local cpub lp a b c i h bl bc
	cpub=$(cid isec-c); lp=$(lpub isec-l)
	a=$(lnd_open isec-l "$cpub" 2000000 --push_amt 500000)
	b=$(lnd_open isec-l "$cpub" 1000000 --push_amt 300000)
	c=$(cln_open isec-c "$lp" 1000000)
	for x in "$a" "$b" "$c"; do
		has_addon_cln "$(cchan_by_txid isec-c "${x%:*}")" || fail "$x without the add-on"
	done
	c=$(L isec-l listchannels | jq -r --arg t "$c" '.channels[] | select(.channel_point | startswith($t)) | .channel_point')
	ev "channels a=$a b=$b c=$c, all independent_secrets: $(L isec-l listchannels | jq -c '[.channels[].independent_secrets]')"

	step "2a. payments both ways"
	for i in $(seq 1 8); do pay_lc isec-l isec-c 7000; pay_cl isec-l isec-c 3000; done
	ev "CLN stores lnd's secrets one by one: a=$(cstored isec-c "${a%:*}") b=$(cstored isec-c "${b%:*}") c=$(cstored isec-c "${c%:*}")"
	[ "$(cstored isec-c "${a%:*}")" -gt 0 ] || fail "CLN stores none of lnd's secrets"
	pass "16 payments both ways"

	step "2b. an HTLC held across restarts of both nodes"
	h=$(hold_htlc isec-l isec-c 25000)
	ev "held HTLC $h on: $(L isec-l listchannels | jq -c '[.channels[] | {channel_point, n: (.pending_htlcs|length)}]')"
	restart_lnd isec-l
	restart_cln isec-c
	connect_lc isec-l isec-c
	wait_for "channels active" 90 sh -c "[ \"\$(docker exec isec-l lncli --network=regtest listchannels --active_only | jq '.channels | length')\" = 3 ]"
	[ "$(L isec-l lookupinvoice "$h" | jq -r .state)" = ACCEPTED ] || fail "HTLC lost over the restarts"
	settle_htlc isec-l "$h"
	wait_for "CLN's payment complete" 60 sh -c "docker exec isec-c lightning-cli --network=regtest --lightning-dir=/data listpays | jq -e --arg h $h '.pays[] | select(.payment_hash == \$h and .status == \"complete\")'"
	ev "HTLC $h settled after restarts; lnd invoice state $(L isec-l lookupinvoice "$h" | jq -r .state)"
	for i in 1 2 3; do pay_lc isec-l isec-c 4000; pay_cl isec-l isec-c 2000; done
	pass "held over restarts, settled, payments continue"

	step "2c. disconnect, reconnect"
	C isec-c -k disconnect id="$lp" force=true >/dev/null
	sleep 2
	connect_lc isec-l isec-c
	wait_for "channels active" 90 sh -c "[ \"\$(docker exec isec-l lncli --network=regtest listchannels --active_only | jq '.channels | length')\" = 3 ]"
	pay_lc isec-l isec-c 4000; pay_cl isec-l isec-c 2000
	ev "after reconnect stored on CLN: a=$(cstored isec-c "${a%:*}")"
	pass "reconnected, payments both ways"

	step "2d. cooperative close (a, lnd closes)"
	local loc rem lb0 cb0
	loc=$(lchan_by_point isec-l "$a" | jq -r .local_balance); rem=$(lchan_by_point isec-l "$a" | jq -r .remote_balance)
	lb0=$(lbal isec-l); cb0=$(cbal isec-c)
	L isec-l closechannel --chan_point "$a" --sat_per_vbyte 1 >/dev/null &
	sleep 5; mine 1; wait
	mine 5
	wait_for "a closed" 60 sh -c "docker exec isec-l lncli --network=regtest closedchannels | jq -e --arg c $a '.channels[] | select(.channel_point == \$c and .close_type == \"COOPERATIVE_CLOSE\")'"
	ev "coop close $a: lnd local $loc -> wallet +$(( $(lbal isec-l) - lb0 )); CLN remote $rem -> wallet +$(( $(cbal isec-c) - cb0 )); closing tx $(L isec-l closedchannels | jq -r --arg c "$a" '.channels[] | select(.channel_point == $c) | .closing_tx_hash')"
	[ $(( $(lbal isec-l) - lb0 )) -gt $(( loc - 3000 )) ] || fail "lnd short after coop close"
	[ $(( $(cbal isec-c) - cb0 )) -ge $(( rem - 3000 )) ] || fail "CLN short after coop close"
	pass "cooperative close, both paid"

	step "2e. lnd force closes b with an HTLC in flight"
	h=$(hold_htlc isec-l isec-c 30000)
	[ "$(pending_htlcs isec-l "$b")$(pending_htlcs isec-l "$c")" != 00 ] || fail "no HTLC in flight"
	local hb; hb=$( [ "$(pending_htlcs isec-l "$b")" = 1 ] && echo "$b" || echo "$c")
	# The HTLC is on hb; lnd settles it on chain after the close.
	loc=$(lchan_by_point isec-l "$hb" | jq -r .local_balance); rem=$(lchan_by_point isec-l "$hb" | jq -r .remote_balance)
	lb0=$(lbal isec-l); cb0=$(cbal isec-c)
	L isec-l closechannel --force --chan_point "$hb" >/dev/null
	mine 1
	settle_htlc isec-l "$h"
	mine_until "lnd resolved" 400 lnd_resolved isec-l
	mine_until "CLN resolved" 200 cln_resolved isec-c "${hb%:*}"
	mine 3
	ev "force close $hb with HTLC 30000 (lnd settles on chain): lnd local $loc + htlc 30000 -> wallet +$(( $(lbal isec-l) - lb0 )); CLN remote $rem -> wallet +$(( $(cbal isec-c) - cb0 ))"
	ev "  lnd closed: $(L isec-l closedchannels | jq -c --arg c "$hb" '.channels[] | select(.channel_point == $c) | {close_type, closing_tx_hash, settled_balance, time_locked_balance, independent_secrets}')"
	[ $(( $(lbal isec-l) - lb0 )) -gt $(( loc + 30000 - 8000 )) ] || fail "lnd short after force close"
	[ $(( $(cbal isec-c) - cb0 )) -ge $(( rem - 30000 - 3000 )) ] || fail "CLN short after force close"
	pass "force close with an HTLC: all resolved"

	step "2f. CLN force closes the other"
	local other; other=$(L isec-l listchannels | jq -r '.channels[0].channel_point')
	loc=$(lchan_by_point isec-l "$other" | jq -r .local_balance); rem=$(lchan_by_point isec-l "$other" | jq -r .remote_balance)
	lb0=$(lbal isec-l); cb0=$(cbal isec-c)
	C isec-c close "$(cchan_by_txid isec-c "${other%:*}" | jq -r .short_channel_id)" 1 >/dev/null
	mine 1
	mine_until "lnd resolved" 50 lnd_resolved isec-l
	mine_until "CLN resolved" 400 cln_resolved isec-c "${other%:*}"
	mine 3
	ev "CLN force close $other: lnd local $loc -> +$(( $(lbal isec-l) - lb0 )); CLN local $rem -> +$(( $(cbal isec-c) - cb0 ))"
	[ $(( $(lbal isec-l) - lb0 )) -gt $(( loc - 3000 )) ] || fail "lnd short"
	[ $(( $(cbal isec-c) - cb0 )) -ge $(( rem - 5000 )) ] || fail "CLN short"
	pass "CLN's force close: all resolved"
}

# signed_last CLN PEER_PUB -> Core Lightning's current commitment, signed
signed_last() { C "$1" dev-sign-last-tx "$2" | jq -r .tx; }

# lnd_punished LND CHAN_POINT: a breach close, and nothing left pending
lnd_breach_closed() {
	L "$1" closedchannels | jq -e --arg c "$2" '.channels[] | select(.channel_point == $c and .close_type == "BREACH_CLOSE")' >/dev/null
}

# breach_report LND CHAN_POINT BREACH_TXID: the justice transaction(s) spending the breach
justice_of() {
	local b=$1 h txs
	K getrawtransaction "$b" 1 >/dev/null 2>&1 || return 0
	# Every confirmed tx in the blocks since the breach that spends one of its outputs.
	local bh; bh=$(K getrawtransaction "$b" 1 | jq -r .blockhash)
	local hgt; hgt=$(K getblock "$bh" | jq -r .height)
	local t; t=$(tip)
	for ((h=hgt; h<=t; h++)); do
		K getblock "$(K getblockhash $h)" 2 | jq -r --arg b "$b" '.tx[] | select(any(.vin[]; .txid == $b)) | "\(.txid) in=\(.vin | map(select(.txid == $b) | .vout) | tostring) out=\([.vout[].value] | add)"'
	done
}

s3() {
	step "3. Core Lightning sends non-shachain secrets and broadcasts a revoked state; lnd punishes"
	fresh_chain
	start_lnd isec-l "$LND_IMAGE" --protocol.independent-secrets
	start_cln isec-c --independent-secrets --dev-independent-secrets-sender
	start_cln isec-c2 --independent-secrets --dev-independent-secrets-sender
	mine 1; fund_lnd isec-l 2; fund_cln isec-c 2; fund_cln isec-c2 2; mine 6
	connect_lc isec-l isec-c; connect_lc isec-l isec-c2
	local lp tx cp old i lb0 btx cap loc
	lp=$(lpub isec-l)

	step "3a. a revoked state without HTLCs"
	tx=$(cln_open isec-c "$lp" 1000000)
	cp=$(L isec-l listchannels | jq -r --arg t "$tx" '.channels[] | select(.channel_point | startswith($t)) | .channel_point')
	lchan_by_point isec-l "$cp" | jq -e .independent_secrets >/dev/null || fail "no add-on"
	pay_cl isec-l isec-c 200000
	old=$(signed_last isec-c "$lp")
	ev "revoked-to-be state of $cp captured: lnd local $(lchan_by_point isec-l "$cp" | jq -r .local_balance), CLN local $(lchan_by_point isec-l "$cp" | jq -r .remote_balance), txid $(K decoderawtransaction "$old" | jq -r .txid)"
	for i in $(seq 1 12); do pay_cl isec-l isec-c 20000; pay_lc isec-l isec-c 1000; done
	ev "after 24 more payments: lnd local $(lchan_by_point isec-l "$cp" | jq -r .local_balance); CLN independent? lnd stores CLN's secrets; CLN's own count of lnd's: $(cstored isec-c "$tx")"
	cap=1000000; loc=$(lchan_by_point isec-l "$cp" | jq -r .local_balance)
	lb0=$(lbal isec-l)
	btx=$(K sendrawtransaction "$old")
	ev "CLN's revoked commitment broadcast: $btx"
	mine 1
	mine_until "breach closed" 40 lnd_breach_closed isec-l "$cp"
	mine_until "lnd resolved" 40 lnd_resolved isec-l
	mine 2
	ev "justice: $(justice_of "$btx" | tr '\n' ';')"
	ev "lnd wallet +$(( $(lbal isec-l) - lb0 )) of capacity $cap (its own balance was $loc); closed: $(L isec-l closedchannels | jq -c --arg c "$cp" '.channels[] | select(.channel_point == $c) | {close_type, closing_tx_hash, settled_balance, independent_secrets}')"
	[ $(( $(lbal isec-l) - lb0 )) -gt $(( cap - 20000 )) ] || fail "lnd didn't take the channel"
	pass "3a: lnd swept $(( $(lbal isec-l) - lb0 )) of $cap"

	step "3b. a revoked state with an HTLC in flight"
	tx=$(cln_open isec-c2 "$lp" 1000000)
	cp=$(L isec-l listchannels | jq -r --arg t "$tx" '.channels[] | select(.channel_point | startswith($t)) | .channel_point')
	pay_cl isec-l isec-c2 200000
	local h; h=$(hold_htlc isec-l isec-c2 150000)
	old=$(signed_last isec-c2 "$lp")
	ev "revoked-to-be state of $cp with HTLC $h (150000 sat): outputs $(K decoderawtransaction "$old" | jq -c '[.vout[].value]')"
	settle_htlc isec-l "$h"
	for i in $(seq 1 10); do pay_cl isec-l isec-c2 20000; pay_lc isec-l isec-c2 1000; done
	loc=$(lchan_by_point isec-l "$cp" | jq -r .local_balance); lb0=$(lbal isec-l)
	btx=$(K sendrawtransaction "$old")
	ev "revoked commitment with the HTLC broadcast: $btx"
	mine 1
	mine_until "breach closed" 40 lnd_breach_closed isec-l "$cp"
	mine_until "lnd resolved" 40 lnd_resolved isec-l
	mine 2
	ev "justice: $(justice_of "$btx" | tr '\n' ';')"
	ev "lnd wallet +$(( $(lbal isec-l) - lb0 )) of 1000000 (own $loc)"
	[ $(( $(lbal isec-l) - lb0 )) -gt $(( 1000000 - 20000 )) ] || fail "lnd didn't take the channel and the HTLC"
	pass "3b: lnd swept $(( $(lbal isec-l) - lb0 )) of 1000000, HTLC output included"
}

# lnd_snapshot LND TAG: stop, copy the data aside, start again.
lnd_snapshot() {
	docker stop "$1" >/dev/null
	snap_vol "$1" "$2"
	docker start "$1" >/dev/null
	wait_for "$1 RPC" 90 sh -c "docker exec $1 lncli --network=regtest getinfo"
	wait_for "$1 at tip" 180 lnd_at_tip "$1"
}

# lnd_breach LND TAG CHAN_POINT PEER_CONTAINER -> the revoked commitment's txid:
# the peer goes down, lnd comes back on the old data and force closes.
lnd_breach() {
	local n=$1 tag=$2 cp=$3 peer=$4 before
	docker stop "$peer" >/dev/null
	docker stop "$n" >/dev/null
	restore_vol "$n" "$tag"
	docker start "$n" >/dev/null
	wait_for "$n RPC" 90 sh -c "docker exec $n lncli --network=regtest getinfo"
	wait_for "$n at tip" 180 lnd_at_tip "$n"
	L "$n" closechannel --force --chan_point "$cp" >/dev/null
	wait_for "force close in the mempool" 60 sh -c "docker exec isec-knots bitcoin-cli -datadir=/data -rpcuser=lab -rpcpassword=lab getrawmempool | jq -e 'length > 0'"
	L "$n" pendingchannels | jq -r --arg c "$cp" '.waiting_close_channels[] | select(.channel.channel_point == $c) | .closing_txid'
}

cln_penalty_logged() { docker logs "$1" 2>&1 | grep -q 'OUR_PENALTY_TX'; }

# cln_relay_nudge CLN: Core Lightning's estimate of a penalty transaction's
# weight leaves out the revocation pubkey it puts in the witness of an HTLC
# penalty (lightningd/onchain_control.c, "Worst-case sig is 73 bytes"), 34
# weight units short, so at its 253 perkw floor the transaction pays under
# 1 sat/vB and the node refuses it ("min relay fee not met"). The same line is
# in the port before this feature and upstream. Raise such a transaction's
# modified fee so the scenario can go on, and say so.
cln_relay_nudge() {
	local hex txid
	for hex in $(docker logs "$1" 2>&1 | grep 'Expected error broadcasting tx' | grep 'min relay fee not met' | sed 's/.*broadcasting tx \([0-9a-f]*\):.*/\1/' | sort -u); do
		txid=$(K decoderawtransaction "$hex" | jq -r .txid)
		[ -f "/tmp/isec-work/nudged-$txid" ] && continue
		touch "/tmp/isec-work/nudged-$txid"
		K prioritisetransaction "$txid" 0 1000 >/dev/null
		ev "NUDGE: $1's $txid refused for the min relay fee ($(K decoderawtransaction "$hex" | jq -c '{weight, vsize, witness: [.vin[0].txinwitness[] | length/2]}')); prioritised"
	done
}
cln_resolved_nudged() { cln_relay_nudge "$1"; cln_resolved "$@"; }

s4() {
	step "4. lnd sends non-shachain secrets and broadcasts a revoked state; Core Lightning punishes"
	fresh_chain
	start_lnd isec-l "$LND_INT_IMAGE" $INT
	start_cln isec-c --independent-secrets
	start_cln isec-c2 --independent-secrets
	mine 1; fund_lnd isec-l 3; fund_cln isec-c 1; fund_cln isec-c2 1; mine 6
	connect_lc isec-l isec-c; connect_lc isec-l isec-c2
	local cpub cp btx cb0 rem i h
	ALL_CLN_SAVE=$ALL_CLN

	step "4a. a revoked state without HTLCs"
	cpub=$(cid isec-c)
	cp=$(lnd_open isec-l "$cpub" 1000000)
	pay_lc isec-l isec-c 200000
	lnd_snapshot isec-l s4a
	connect_lc isec-l isec-c
	wait_for "active" 60 sh -c "docker exec isec-l lncli --network=regtest listchannels --active_only | jq -e '.channels | length == 1'"
	ev "snapshot of lnd taken: CLN local $(lchan_by_point isec-l "$cp" | jq -r .remote_balance)"
	for i in $(seq 1 12); do pay_lc isec-l isec-c 20000; pay_cl isec-l isec-c 1000; done
	ev "CLN stores lnd's secrets one by one: $(cstored isec-c "${cp%:*}")"
	[ "$(cstored isec-c "${cp%:*}")" -gt 10 ] || fail "CLN isn't storing lnd's secrets one by one"
	rem=$(cchan_by_txid isec-c "${cp%:*}" | jq -r '.to_us_msat / 1000 | floor')
	cb0=$(cbal isec-c)
	ALL_CLN=""  # Core Lightning is down for the breach
	btx=$(lnd_breach isec-l s4a "$cp" isec-c)
	ev "lnd's revoked commitment broadcast: $btx ($(K getrawtransaction "$btx" 1 | jq -c '[.vout[].value]'))"
	mine 1
	docker start isec-c >/dev/null
	ALL_CLN=$ALL_CLN_SAVE
	wait_for "isec-c RPC" 90 sh -c "docker exec isec-c lightning-cli --network=regtest --lightning-dir=/data getinfo"
	wait_for "isec-c at tip" 180 cln_at_tip isec-c
	wait_for "CLN's penalty" 120 cln_penalty_logged isec-c
	mine_until "CLN resolved" 150 cln_resolved_nudged isec-c "${cp%:*}"
	mine 3
	ev "CLN: $(docker logs isec-c 2>&1 | grep -oE 'Resolved THEIR_REVOKED_UNILATERAL/[A-Z_]+ by our proposal OUR_PENALTY_TX' | sort | uniq -c | tr '\n' ';')"
	ev "penalty: $(justice_of "$btx" | tr '\n' ';')"
	ev "CLN wallet +$(( $(cbal isec-c) - cb0 )) of 1000000 (own $rem)"
	[ $(( $(cbal isec-c) - cb0 )) -gt $(( 1000000 - 20000 )) ] || fail "CLN didn't take the channel"
	pass "4a: CLN swept $(( $(cbal isec-c) - cb0 )) of 1000000"

	step "4b. a revoked state with an HTLC in flight"
	cpub=$(cid isec-c2)
	connect_lc isec-l isec-c2
	cp=$(lnd_open isec-l "$cpub" 1000000)
	pay_lc isec-l isec-c2 300000
	h=$(hold_htlc isec-l isec-c2 150000)
	lnd_snapshot isec-l s4b
	connect_lc isec-l isec-c2
	wait_for "active" 60 sh -c "docker exec isec-l lncli --network=regtest listchannels --active_only | jq -e '.channels | length == 1'"
	ev "snapshot with HTLC $h in flight: $(lchan_by_point isec-l "$cp" | jq -c '{local_balance, remote_balance, htlcs: [.pending_htlcs[].amount]}')"
	settle_htlc isec-l "$h"
	for i in $(seq 1 10); do pay_lc isec-l isec-c2 20000; pay_cl isec-l isec-c2 1000; done
	ev "CLN stores: $(cstored isec-c2 "${cp%:*}")"
	cb0=$(cbal isec-c2)
	ALL_CLN="isec-c"
	btx=$(lnd_breach isec-l s4b "$cp" isec-c2)
	ev "lnd's revoked commitment with the HTLC broadcast: $btx ($(K getrawtransaction "$btx" 1 | jq -c '[.vout[].value]'))"
	mine 1
	docker start isec-c2 >/dev/null
	ALL_CLN=$ALL_CLN_SAVE
	wait_for "isec-c2 RPC" 90 sh -c "docker exec isec-c2 lightning-cli --network=regtest --lightning-dir=/data getinfo"
	wait_for "isec-c2 at tip" 180 cln_at_tip isec-c2
	wait_for "CLN's penalty" 120 cln_penalty_logged isec-c2
	mine_until "CLN resolved" 150 cln_resolved_nudged isec-c2 "${cp%:*}"
	mine 3
	ev "CLN: $(docker logs isec-c2 2>&1 | grep -oE 'Resolved THEIR_REVOKED_UNILATERAL/[A-Z_]+ by our proposal OUR_PENALTY_TX' | sort | uniq -c | tr '\n' ';')"
	ev "penalty: $(justice_of "$btx" | tr '\n' ';')"
	ev "CLN wallet +$(( $(cbal isec-c2) - cb0 )) of 1000000"
	[ $(( $(cbal isec-c2) - cb0 )) -gt $(( 1000000 - 25000 )) ] || fail "CLN didn't take the channel and the HTLC"
	pass "4b: CLN swept $(( $(cbal isec-c2) - cb0 )) of 1000000, HTLC output included"
}

# lnd_splice LND CHAN_POINT in|out ARGS... -> the splice's txid once broadcast
lnd_splice() {
	local n=$1 cp=$2 dir=$3 log="/tmp/splice-$RANDOM.log"; shift 3
	docker exec -d "$n" sh -c "lncli --network=regtest --rpcserver=127.0.0.1:10009 splice $dir --chan_point $cp $* --sat_per_vbyte 2 > $log 2>&1"
	wait_for "splice broadcast" 90 sh -c "docker exec $n grep -q '\"broadcast\"' $log"
	! docker exec "$n" grep -q '"aborted"' "$log" || fail "splice aborted: $(docker exec "$n" cat "$log")"
	wait_for "pending splice listed" 30 sh -c "docker exec $n lncli --network=regtest listchannels | jq -e --arg c $cp '.channels[] | select(.channel_point == \$c or .original_chan_point == \$c) | .pending_splice.txid'"
	L "$n" listchannels | jq -r --arg c "$cp" '.channels[] | select(.channel_point == $c) | .pending_splice.txid'
}

# mine_with HEX...: a block holding these transactions, whatever the mempool
# holds; a mempool transaction they conflict with (the pending splice) drops out.
mine_with() {
	local arr; arr=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
	K generateblock "$(K -rpcwallet=lab getnewaddress)" "$arr" | jq -r .hash
	sync_all
}

restart_knots() {
	docker restart isec-knots >/dev/null
	wait_for "isec-knots up" 60 sh -c "docker exec isec-knots bitcoin-cli -datadir=/data -rpcuser=lab -rpcpassword=lab getblockchaininfo"
	K loadwallet lab >/dev/null 2>&1 || true
}

# cur_point LND PEER_PUB -> the channel point of the one channel with the peer
cur_point() { L "$1" listchannels | jq -r --arg p "$2" '.channels[] | select(.remote_pubkey == $p) | .channel_point'; }

# splice_locked LND PEER_PUB OLD_POINT: no pending splice and a new channel point
splice_locked() { L "$1" listchannels | jq -e --arg p "$2" --arg c "$3" '.channels[] | select(.remote_pubkey == $p) | select(.pending_splice == null and .channel_point != $c)' >/dev/null; }

# lnd_takes LND BREACH_TXID CAP BEFORE: the breach closed and swept
lnd_takes() {
	local n=$1 btx=$2 cap=$3 before=$4
	mine_until "$n breach closed" 40 sh -c "docker exec $n lncli --network=regtest closedchannels | jq -e --arg t $btx '.channels[] | select(.closing_tx_hash == \$t and .close_type == \"BREACH_CLOSE\")'"
	mine_until "$n resolved" 40 lnd_resolved "$n"
	mine 2
	ev "  justice: $(justice_of "$btx" | tr '\n' ';')"
	ev "  $n closed: $(L "$n" closedchannels | jq -c --arg t "$btx" '.channels[] | select(.closing_tx_hash == $t) | {channel_point, close_type, settled_balance, independent_secrets}')"
	local got; got=$(justice_of "$btx" | sed 's/.*out=//' | awk '{s+=$1} END {printf "%d", s*100000000 + 0.5}')
	ev "  justice outputs total $got of $cap"
	[ "$got" -gt $(( cap * 55 / 100 )) ] || fail "$n's justice took $got of $cap"
}

s5a() {
	step "5A. Core Lightning (non-shachain sender) breaches around lnd's splices; lnd punishes"
	fresh_chain
	start_lnd isec-l "$LND_IMAGE" --protocol.independent-secrets --protocol.splice
	local c
	for c in isec-c isec-c2 isec-c3; do start_cln $c --independent-secrets --dev-independent-secrets-sender; done
	mine 1; fund_lnd isec-l 1; fund_lnd isec-l 1; fund_lnd isec-l 1
	for c in isec-c isec-c2 isec-c3; do fund_cln $c 2; done
	mine 6
	local lp tx cp old stx btx i ln
	lp=$(lpub isec-l)
	for c in isec-c isec-c2 isec-c3; do connect_lc isec-l $c; done

	step "5A-i. a pre-splice revoked state, mined on the old funding output while lnd's splice-in is pending"
	tx=$(cln_open isec-c "$lp" 1000000)
	cp=$(L isec-l listchannels | jq -r --arg t "$tx" '.channels[] | select(.channel_point | startswith($t)) | .channel_point')
	pay_cl isec-l isec-c 200000
	old=$(signed_last isec-c "$lp")
	ev "pre-splice state of $cp captured ($(K decoderawtransaction "$old" | jq -r .txid)), lnd local $(lchan_by_point isec-l "$cp" | jq -r .local_balance)"
	for i in 1 2 3 4; do pay_cl isec-l isec-c 20000; pay_lc isec-l isec-c 1000; done
	stx=$(lnd_splice isec-l "$cp" in --amt 300000)
	ev "lnd's splice-in pending: $stx"
	for i in 1 2 3; do pay_cl isec-l isec-c 20000; pay_lc isec-l isec-c 1000; done
	ev "paid while pending: lnd local $(L isec-l listchannels | jq -r --arg c "$cp" '.channels[] | select(.channel_point == $c) | .local_balance'), splice $(L isec-l listchannels | jq -r --arg c "$cp" '.channels[] | select(.channel_point == $c) | .pending_splice.state')"
	btx=$(K decoderawtransaction "$old" | jq -r .txid)
	ev "block with the revoked commitment: $(mine_with "$old"); splice tx in mempool now: $(K getrawmempool | jq --arg t "$stx" 'index($t) != null')"
	lnd_takes isec-l "$btx" 1000000 0
	pass "5A-i: lnd punished a pre-splice state on the old funding"

	step "5A-ii. a revoked state signed while the splice was pending, on the old funding"
	tx=$(cln_open isec-c2 "$lp" 1000000)
	cp=$(L isec-l listchannels | jq -r --arg t "$tx" '.channels[] | select(.channel_point | startswith($t)) | .channel_point')
	pay_cl isec-l isec-c2 200000
	stx=$(lnd_splice isec-l "$cp" in --amt 300000)
	pay_cl isec-l isec-c2 10000
	old=$(C isec-c2 dev-sign-last-tx "$lp")
	ev "pending-splice state captured: commitment on the old funding $(echo "$old" | jq -r .tx | xargs -I{} docker exec isec-knots bitcoin-cli -datadir=/data -rpcuser=lab -rpcpassword=lab decoderawtransaction {} | jq -r .txid), inflights $(echo "$old" | jq -c '[.inflights[]?.funding_txid]')"
	old=$(echo "$old" | jq -r .tx)
	for i in 1 2 3; do pay_cl isec-l isec-c2 20000; pay_lc isec-l isec-c2 1000; done
	btx=$(K decoderawtransaction "$old" | jq -r .txid)
	ev "block with it: $(mine_with "$old")"
	lnd_takes isec-l "$btx" 1000000 0
	pass "5A-ii: lnd punished a state revoked during the splice"

	step "5A-iii. a revoked post-splice state on the new funding"
	tx=$(cln_open isec-c3 "$lp" 1000000)
	cp=$(L isec-l listchannels | jq -r --arg t "$tx" '.channels[] | select(.channel_point | startswith($t)) | .channel_point')
	pay_cl isec-l isec-c3 200000
	stx=$(lnd_splice isec-l "$cp" in --amt 300000)
	mine 6
	wait_for "splice locked" 120 splice_locked isec-l "$(cid isec-c3)" "$cp"
	ln=$(cur_point isec-l "$(cid isec-c3)")
	wait_for "CLN on the new funding" 60 sh -c "docker exec isec-c3 lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq -e --arg t ${ln%:*} '.channels[] | select(.funding_txid == \$t and .state == \"CHANNELD_NORMAL\")'"
	ev "splice locked: $cp -> $ln, capacity $(lchan_by_point isec-l "$ln" | jq -r .capacity)"
	for i in 1 2; do pay_cl isec-l isec-c3 20000; pay_lc isec-l isec-c3 1000; done
	old=$(signed_last isec-c3 "$lp")
	ev "post-splice state captured: spends $(K decoderawtransaction "$old" | jq -r '.vin[0] | "\(.txid):\(.vout)"')"
	for i in 1 2 3; do pay_cl isec-l isec-c3 20000; pay_lc isec-l isec-c3 1000; done
	btx=$(K sendrawtransaction "$old" 2>&1) || fail "Core Lightning's signed post-splice commitment is invalid: $btx"
	ev "post-splice revoked commitment broadcast: $btx"
	mine 1
	lnd_takes isec-l "$btx" 1300000 0
	pass "5A-iii: lnd punished a post-splice state"
}

# presplice_cln LND_IMAGE "LND_FLAGS" "CLN_FLAGS": on a fresh chain, lnd
# opens to Core Lightning, a copy of lnd's data is taken, payments, lnd
# splices out, payments while the splice is pending; then, with Core Lightning
# cut off from lnd only, lnd comes back on the copy and its revoked commitment
# is mined on the old funding output. Core Lightning must punish it.
presplice_cln() {
	local img=$1 lflags=$2 cflags=$3
	local cpub cp stx btx cb0 i addr
	fresh_chain
	start_lnd isec-l "$img" $lflags --protocol.splice
	start_cln isec-c $cflags
	mine 1; fund_lnd isec-l 2; fund_cln isec-c 1; mine 6
	connect_lc isec-l isec-c
	cpub=$(cid isec-c)
	cp=$(lnd_open isec-l "$cpub" 1000000)
	ev "channel $cp: lnd independent_secrets=$(lchan_by_point isec-l "$cp" | jq .independent_secrets), CLN $(cchan_by_txid isec-c "${cp%:*}" | jq -c .channel_type.names)"
	pay_lc isec-l isec-c 200000
	lnd_snapshot isec-l s5pre
	connect_lc isec-l isec-c
	wait_for "active" 60 sh -c "docker exec isec-l lncli --network=regtest listchannels --active_only | jq -e '.channels | length == 1'"
	for i in 1 2 3 4; do pay_lc isec-l isec-c 20000; pay_cl isec-l isec-c 1000; done
	# An address of a wallet that isn't loaded when the chain node restarts:
	# the lab wallet would put a splice paying it back in the mempool.
	K createwallet sink >/dev/null 2>&1 || K loadwallet sink >/dev/null
	addr=$(K -rpcwallet=sink getnewaddress "" bech32); K unloadwallet sink >/dev/null
	stx=$(lnd_splice isec-l "$cp" out --amt 200000 --addr "$addr")
	for i in 1 2 3; do pay_lc isec-l isec-c 20000; pay_cl isec-l isec-c 1000; done
	ev "splice-out $stx pending; CLN stores $(cstored isec-c "${cp%:*}") of lnd's secrets one by one; CLN state $(cchan_by_txid isec-c "${cp%:*}" | jq -r .state)"
	cb0=$(cbal isec-c)
	# Core Lightning reaches the chain over a network lnd isn't on.
	docker network create isec-aux >/dev/null 2>&1 || true
	docker network connect isec-aux isec-knots 2>/dev/null || true
	docker network connect isec-aux isec-c
	docker network disconnect $N isec-c
	docker stop isec-l >/dev/null
	restart_knots
	[ "$(K getrawmempool | jq length)" = 0 ] || fail "the splice is still in the mempool"
	restore_vol isec-l s5pre
	docker start isec-l >/dev/null
	wait_for "isec-l RPC" 90 sh -c "docker exec isec-l lncli --network=regtest getinfo"
	wait_for "isec-l at tip" 180 lnd_at_tip isec-l
	L isec-l closechannel --force --chan_point "$cp" >/dev/null
	wait_for "force close in the mempool" 60 sh -c "docker exec isec-knots bitcoin-cli -datadir=/data -rpcuser=lab -rpcpassword=lab getrawmempool | jq -e 'length > 0'"
	btx=$(L isec-l pendingchannels | jq -r --arg c "$cp" '.waiting_close_channels[] | select(.channel.channel_point == $c) | .closing_txid')
	# Mined at once, before anyone can replace it with the splice.
	K generateblock "$(K -rpcwallet=lab getnewaddress)" "[\"$btx\"]" >/dev/null
	ev "lnd's pre-splice revoked commitment $btx mined, spending $(K getrawtransaction "$btx" 1 | jq -r '.vin[0] | "\(.txid):\(.vout)"')"
	sync_all
	for i in $(seq 1 12); do
		cln_penalty_logged isec-c && break
		sleep 5; mine 1
	done
	cln_penalty_logged isec-c || fail "no penalty from Core Lightning: $(cchan_by_txid isec-c "${cp%:*}" | jq -c '{state, status}')"
	mine_until "CLN resolved" 150 cln_resolved_nudged isec-c "${cp%:*}"
	mine 3
	ev "  CLN: $(docker logs isec-c 2>&1 | grep -oE 'Resolved THEIR_REVOKED_UNILATERAL/[A-Z_]+ by our proposal OUR_PENALTY_TX' | sort | uniq -c | tr '\n' ';')"
	ev "  penalty: $(justice_of "$btx" | tr '\n' ';'); CLN wallet +$(( $(cbal isec-c) - cb0 )) of 1000000"
	[ $(( $(cbal isec-c) - cb0 )) -gt $(( 1000000 - 20000 )) ] || fail "CLN didn't take the channel"
}

s5b() {
	step "5B. lnd (non-shachain sender) breaches around its splices; Core Lightning punishes"

	step "5B-i. a pre-splice revoked state on the old funding while lnd's splice-out is pending"
	presplice_cln "$LND_INT_IMAGE" "$INT" "--independent-secrets"
	pass "5B-i: CLN punished a pre-splice state on the old funding"

	step "5B-ii. a revoked post-splice state on the new funding"
	fresh_chain
	start_lnd isec-l "$LND_INT_IMAGE" $INT --protocol.splice
	start_cln isec-c2 --independent-secrets
	mine 1; fund_lnd isec-l 2; fund_lnd isec-l 1; fund_cln isec-c2 1; mine 6
	local cpub cp stx btx cb0 i ln
	cpub=$(cid isec-c2)
	connect_lc isec-l isec-c2
	cp=$(lnd_open isec-l "$cpub" 1000000)
	pay_lc isec-l isec-c2 200000
	stx=$(lnd_splice isec-l "$cp" in --amt 300000)
	mine 6
	wait_for "splice locked" 120 splice_locked isec-l "$cpub" "$cp"
	ln=$(cur_point isec-l "$cpub")
	wait_for "CLN on the new funding" 60 sh -c "docker exec isec-c2 lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq -e --arg t ${ln%:*} '.channels[] | select(.funding_txid == \$t and .state == \"CHANNELD_NORMAL\")'"
	ev "splice locked: $cp -> $ln"
	pay_lc isec-l isec-c2 20000
	lnd_snapshot isec-l s5bii
	connect_lc isec-l isec-c2
	wait_for "active" 60 sh -c "docker exec isec-l lncli --network=regtest listchannels --active_only | jq -e '.channels | length == 1'"
	for i in 1 2 3 4; do pay_lc isec-l isec-c2 20000; pay_cl isec-l isec-c2 1000; done
	cb0=$(cbal isec-c2)
	btx=$(lnd_breach isec-l s5bii "$ln" isec-c2)
	ev "lnd's post-splice revoked commitment broadcast: $btx (spends $(K getrawtransaction "$btx" 1 | jq -r '.vin[0] | "\(.txid):\(.vout)"'))"
	mine 1
	docker start isec-c2 >/dev/null
	wait_for "isec-c2 RPC" 90 sh -c "docker exec isec-c2 lightning-cli --network=regtest --lightning-dir=/data getinfo"
	wait_for "isec-c2 at tip" 180 cln_at_tip isec-c2
	wait_for "CLN's penalty" 120 cln_penalty_logged isec-c2
	mine_until "CLN resolved" 150 cln_resolved_nudged isec-c2 "${ln%:*}"
	mine 3
	ev "  CLN: $(docker logs isec-c2 2>&1 | grep -oE 'Resolved THEIR_REVOKED_UNILATERAL/[A-Z_]+ by our proposal OUR_PENALTY_TX' | sort | uniq -c | tr '\n' ';')"
	ev "  penalty: $(justice_of "$btx" | tr '\n' ';'); CLN wallet +$(( $(cbal isec-c2) - cb0 )) of 1300000"
	[ $(( $(cbal isec-c2) - cb0 )) -gt $(( 1300000 - 20000 )) ] || fail "CLN didn't take the channel"
	pass "5B-ii: CLN punished a post-splice state"
}

# 5D: lnd restarts while its splice is pending, then Core Lightning (the
# non-shachain sender) mines a pre-splice revoked state on the old funding.
s5d() {
	step "5D. lnd restarted while its splice is pending; Core Lightning breaches on the old funding"
	fresh_chain
	start_lnd isec-l "$LND_IMAGE" --protocol.independent-secrets --protocol.splice
	start_cln isec-c --independent-secrets --dev-independent-secrets-sender
	mine 1; fund_lnd isec-l 1; fund_lnd isec-l 1; fund_cln isec-c 2; mine 6
	connect_lc isec-l isec-c
	local lp tx cp old stx btx i
	lp=$(lpub isec-l)
	tx=$(cln_open isec-c "$lp" 1000000)
	cp=$(L isec-l listchannels | jq -r --arg t "$tx" '.channels[] | select(.channel_point | startswith($t)) | .channel_point')
	pay_cl isec-l isec-c 200000
	old=$(signed_last isec-c "$lp")
	for i in 1 2 3; do pay_cl isec-l isec-c 20000; pay_lc isec-l isec-c 1000; done
	stx=$(lnd_splice isec-l "$cp" in --amt 300000)
	restart_lnd isec-l
	connect_lc isec-l isec-c
	ev "lnd restarted with splice $stx pending: $(L isec-l listchannels | jq -c '.channels[0] | {channel_point, pending: .pending_splice.state, active}')"
	for i in 1 2 3; do pay_cl isec-l isec-c 20000; pay_lc isec-l isec-c 1000; done
	btx=$(K decoderawtransaction "$old" | jq -r .txid)
	ev "block with the revoked commitment $btx: $(mine_with "$old")"
	lnd_takes isec-l "$btx" 1000000 0
	pass "5D: lnd punished a pre-splice state after restarting with the splice pending"
}
s5() { s5a; s5b; s5d; }

backups_settled() { L "$1" wtclient stats | jq -e '.num_pending_backups == 0' >/dev/null; }
tower_up() { L isec-t tower info | jq -e '.uris | length > 0' >/dev/null; }

s6() {
	step "6. lnd victim offline, an lnd tower punishes for it"
	fresh_chain
	start_lnd isec-t "$LND_IMAGE" --watchtower.active --watchtower.listen=0.0.0.0:9911 --watchtower.externalip=isec-t:9911
	start_lnd isec-v "$LND_IMAGE" --protocol.independent-secrets --wtclient.active
	start_lnd isec-x "$LND_INT_IMAGE" $INT
	start_cln isec-c --independent-secrets --dev-independent-secrets-sender
	mine 1
	wait_for "tower" 60 tower_up
	L isec-v wtclient add "$(L isec-t tower info | jq -r '.uris[0]')" >/dev/null
	fund_lnd isec-v 1; fund_lnd isec-x 2; fund_cln isec-c 2; mine 6
	local vp tx cp old btx vb0 i ses
	vp=$(lpub isec-v)

	step "6a. Core Lightning (non-shachain sender) cheats"
	connect_lc isec-v isec-c
	tx=$(cln_open isec-c "$vp" 1000000)
	cp=$(L isec-v listchannels | jq -r --arg t "$tx" '.channels[] | select(.channel_point | startswith($t)) | .channel_point')
	lchan_by_point isec-v "$cp" | jq -e .independent_secrets >/dev/null || fail "no add-on"
	pay_cl isec-v isec-c 200000
	old=$(signed_last isec-c "$vp")
	for i in $(seq 1 8); do pay_cl isec-v isec-c 20000; pay_lc isec-v isec-c 1000; done
	wait_for "backups settled" 60 backups_settled isec-v
	ev "victim's backups: $(L isec-v wtclient stats | jq -c .); towers: $(L isec-v wtclient towers | jq -c '[.towers[] | {active_session_candidate, num_sessions}]' 2>/dev/null)"
	[ "$(L isec-v wtclient stats | jq -r .num_backups)" -gt 10 ] || fail "too few backups"
	docker stop isec-v >/dev/null
	btx=$(K sendrawtransaction "$old")
	ev "victim down; Core Lightning's revoked commitment broadcast: $btx ($(K getrawtransaction "$btx" 1 | jq -c '[.vout[].value]'))"
	mine 1
	wait_for "the tower's justice" 120 sh -c "docker logs isec-t 2>&1 | grep -q 'breach-txid=$btx dispatched'"
	mine 1
	ev "  tower justice: $(justice_of "$btx" | tr '\n' ';')"
	ev "  tower log: $(docker logs isec-t 2>&1 | grep -iE 'WTWR.*(breach|justice|Publish)' | tail -3 | cut -c1-220 | tr '\n' '|')"
	local got; got=$(justice_of "$btx" | sed 's/.*out=//' | awk '{s+=$1} END {printf "%d", s*100000000 + 0.5}')
	[ "$got" -gt 500000 ] || fail "the tower's justice took $got"
	docker start isec-v >/dev/null
	wait_for "isec-v RPC" 90 sh -c "docker exec isec-v lncli --network=regtest getinfo"
	mine 3
	mine_until "victim resolved" 40 lnd_resolved isec-v
	ev "  victim back: $(L isec-v closedchannels | jq -c --arg c "$cp" '.channels[] | select(.channel_point == $c) | {close_type, settled_balance, independent_secrets}'); wallet $(lbal isec-v)"
	pass "6a: the tower took $got sat of the cheater's commitment for the offline victim"

	step "6b. lnd (non-shachain sender) cheats"
	connect_ll isec-x isec-v 2>/dev/null || true
	docker start isec-v >/dev/null 2>&1 || true
	connect_ll isec-x isec-v
	cp=$(lnd_open isec-x "$vp" 1000000)
	lchan_by_point isec-v "$cp" | jq -e .independent_secrets >/dev/null || fail "no add-on"
	pay_ll isec-x isec-v 200000
	lnd_snapshot isec-x s6b
	connect_ll isec-x isec-v
	wait_for "active" 60 sh -c "docker exec isec-x lncli --network=regtest listchannels --active_only | jq -e '.channels | length == 1'"
	for i in $(seq 1 8); do pay_ll isec-x isec-v 20000; pay_ll isec-v isec-x 1000; done
	wait_for "backups settled" 60 backups_settled isec-v
	ev "victim's backups: $(L isec-v wtclient stats | jq -c .)"
	btx=$(lnd_breach isec-x s6b "$cp" isec-v)
	ev "victim down; lnd's revoked commitment broadcast: $btx ($(K getrawtransaction "$btx" 1 | jq -c '[.vout[].value]'))"
	mine 1
	wait_for "the tower's justice" 120 sh -c "docker logs isec-t 2>&1 | grep -q 'breach-txid=$btx dispatched'"
	mine 1
	ev "  tower justice: $(justice_of "$btx" | tr '\n' ';')"
	got=$(justice_of "$btx" | sed 's/.*out=//' | awk '{s+=$1} END {printf "%d", s*100000000 + 0.5}')
	[ "$got" -gt 500000 ] || fail "the tower's justice took $got"
	pass "6b: the tower took $got sat of the cheater's commitment for the offline victim"
}

s7() {
	step "7. a peer setting 266 in init"
	fresh_chain
	start_lnd isec-bad "$LND_REL_IMAGE" --protocol.custom-init=266
	start_lnd isec-lon "$LND_IMAGE" --protocol.independent-secrets
	start_lnd isec-loff "$LND_IMAGE"
	start_cln isec-con --independent-secrets
	start_cln isec-coff
	mine 1
	ev "isec-bad (.21, custom-init=266) init bits: $(feat_bits isec-bad)"
	feat_bits isec-bad | jq -e 'index(266)' >/dev/null || fail "release didn't set 266"
	local t out
	for t in isec-lon isec-loff; do
		out=$(L isec-bad connect "$(lpub $t)@$t:9735" 2>&1 || true); sleep 3
		ev "$t: connect -> $(echo "$out" | tr -d '\n' | cut -c1-160); peers: $(L $t listpeers | jq '.peers | length'); log: $(docker logs $t 2>&1 | grep -iE 'even bit|266|independent' | grep -v 'Version Info' | tail -1 | cut -c1-200)"
		[ "$(L $t listpeers | jq '.peers | length')" = 0 ] || fail "$t kept a peer setting 266"
	done
	for t in isec-con isec-coff; do
		out=$(L isec-bad connect "$(cid $t)@$t:9735" 2>&1 || true); sleep 3
		ev "$t: connect -> $(echo "$out" | tr -d '\n' | cut -c1-160); peers: $(C $t listpeers | jq '[.peers[] | select(.connected)] | length'); log: $(docker logs $t 2>&1 | grep -iE '266|independent|feature' | grep -v 'preinit\|dev_' | tail -1 | cut -c1-200)"
	done
	# bolts#17: a node receiving init with 266 set MUST close the
	# connection, whether or not it offers the option.
	for t in isec-con isec-coff; do
		[ "$(C $t listpeers | jq '[.peers[] | select(.connected)] | length')" = 0 ] || fail "$t kept a peer setting 266"
	done
	pass "7: lnd and Core Lightning, with the option on or off, refuse a peer with 266 in init"
}

case_list=${*:-1 2 3 4 5 6 7}
for s in $case_list; do
	"s$s"
done
[ -n "${KEEP:-}" ] || cleanup_all
echo "independent-secrets: done ($case_list)"
