#!/usr/bin/env bash
# Does a watchtower client only use towers that follow the BLAKE2b rules?
#
# A tower and its client learn each other's chain only from the genesis hash
# in the watchtower Init message, which the BLAKE2b chain shares with Bitcoin
# nodes that have not upgraded. Up to .13 a Lightning Fork client opened
# sessions with a stock SHA256d tower, which then watched a chain where the
# breaches it guards against never appear. From .14 every tower and client
# of the fork sets an even bit 512 in its Init, and refuses a peer that sets
# neither 512 nor 513.
#
#   1. a fork tower and a fork client on the new build: a session
#   2. a stock lnd tower, and a fork tower on the previous release, each
#      with a client on the new build: no session
#   3. a stock lnd client with a tower on the new build: no session
#   4. the problem, as a control: a client on the previous release with a
#      stock tower gets a session, which also shows the harness sees them
#
# NEW_IMAGE is the build under test; OLD_IMAGE the previous fork release;
# STOCK_IMAGE a stock lnd, run against the lab's SHA256d regtest.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/lib.sh

N=$(docker network ls --format '{{.Name}}' | grep -m1 lightning-fork-lab)
NEW_IMAGE=${NEW_IMAGE:-lightning-fork:dev}
OLD_IMAGE=${OLD_IMAGE:-paulscode/lightning-fork:0.21.3-beta-blake2b.13}
STOCK_IMAGE=${STOCK_IMAGE:-lightninglabs/lnd:v0.21.3-beta}
P=wt
# One client per tower it is given: a client that already holds a session
# does not go looking for another tower, so it would never try the second.
ALL="$P-tower-new $P-tower-old $P-tower-stock $P-client-new $P-client-new2 $P-client-new3 $P-client-old $P-client-stock"

exec 9>/tmp/scenario-watchtower.lock
flock -n 9 || fail "another run of this scenario holds the lock"

