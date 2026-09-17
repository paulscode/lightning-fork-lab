#!/usr/bin/env bash
# Mine blocks with plausible timestamps on both chains.
#
# The bridge sizes every HTLC against how fast each chain is running, measured
# from block timestamps. Regtest mines on demand, so a burst of blocks all
# carry nearly the same timestamp and read as a chain running thousands of
# times too fast, which makes the bridge refuse every swap for a reason that
# has nothing to do with the swap.
#
# setmocktime advances the clock between blocks so the observer sees spacing
# that looks like a real chain. Nothing here stubs the bridge: it measures
# these blocks with the same code it would use on mainnet.
set -euo pipefail

COMPOSE="docker compose"
COUNT="${COUNT:-120}"
SPACING="${SPACING:-600}"

b2b() {
    $COMPOSE exec -T knots-b2b bitcoin-cli -regtest -rpcuser=lab \
        -rpcpassword=lab "$@"
}
sha() {
    $COMPOSE exec -T bitcoind-sha bitcoin-cli -regtest -rpcuser=lab \
        -rpcpassword=lab "$@"
}

b2b_addr=$(b2b -rpcwallet=miner getnewaddress 2>/dev/null \
    || b2b getnewaddress)
sha_addr=$(sha -rpcwallet=miner getnewaddress 2>/dev/null \
    || sha getnewaddress)

# Forward from whatever each chain already has, not backward from now.
# Bringing the lab up mines blocks stamped with the real clock, so a sequence
# ending at now would have to start before them, and bitcoind refuses a block
# more than two hours ahead of its own idea of the time. Going forward keeps
# every block exactly at the clock it is mined under.
#
# The clock is deliberately left where this leaves it. Everything downstream
# reads block timestamps, so it stays self-consistent, and resetting to the
# real time would put later blocks behind the chain they extend.
b2b_tip=$(b2b getblockheader "$(b2b getbestblockhash)" | jq -r .time)
sha_tip=$(sha getblockheader "$(sha getbestblockhash)" | jq -r .time)

echo "Mining $COUNT blocks on each chain, ${SPACING}s apart..."
for i in $(seq 1 "$COUNT"); do
    b2b setmocktime $((b2b_tip + i * SPACING)) >/dev/null
    sha setmocktime $((sha_tip + i * SPACING)) >/dev/null
    b2b generatetoaddress 1 "$b2b_addr" >/dev/null
    sha generatetoaddress 1 "$sha_addr" >/dev/null
done

echo "BLAKE2b at $(b2b getblockcount), SHA256 at $(sha getblockcount)"
