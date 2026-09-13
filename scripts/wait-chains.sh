#!/usr/bin/env bash
# Wait for both chain nodes, create their wallets, and mine to a known state:
# the BLAKE2b regtest sits ten blocks below its activation height so that a
# Lightning Fork node started now has to wait for activation, which is the
# first thing the sync scenario checks.
source "$(dirname "$0")/lib.sh"

step "waiting for knots-b2b"
wait_for "knots-b2b rpc" 60 b2b getblockchaininfo
step "waiting for bitcoind-sha"
wait_for "bitcoind-sha rpc" 60 sha getblockchaininfo

b2b createwallet lab >/dev/null 2>&1 || b2b loadwallet lab >/dev/null 2>&1 || true
sha createwallet lab >/dev/null 2>&1 || sha loadwallet lab >/dev/null 2>&1 || true

pre=$(( ACTIVATION_HEIGHT - 10 ))
h=$(b2b getblockcount)
if [ "$h" -lt "$pre" ]; then
    mine_b2b $(( pre - h ))
fi
h=$(sha getblockcount)
if [ "$h" -lt 101 ]; then
    mine_sha $(( 101 - h ))
fi

echo "knots-b2b height $(b2b getblockcount) (activation at $ACTIVATION_HEIGHT), bitcoind-sha height $(sha getblockcount)"