cleanup() {
	local rc=$?
	if [ "$rc" != 0 ]; then
		for n in $ALL; do
			echo "=== $n (last 10) ==="
			docker logs "$n" 2>&1 | tail -10 || true
		done
	fi
	# KEEP leaves the nodes up after the run, for inspection.
	[ -z "${KEEP:-}" ] || return 0
	docker rm -f $ALL >/dev/null 2>&1 || true
	for n in $ALL; do docker volume rm -f "$n-data" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

# start NAME IMAGE CHAIN(b2b|sha) ROLE(tower|client)
start() {
	local name=$1 image=$2 chain=$3 role=$4 backend
	if [ "$chain" = b2b ]; then
		backend=(
			--bitcoin.blake2b-activation-height="${ACTIVATION_HEIGHT:-20}"
			--fee.url=http://fees:8080/fees.json
			--bitcoind.rpchost=knots-b2b:18443
			--bitcoind.zmqpubrawblock=tcp://knots-b2b:28332
			--bitcoind.zmqpubrawtx=tcp://knots-b2b:28333
		)
	else
		backend=(
			--bitcoind.rpchost=bitcoind-sha:18443
			--bitcoind.zmqpubrawblock=tcp://bitcoind-sha:28332
			--bitcoind.zmqpubrawtx=tcp://bitcoind-sha:28333
		)
	fi
	local roleargs=(--wtclient.active)
	[ "$role" = tower ] && roleargs=(--watchtower.active
		--watchtower.listen=0.0.0.0:9911
		--watchtower.externalip="$name":9911)
	docker volume rm -f "$name-data" >/dev/null 2>&1 || true
	docker run -d --name "$name" --network "$N" -v "$name-data:/root/.lnd" \
		"$image" --noseedbackup --bitcoin.regtest --bitcoin.node=bitcoind \
		--bitcoind.rpcuser=lab --bitcoind.rpcpass=lab "${backend[@]}" \
		--rpclisten=0.0.0.0:10009 --listen=0.0.0.0:9735 \
		--tlsextradomain="$name" --alias="$name" \
		"${roleargs[@]}" --debuglevel=info,WTCL=debug,WTWR=debug >/dev/null
}

cli() {
	local name=$1; shift
	timeout 90 docker exec "$name" lncli --network=regtest --rpcserver=127.0.0.1:10009 "$@"
}

# up NAME CHAIN: lnd serves the wtclient and tower RPCs only once it has
# started in full, which waits for a synced chain; an idle lab chain's tip is
# too old for that, so blocks are mined while waiting.
up() {
	local name=$1 chain=$2
	for i in $(seq 1 60); do
		docker exec "$name" lncli --network=regtest --rpcserver=127.0.0.1:10009 \
			getinfo 2>/dev/null | grep -Eq '"synced_to_chain": +true' && return 0
		if [ "$chain" = b2b ]; then
			mine_b2b 1 >/dev/null 2>&1 || true
		else
			mine_sha 1
		fi
		sleep 5
	done
	fail "$name never synced"
}

mine_sha() {
	local addr
	addr=$(docker exec lightning-fork-lab-bitcoind-sha-1 bitcoin-cli -regtest \
		-rpcuser=lab -rpcpassword=lab getnewaddress 2>/dev/null) ||
		addr=bcrt1q0000000000000000000000000000000000000000
	docker exec lightning-fork-lab-bitcoind-sha-1 bitcoin-cli -regtest \
		-rpcuser=lab -rpcpassword=lab generatetoaddress "$1" "$addr" \
		>/dev/null 2>&1 || true
}

tower_uri() {
	cli "$1" tower info | jq -r '.uris[0] // empty'
}

# sessions CLIENT TOWER_PUB -> the number of sessions the client holds with it
sessions() {
	cli "$1" wtclient tower --include_sessions "$2" 2>/dev/null |
		jq -r '[([.session_info[]?.sessions[]?] | length), (.sessions // [] | length)] | max' 2>/dev/null || echo 0
}

# add CLIENT TOWER: give the client the tower's URI.
add() {
	local uri
	uri=$(tower_uri "$2")
	[ -n "$uri" ] || fail "$2 reports no tower URI"
	cli "$1" wtclient add "$uri" >/dev/null 2>&1 || true
}

# count CLIENT TOWER -> sessions the client holds with the tower
count() {
	local uri
	uri=$(tower_uri "$2")
	sessions "$1" "${uri%@*}"
}

# refused CLIENT TOWER -> yes if either side logged a refusal over the bit.
# A zero count alone could mean the client has not got round to trying.
refused() {
	local c t
	c=$(cli "$1" getinfo | jq -r .identity_pubkey)
	t=$(tower_uri "$2"); t=${t%@*}
	# Counted, not grep -q: under pipefail an early exit fails the pipe.
	local pat='unknown required features: \[512\]|blake2b bit' n1 n2
	n1=$(docker logs "$1" 2>&1 | grep -F "$t" | grep -cE "$pat" || true)
	n2=$(docker logs "$2" 2>&1 | grep -F "$c" | grep -cE "$pat" || true)
	if [ "${n1:-0}" -gt 0 ] || [ "${n2:-0}" -gt 0 ]; then
		echo yes
	else
		echo no
	fi
}

# wait_refused CLIENT TOWER -> yes once a refusal is logged, no after a minute
wait_refused() {
	local r=no
	for i in $(seq 1 12); do
		r=$(refused "$1" "$2")
		[ "$r" = yes ] && break
		sleep 5
	done
	echo "$r"
}

step "watchtower: start towers and clients"
start $P-tower-new "$NEW_IMAGE" b2b tower
start $P-tower-old "$OLD_IMAGE" b2b tower
start $P-tower-stock "$STOCK_IMAGE" sha tower
start $P-client-new "$NEW_IMAGE" b2b client
start $P-client-new2 "$NEW_IMAGE" b2b client
start $P-client-new3 "$NEW_IMAGE" b2b client
start $P-client-old "$OLD_IMAGE" b2b client
start $P-client-stock "$STOCK_IMAGE" sha client
for n in $P-tower-new $P-tower-old $P-client-new $P-client-new2 $P-client-new3 $P-client-old; do up $n b2b; done
for n in $P-tower-stock $P-client-stock; do up $n sha; done
for n in $ALL; do echo "  $n: $(cli $n getinfo | jq -r .version)"; done

step "watchtower: every client is given its towers at once"
# The session negotiator backs off while it has no tower, up to minutes, so
# the towers go in before it has waited long.
add $P-client-new $P-tower-new
add $P-client-new2 $P-tower-stock
add $P-client-new3 $P-tower-old
add $P-client-stock $P-tower-new
add $P-client-old $P-tower-stock
new_new=0
old_stock=0
for i in $(seq 1 60); do
	new_new=$(count $P-client-new $P-tower-new)
	old_stock=$(count $P-client-old $P-tower-stock)
	[ "${new_new:-0}" -ge 1 ] && [ "${old_stock:-0}" -ge 1 ] && break
	sleep 5
done

step "watchtower: 1. a tower and a client on the new build"
echo "  sessions: $new_new"

step "watchtower: 2. a client on the new build, and towers that do not set the bit"
new_stock=$(count $P-client-new2 $P-tower-stock)
new_stock_refused=$(wait_refused $P-client-new2 $P-tower-stock)
echo "  with a stock tower: $new_stock sessions, refused over the bit: $new_stock_refused"
new_old=$(count $P-client-new3 $P-tower-old)
new_old_refused=$(wait_refused $P-client-new3 $P-tower-old)
echo "  with a tower on the previous release: $new_old sessions, refused over the bit: $new_old_refused"

step "watchtower: 3. a stock client and a tower on the new build"
stock_new=$(count $P-client-stock $P-tower-new)
stock_new_refused=$(wait_refused $P-client-stock $P-tower-new)
echo "  sessions: $stock_new, refused over the bit: $stock_new_refused"

step "watchtower: 4. the control: a client on the previous release and a stock tower"
echo "  sessions: $old_stock (the problem .14 closes)"

step "watchtower: verdict"
# The control must show the problem, or the harness is not seeing sessions.
if [ "$new_new" -ge 1 ] && [ "$old_stock" -ge 1 ] &&
	[ "$new_stock" = 0 ] && [ "$new_stock_refused" = yes ] &&
	[ "$new_old" = 0 ] && [ "$new_old_refused" = yes ] &&
	[ "$stock_new" = 0 ] && [ "$stock_new_refused" = yes ]; then
	echo "PASS"
else
	echo "FAIL: new/new=$new_new old/stock=$old_stock new/stock=$new_stock($new_stock_refused) new/old=$new_old($new_old_refused) stock/new=$stock_new($stock_new_refused)"
	exit 1
fi
