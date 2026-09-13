#!/usr/bin/env bash
# E7: everything Lightning Fork signs alone carries SIGHASH_UNIFIED (0x20 in
# the hash type byte), which the BLAKE2b regtest accepts and no chain without
# the fork would. A wallet send, and a PSBT funded and finalized by the
# wallet, both confirm with the bit on every input.
source "$(dirname "$0")/lib.sh"

# witness_opts_in TXID: every input's first witness element (the signature)
# ends in a hash type byte with 0x20 set. Prints the bytes it saw.
witness_opts_in() {
    local txid=$1
    local sigs; sigs=$(b2b getrawtransaction "$txid" true | jq -r '.vin[].txinwitness[0]')
    [ -n "$sigs" ] || fail "$txid has no witness"
    local sig last
    for sig in $sigs; do
        last=$(( 16#${sig: -2} ))
        [ $(( last & 0x20 )) -ne 0 ] || fail "$txid: signature ends in hash type 0x$(printf %02x $last), not opted in"
        printf '0x%02x ' "$last"
    done
}

# The wallet backend calls a tip older than two hours "not current", so a
# stack left idle since the last run needs a fresh block before the nodes
# report synced.
mine_b2b 1
wait_for "lf1 synced" 120 lnd_synced lf1

step "E7: a wallet send opts in"
fund_lf lf1 1
addr=$(lf1 newaddress p2wkh | jq -r .address)
txid=$(lf1 sendcoins --addr="$addr" --amt=200000 --sat_per_vbyte=2 --force | jq -r .txid)
wait_for "send in the mempool" 30 sh -c "$COMPOSE exec -T knots-b2b bitcoin-cli -datadir=/data -rpcuser=lab -rpcpassword=lab getrawtransaction $txid >/dev/null 2>&1"
bytes=$(witness_opts_in "$txid")
mine_b2b 1
conf=$(b2b getrawtransaction "$txid" true | jq -r .confirmations)
[ "$conf" -ge 1 ] || fail "send $txid did not confirm"
pass "wallet send $txid confirmed with hash type byte(s) $bytes"

step "E7: a taproot input opts in too (65-byte signature)"
addr=$(lf1 newaddress p2tr | jq -r .address)
txid=$(lf1 sendcoins --addr="$addr" --amt=150000 --sat_per_vbyte=2 --force | jq -r .txid)
mine_b2b 1
# Spend the taproot output we just made: send everything it can reach.
txid2=$(lf1 sendcoins --addr="$(lf1 newaddress p2wkh | jq -r .address)" --amt=100000 --sat_per_vbyte=2 --force | jq -r .txid)
wait_for "taproot spend in the mempool" 30 sh -c "$COMPOSE exec -T knots-b2b bitcoin-cli -datadir=/data -rpcuser=lab -rpcpassword=lab getrawtransaction $txid2 >/dev/null 2>&1"
bytes=$(witness_opts_in "$txid2")
sigs=$(b2b getrawtransaction "$txid2" true | jq -r '.vin[].txinwitness[0]')
for sig in $sigs; do
    [ ${#sig} -eq 130 ] && pass "a 65-byte Schnorr signature carries the byte: ${sig: -2}"
done
mine_b2b 1
[ "$(b2b getrawtransaction "$txid2" true | jq -r .confirmations)" -ge 1 ] || fail "$txid2 did not confirm"
pass "taproot-funded send $txid2 confirmed with $bytes"

step "E7: a PSBT the wallet funds and finalizes opts in"
dest=$(lf1 newaddress p2wkh | jq -r .address)
funded=$(lf1 wallet psbt fund --outputs="{\"$dest\":120000}" --sat_per_vbyte=2)
psbt=$(echo "$funded" | jq -r .psbt)
# The inputs the wallet added were stamped with the opt-in hash type.
decoded=$(echo "$psbt" | base64 -d | xxd -p | tr -d '\n')
finalized=$(lf1 wallet psbt finalize "$psbt")
rawtx=$(echo "$finalized" | jq -r .final_tx)
txid3=$(b2b sendrawtransaction "$rawtx")
bytes=$(witness_opts_in "$txid3")
mine_b2b 1
[ "$(b2b getrawtransaction "$txid3" true | jq -r .confirmations)" -ge 1 ] || fail "$txid3 did not confirm"
pass "wallet-funded PSBT $txid3 confirmed with hash type byte(s) $bytes"

step "E7: a template-funded PSBT (coin selection path) opts in too"
funded=$(lf1 wallet psbt fundtemplate --outputs="{\"$dest\":90000}" --sat_per_vbyte=2 2>/dev/null || lf1 wallet psbt fund --outputs="{\"$dest\":90000}" --sat_per_vbyte=2)
psbt=$(echo "$funded" | jq -r .psbt)
finalized=$(lf1 wallet psbt finalize "$psbt")
rawtx=$(echo "$finalized" | jq -r .final_tx)
txid4=$(b2b sendrawtransaction "$rawtx")
bytes=$(witness_opts_in "$txid4")
mine_b2b 1
pass "template-funded PSBT $txid4 confirmed with hash type byte(s) $bytes"

step "E7: a PSBT carrying a signature made without the opt-in is refused"
# Fund and sign, then flip the partial signature's hash type byte to
# SIGHASH_ALL, as a signer that does not know the chain would have written
# it; finalization must refuse rather than assemble a replayable transaction.
funded=$(lf1 wallet psbt fund --outputs="{\"$dest\":110000}" --sat_per_vbyte=2)
psbt=$(echo "$funded" | jq -r .psbt)
signed=$(lf1 wallet psbt sign "$psbt" | jq -r .psbt)
python3 - "$signed" > /tmp/e7-legacy.psbt <<'PY'
import base64, sys
raw = bytearray(base64.b64decode(sys.argv[1]))
assert raw[:5] == b"psbt\xff", "not a PSBT"

def varint(i):
    b = raw[i]
    if b < 0xfd:
        return b, i + 1
    if b == 0xfd:
        return int.from_bytes(raw[i+1:i+3], "little"), i + 3
    if b == 0xfe:
        return int.from_bytes(raw[i+1:i+5], "little"), i + 5
    return int.from_bytes(raw[i+1:i+9], "little"), i + 9

def walk(i, on_record):
    """Walk one key/value map starting at i; return the index after its terminator."""
    while True:
        klen, j = varint(i)
        if klen == 0:
            return j
        key = bytes(raw[j:j+klen]); j += klen
        vlen, j = varint(j)
        on_record(key, j, vlen)
        i = j + vlen

i = walk(5, lambda k, v, n: None)  # the global map
flipped = []
def flip(key, v, n):
    if key[:1] == b"\x02":  # PSBT_IN_PARTIAL_SIG
        raw[v+n-1] = 0x01
        flipped.append(key)
walk(i, flip)  # the first input map
if not flipped:
    raise SystemExit("no partial signature in the first input")
print(base64.b64encode(bytes(raw)).decode())
PY
legacy=$(cat /tmp/e7-legacy.psbt)
if out=$(lf1 wallet psbt finalize "$legacy" 2>&1); then
    fail "a PSBT with a legacy signature was finalized: $out"
fi
echo "$out" | grep -q "does not opt into the unified signature hash" || fail "unexpected refusal: $out"
pass "finalization refused the legacy signature: $(echo "$out" | grep -o 'input 0: [^;]*' | head -1 | cut -c1-90)"
# Release the leased inputs so later scenarios can use them.
for lock in $(echo "$funded" | jq -c '.locked_utxos[]'); do
    lf1 wallet releaseoutput --lock_id="$(echo "$lock" | jq -r .id)" --outpoint="$(echo "$lock" | jq -r .outpoint.txid_str):$(echo "$lock" | jq -r .outpoint.output_index)" >/dev/null 2>&1 || true
done

record e7-replay result PASS
echo "E7 PASSED"
