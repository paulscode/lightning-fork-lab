#!/usr/bin/env bash
# Shared helpers for the lab scenarios. Source this file.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LAB_DIR"
mkdir -p results
export ACTIVATION_HEIGHT="${ACTIVATION_HEIGHT:-20}"

COMPOSE="docker compose"

b2b()   { $COMPOSE exec -T knots-b2b bitcoin-cli -datadir=/data -rpcuser=lab -rpcpassword=lab "$@"; }
sha()   { $COMPOSE exec -T bitcoind-sha bitcoin-cli -regtest -rpcuser=lab -rpcpassword=lab -rpcconnect=127.0.0.1 -rpcport=18443 "$@"; }
lncli_on() { local svc=$1; shift; $COMPOSE exec -T "$svc" lncli --network=regtest --rpcserver=127.0.0.1:10009 "$@"; }
lf1()   { lncli_on lf1 "$@"; }
lf2()   { lncli_on lf2 "$@"; }
lndsha(){ lncli_on lnd-sha "$@"; }

# status_file SERVICE -> prints the chain-identity.json of a Lightning Fork
# container, or nothing if it does not exist yet.
status_file() {
    $COMPOSE exec -T "$1" sh -c 'cat /root/.lnd/data/chain/bitcoin/regtest/chain-identity.json 2>/dev/null' || true
}

status_state() { status_file "$1" | jq -r '.state // empty' 2>/dev/null || true; }

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

# wait_for DESCRIPTION SECONDS COMMAND... : polls until the command succeeds.
wait_for() {
    local what=$1 secs=$2; shift 2
    local i
    for ((i=0; i<secs; i++)); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    fail "timed out after ${secs}s waiting for: $what"
}

# mine_b2b N mines N blocks on the BLAKE2b regtest to the lab wallet.
mine_b2b() {
    local n=$1
    b2b -rpcwallet=lab getnewaddress >/dev/null 2>&1 || b2b createwallet lab >/dev/null 2>&1 || b2b loadwallet lab >/dev/null 2>&1 || true
    local addr; addr=$(b2b -rpcwallet=lab getnewaddress)
    b2b -rpcwallet=lab generatetoaddress "$n" "$addr" >/dev/null
}

mine_sha() {
    local n=$1
    sha -rpcwallet=lab getnewaddress >/dev/null 2>&1 || sha createwallet lab >/dev/null 2>&1 || sha loadwallet lab >/dev/null 2>&1 || true
    local addr; addr=$(sha -rpcwallet=lab getnewaddress)
    sha -rpcwallet=lab generatetoaddress "$n" "$addr" >/dev/null
}

# header_width HEIGHT -> byte width of the header at that height on knots-b2b.
header_width() {
    local h; h=$(b2b getblockhash "$1")
    local raw; raw=$(b2b getblockheader "$h" false)
    echo $(( ${#raw} / 2 ))
}

# lnd_synced SERVICE: true when lncli getinfo reports synced_to_chain.
lnd_synced() { [ "$(lncli_on "$1" getinfo 2>/dev/null | jq -r .synced_to_chain)" = "true" ]; }

# lnd_height SERVICE -> block_height from getinfo.
lnd_height() { lncli_on "$1" getinfo | jq -r .block_height; }

# lnd_ready SERVICE: getinfo answers at all.
lnd_ready() { lncli_on "$1" getinfo >/dev/null 2>&1; }

# ensure_b2b_funds AMOUNT_BTC: coinbase outputs mature after 100 blocks, and
# a fresh lab chain is only a few blocks past activation, so mine to maturity
# the first time coins are needed.
ensure_b2b_funds() {
    local need=$1
    local bal; bal=$(b2b -rpcwallet=lab getbalance 2>/dev/null || echo 0)
    if [ "$(echo "$bal < $need" | bc)" = 1 ]; then
        mine_b2b 101
    fi
}

# fund_lf SERVICE AMOUNT_BTC: sends coins from the lab wallet on knots-b2b and
# confirms them.
fund_lf() {
    local svc=$1 amt=$2
    ensure_b2b_funds "$amt"
    local addr; addr=$(lncli_on "$svc" newaddress p2tr | jq -r .address)
    b2b -rpcwallet=lab sendtoaddress "$addr" "$amt" >/dev/null
    mine_b2b 6
    wait_for "$svc to see funds" 60 sh -c "[ \"\$($COMPOSE exec -T $svc lncli --network=regtest --rpcserver=127.0.0.1:10009 walletbalance | jq -r .confirmed_balance)\" != 0 ]"
}

pubkey_of() { lncli_on "$1" getinfo | jq -r .identity_pubkey; }

record() {
    # record NAME KEY VALUE: append a line to results/<name>.log
    echo "$(date -u +%FT%TZ) $2=$3" >> "results/$1.log"
}
