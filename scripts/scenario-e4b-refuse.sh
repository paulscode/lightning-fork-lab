#!/usr/bin/env bash
# E4b: a Lightning Fork node pointed at a SHA256d regtest must refuse to
# start, in words, and record the refusal in its status file.
source "$(dirname "$0")/lib.sh"

step "E4b: start lf-bad against bitcoind-sha"
$COMPOSE --profile refuse up -d lf-bad
# Make sure the SHA256d chain is past the activation height so the check
# actually reads a header rather than waiting.
h=$(sha getblockcount)
if [ "$h" -lt $(( ACTIVATION_HEIGHT + 5 )) ]; then
    mine_sha $(( ACTIVATION_HEIGHT + 5 - h ))
fi

wait_for "lf-bad to exit" 120 sh -c "[ \"\$($COMPOSE ps -a --format json lf-bad | jq -r '.State')\" = exited ]"
code=$($COMPOSE ps -a --format json lf-bad | jq -r '.ExitCode')
[ "$code" != 0 ] || fail "lf-bad exited 0 against a SHA256d chain"
pass "lf-bad exited with code $code"

logs=$($COMPOSE logs --no-color lf-bad 2>/dev/null)
echo "$logs" | grep -q "not on the Bitcoin BLAKE2b chain" || { echo "$logs" | tail -20; fail "refusal message not in the log"; }
echo "$logs" | grep -q "80 bytes" || fail "log does not name the 80-byte header"
pass "log names the reason: $(echo "$logs" | grep -o 'not on the Bitcoin BLAKE2b chain: [^"]*' | head -1 | cut -c1-120)..."

# The status file is on the volume; read it with a one-off container.
st=$(docker run --rm -v lightning-fork-lab_lf-bad-data:/lnd:ro alpine cat /lnd/data/chain/bitcoin/regtest/chain-identity.json)
[ "$(echo "$st" | jq -r .state)" = refused ] || fail "status file state is $(echo "$st" | jq -r .state)"
echo "$st" | jq -r .reason | grep -q "SHA256d" || fail "status file reason does not mention SHA256d"
pass "status file records state=refused with the reason"

$COMPOSE --profile refuse rm -sf lf-bad >/dev/null
record e4b-refuse result PASS
echo "E4b PASSED"
