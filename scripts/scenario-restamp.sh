#!/usr/bin/env bash
# What still refuses a wallet carried between the two chains, once chain_hash
# is the genesis hash both chains share?
#
# This started as an experiment to support a claim: that the reversal makes
# Core Lightning's restamp check more load-bearing, because the wallet's own
# recorded history is the only thing left that can tell the chains apart. The
# experiment said otherwise, and the result is worth keeping as a scenario
# rather than a note, because the conclusion is the opposite of the intuition.
#
# The restamp check is reached only through this gate (wallet_sanity_check):
#
#     wallet_stamp != chain_hash && block0 != chain_hash && wallet_stamp == block0
#
# so it fires only for a wallet stamped with block 0 on a build whose
# chain_hash is something other than block 0. That is a migration path off the
# old synthetic chain_hash, not a standing guard. The reversal sets
# chain_hash = block0, which closes the middle clause permanently: after it,
# no wallet can reach the check at all.
#
# Below: part 1 shows the gate closed, which is every wallet's situation after
# the reversal. Part 2 forces it open and shows what is behind it. Part 3 names
# the check that does work, which is in Lightning Fork and is exercised by
# scenario-e4b-refuse.sh.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/lib.sh

N=$(docker network ls --format '{{.Name}}' | grep -m1 lightning-fork-lab)
NODE=cln-restamp
# The patched image on purpose, unlike the other scenarios here, which use
# cln-vanilla:lab. The subject is the restamp check, and the restamp check is
# part of my chain-identity series, so the build under test has to carry it.
# Nothing below peers with another node, so the fact that this image can no
# longer peer with lf1 does not matter here.
IMG=cln-unified-run:asis
DB=/data/regtest/lightningd.sqlite3

# Regtest's block 0, in the byte order the wallet stores it (bitcoin/chainparams.c
# .block0_hash for the regtest entry, which is the reverse of the displayed id
# 0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206).
BLOCK0=06226E46111A0B59CAAF126043EB5BBF28C34F3A5E332A1FC7B2B73CF188910F

docker rm -f $NODE >/dev/null 2>&1 || true
docker volume rm -f $NODE-data >/dev/null 2>&1 || true

start_against() {
	docker run -d --name $NODE --network "$N" -v "$NODE-data:/data" "$IMG" \
		--network=regtest --lightning-dir=/data \
		--bitcoin-rpcconnect="$1" --bitcoin-rpcport=18443 \
		--bitcoin-rpcuser=lab --bitcoin-rpcpassword=lab \
		--bind-addr=0.0.0.0:9735 --alias=$NODE --log-level=debug \
		--disable-plugin=cln-grpc --disable-plugin=clnrest \
		--disable-plugin=cln-bip353 "${@:2}" >/dev/null
}

cli() { docker exec $NODE lightning-cli --network=regtest --lightning-dir=/data "$@"; }

# sql STATEMENT: run one statement against the stopped wallet.
sql() {
	docker run --rm -v "$NODE-data:/data" alpine sh -c \
		"apk add -q sqlite && sqlite3 $DB \"$1\""
}

up() {
	wait_for "$NODE up" 180 sh -c \
		"docker exec $NODE lightning-cli --network=regtest --lightning-dir=/data getinfo >/dev/null 2>&1"
}

step "restamp: the other chain must be at least as tall, or there is nothing
      for a height comparison to disagree about"
b2b_h=$(b2b getblockcount)
sha_h=$(sha getblockcount)
if [ "$sha_h" -le "$b2b_h" ]; then
	addr=$(sha -rpcwallet=lab getnewaddress)
	sha generatetoaddress $(( b2b_h - sha_h + 20 )) "$addr" >/dev/null
fi
echo "  BLAKE2b at $(b2b getblockcount), SHA256d at $(sha getblockcount)"

step "restamp 1: sync a wallet on the BLAKE2b chain"
start_against knots-b2b
up
for i in $(seq 1 30); do
	h=$(cli getinfo | jq -r .blockheight)
	[ "$h" = "$(b2b getblockcount)" ] && break
	sleep 5
done
synced_at=$(cli getinfo | jq -r .blockheight)
[ "$synced_at" = "$(b2b getblockcount)" ] ||
	fail "wallet stopped at $synced_at, BLAKE2b is at $(b2b getblockcount)"
echo "  wallet followed the BLAKE2b chain to height $synced_at"
record restamp synced_height "$synced_at"

docker stop $NODE >/dev/null 2>&1; docker rm $NODE >/dev/null 2>&1

# The stamp this build writes is its own chain_hash, not block 0, so the gate
# above is already closed before the wallet goes anywhere near another chain.
stamp=$(sql "SELECT hex(blobval) FROM vars WHERE name='genesis_hash';")
echo "  wallet is stamped $stamp"
[ "$stamp" != "$BLOCK0" ] ||
	fail "wallet is stamped with block 0; this build was expected to stamp its own chain_hash"
record restamp stamp_written "$stamp"

step "restamp 1: start the same wallet against the SHA256d chain"
start_against bitcoind-sha
up
sleep 10
followed=$(cli getinfo | jq -r .blockheight)
refused=no
if docker logs $NODE 2>&1 | grep -qiE "followed another chain|followed the SHA256d chain"; then
	refused=yes
fi
echo "  refused: $refused, wallet is now at height $followed (SHA256d is at $(sha getblockcount))"
record restamp refused_other_chain "$refused"
record restamp followed_height "$followed"

[ "$refused" = no ] ||
	fail "a refusal appeared where the gate should have been closed; re-read wallet_sanity_check"
[ "$followed" = "$(sha getblockcount)" ] ||
	fail "wallet did not follow the SHA256d chain to its tip, so this says less than it looks"
pass "the wallet adopted the other chain's blocks without complaint: nothing in
      the chain identity separates them, and the restamp gate never opened"

step "restamp 2: force the gate open, by stamping the wallet the way a
      pre-change wallet is stamped"
docker rm -f $NODE >/dev/null 2>&1 || true
sql "UPDATE vars SET blobval = x'$BLOCK0' WHERE name='genesis_hash';" >/dev/null
start_against knots-b2b
sleep 20
state=$(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}}' $NODE)
echo "  $state"
msg=$(docker logs $NODE 2>&1 | grep -iE "stamped with block 0" | tail -1)
echo "  ${msg:-(no message)}"
[ -n "$msg" ] || fail "the gate did not open for a wallet stamped with block 0"
record restamp gate_opens yes

# On regtest chain_hash_block_height is 0, so wallet_followed_this_chain()
# returns straight away without an answer and settle_deferred_restamp() finds
# no block above height 0 to ask about. The history comparison the reply draft
# leaned on is reachable on mainnet only. The message says so itself.
echo "$msg" | grep -q "holds no block above height 0" ||
	fail "expected the wallet to be unable to answer on regtest; message was: $msg"
pass "the check behind the gate cannot answer here: chain_hash_block_height is
      0 on every network but mainnet, so the history comparison is mainnet-only"
record restamp history_check_reachable_on_regtest no

step "restamp: verdict"
cat <<'EOF'
  The restamp check is a migration off the old synthetic chain_hash, not a
  standing guard against a wallet carried between chains:

    - its gate needs chain_hash to differ from block 0, which the reversal
      makes false, so after the reversal no wallet reaches it;
    - the history comparison behind the gate is mainnet-only;
    - with the gate closed, a synced wallet pointed at the other chain's
      backend rescans it from blockscan_start and says nothing.

  What does refuse is a backend check rather than a wallet check, and it does
  not use chain_hash at all: Lightning Fork reads the header at the activation
  height and refuses an 80-byte one. See scenario-e4b-refuse.sh.
EOF
echo "PASS"
