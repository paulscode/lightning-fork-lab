#!/usr/bin/env bash
# The bridge running inside Lightning Fork, with Core Lightning on the BLAKE2b
# side where scenario-bridge.sh has lf2:
#
#   cln (payer)  --> lf1 (bridge) ... lnd-sha (bridge) --> lnd-sha2   toSHA256
#   cln (payee)  <-- lf1 (bridge) ... lnd-sha (bridge) <-- lnd-sha2   toBLAKE2b
#
# Needs `make bridge-setup` and `make cln` first, and lf1 running with
# docker-compose.bridge.yml layered on. Core Lightning's two channels with lf1
# are opened here, one from each side. Unless the bridge already quotes, both
# chains are then paced (scripts/pace-blocks.sh) and lf1 restarted, so the
# bridge measures block spacing from the paced blocks.
#
# What it covers: a Bitcoin invoice paid by Core Lightning, after the five
# payer checks of lightning-fork-bridge's docs/payer-api.md (section 2.2) run
# on Core Lightning's own decode of the hold invoice; a Core Lightning invoice
# paid from Bitcoin; and a refund to Core Lightning when the destination
# cancels.
#
# The payer holds a participant's bridge code and calls the bridge from the
# Core Lightning container, at https://lf1:8080 on the lab network, after
# checking that the endpoint presents the certificate the code pins. That is
# where a payer's requests come from, and it does not depend on the host
# reaching container addresses, which rootless Docker does not allow.
source "$(dirname "$0")/lib.sh"

CLN_CONTAINER=${CLN_CONTAINER:-lightning-fork-lab-cln-1}
AMT="${AMT:-2000000}"
cln() { docker exec "$CLN_CONTAINER" lightning-cli --network=regtest --lightning-dir=/data "$@"; }
cln_synced() { [ "$(cln getinfo | jq -r .blockheight)" = "$(b2b getblockcount)" ]; }

# REST on lf1 from the Core Lightning container. Prints the body, then the
# HTTP status on its own line, so a caller can check both. The certificate is
# not checked by curl; the pin is checked once, below, the way a payer would.
rest_as() {
	local mac="$1" method="$2" path="$3" body="${4:-}"
	if [ -n "$body" ]; then
		docker exec "$CLN_CONTAINER" curl -s -k -w '\n%{http_code}' -X "$method" \
			-H "Grpc-Metadata-macaroon: $mac" -d "$body" "https://lf1:8080$path"
	else
		docker exec "$CLN_CONTAINER" curl -s -k -w '\n%{http_code}' -X "$method" \
			-H "Grpc-Metadata-macaroon: $mac" "https://lf1:8080$path"
	fi
}

admin_mac() {
	$COMPOSE exec -T lf1 cat /root/.lnd/data/chain/bitcoin/regtest/admin.macaroon \
		| od -An -tx1 -v | tr -d ' \n'
}

# The operator's status call, for readiness only; the payer never makes it.
status() { rest_as "$(admin_mac)" GET /v2/bridge/status | sed '$d'; }

# The payer's calls, with the participant's macaroon from the bridge code.
payer() { rest_as "$PMAC" POST "/v2/bridge/$1" "$2" | sed '$d'; }

b64_to_hex() { echo "$1" | base64 -d | od -An -tx1 -v | tr -d ' \n'; }
sha256_hex() { echo -n "$1" | python3 -c 'import hashlib, sys; print(hashlib.sha256(bytes.fromhex(sys.stdin.read())).hexdigest())'; }
# has_bit FEATURES_HEX BIT...: true when any of the bits is set.
has_bit() { python3 -c 'import sys; f = int(sys.argv[1] or "0", 16); sys.exit(0 if any(f >> int(b) & 1 for b in sys.argv[2:]) else 1)' "$@"; }
pin_of() { python3 -c '
import hashlib, ssl, sys
h = hashlib.sha256(ssl.PEM_cert_to_DER_cert(sys.stdin.read().strip())).hexdigest().upper()
print(":".join(h[i:i + 2] for i in range(0, 64, 2)))'; }

swap_state() { payer swap "{\"hash\":\"$1\"}" | jq -r '.state // .message'; }

# Waits rather than sleeps, and stops at the first state that ends the swap.
wait_for_state() {
	local hash="$1" want="$2" secs="${3:-120}" seen=""
	for _ in $(seq 1 "$secs"); do
		seen=$(swap_state "$hash" 2>/dev/null || true)
		[ "$seen" = "$want" ] && return 0
		case "$seen" in failed|aborted|expired|lost|settled) break ;; esac
		sleep 1
	done
	fail "swap ended in ${seen:-unknown}, wanted $want"
}

wait_ready() {
	local secs="${1:-180}" resp=""
	for _ in $(seq 1 "$secs"); do
		resp=$(status 2>/dev/null || true)
		echo "$resp" | jq -e '.enabled == true and (.refusals | length) == 0' >/dev/null 2>&1 && return 0
		sleep 1
	done
	fail "the bridge is not ready: ${resp:-no answer}"
}

# payer-api.md 2.1: incoming_msat = ceil(out / rate * (1 + spread))
estimate() {
	echo "$INFO" | jq -r --arg d "$1" '.directions[] | select(.name == $d) | "\(.rate) \(.spread)"' \
		| python3 -c 'import math, sys; r, s = map(float, sys.stdin.read().split()); print(math.ceil(int(sys.argv[1]) / r * (1 + s)))' "$2"
}

# The five payer checks of payer-api.md 2.2, on Core Lightning's decode of the
# hold invoice. Prints the reason and returns non-zero on the first that fails.
cln_payer_checks() {
	local dest="$1" q="$2" agreed="$3" dec ddec hh dh payee feat amt exp now
	dec=$(cln decode "$(echo "$q" | jq -r .hold_invoice)") || { echo "cannot decode the hold invoice"; return 1; }
	ddec=$(cln decode "$dest") || { echo "cannot decode the destination invoice"; return 1; }
	echo "$dec" | jq -e '.valid == true' >/dev/null || { echo "the hold invoice is not valid"; return 1; }
	hh=$(echo "$dec" | jq -r .payment_hash); dh=$(echo "$ddec" | jq -r .payment_hash)
	payee=$(echo "$dec" | jq -r .payee); feat=$(echo "$dec" | jq -r '.features // ""')
	amt=$(echo "$dec" | jq -r .amount_msat); exp=$(echo "$q" | jq -r .expires_at); now=$(date +%s)
	[ "$hh" = "$dh" ] && [ "$hh" = "$(b64_to_hex "$(echo "$q" | jq -r .hash)")" ] \
		|| { echo "1: the hold invoice is for $hh, the destination's for $dh"; return 1; }
	[ "$payee" = "$CODE_NODE" ] || { echo "2: the hold invoice pays $payee, not $CODE_NODE"; return 1; }
	has_bit "$feat" 512 513 || { echo "3: features $feat do not set option_blake2b"; return 1; }
	[ "$amt" -le "$agreed" ] && [ "$amt" = "$(echo "$q" | jq -r .incoming_msat)" ] \
		|| { echo "4: $amt msat against $agreed agreed"; return 1; }
	[ $((exp - now)) -ge 10 ] || { echo "5: only $((exp - now))s before expires_at"; return 1; }
	echo "hash $hh, payee $payee, $amt msat <= $agreed, $((exp - now))s left"
}

cln_to_lf1_msat() { cln listpeerchannels "$LF1" | jq '[.channels[] | .to_us_msat] | add'; }
cln_peer_up() { [ "$(cln listpeerchannels "$LF1" | jq '[.channels[] | select(.state == "CHANNELD_NORMAL" and .peer_connected)] | length')" -ge 2 ]; }

step "bridge-cln: Core Lightning's channels with lf1"
wait_for "cln up" 120 cln getinfo
LF1=$(pubkey_of lf1)
CLN=$(cln getinfo | jq -r .id)
mine_b2b 1
wait_for "lf1 synced" 180 lnd_synced lf1
wait_for "cln at the tip" 120 cln_synced
cln connect "$LF1@lf1:9735" >/dev/null
opened=0
# Forward and refund are paid from a channel Core Lightning opened.
cln_out=$(cln listpeerchannels "$LF1" | jq '[.channels[] | select(.state == "CHANNELD_NORMAL") | .spendable_msat] | max // 0')
if [ "$cln_out" -lt $((10 * AMT)) ]; then
	if [ "$(cln listfunds | jq '[.outputs[] | select(.status == "confirmed")] | length')" = 0 ]; then
		ensure_b2b_funds 2
		b2b -rpcwallet=lab sendtoaddress "$(cln newaddr | jq -r '.p2tr // .bech32')" 1 >/dev/null
		mine_b2b 6
		wait_for "cln sees funds" 60 sh -c "[ \"\$(docker exec $CLN_CONTAINER lightning-cli --network=regtest --lightning-dir=/data listfunds | jq '[.outputs[] | select(.status == \"confirmed\")] | length')\" != 0 ]"
	fi
	wait_for "cln at the tip" 120 cln_synced
	# 3000perkw rather than `normal`, as in scenario-bit68.sh: at regtest's
	# floor of 253perkw a funding transaction spending a coin from an
	# anchors channel's to_remote comes out under the min relay fee, since
	# Core Lightning sizes that input as if it predated anchors.
	res=$(cln fundchannel "$LF1" 1000000 3000perkw true 2>&1) || fail "cln fundchannel: $res"
	opened=1
fi
# The reverse direction is paid out by lf1, so it needs its own channel.
lf1_out=$(lf1 listchannels | jq --arg p "$CLN" '[.channels[] | select(.active and .remote_pubkey == $p) | (.local_balance | tonumber)] | max // 0')
if [ "$lf1_out" -lt 100000 ]; then
	fund_lf lf1 2
	lf1 openchannel --node_key="$CLN" --local_amt=1000000 >/dev/null
	opened=1
fi
if [ "$opened" = 1 ]; then
	mine_b2b 6
	wait_for "two channels normal on cln" 180 sh -c "[ \"\$(docker exec $CLN_CONTAINER lightning-cli --network=regtest --lightning-dir=/data listpeerchannels $LF1 | jq '[.channels[] | select(.state == \"CHANNELD_NORMAL\")] | length')\" -ge 2 ]"
	wait_for "lf1's channels with cln active" 180 sh -c "[ \"\$($COMPOSE exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq --arg p $CLN '[.channels[] | select(.active and .remote_pubkey == \$p)] | length')\" -ge 2 ]"
fi
# Blocks mined in a burst, here or by bridge-setup, read to the bridge as a
# chain running far too fast, so pace both chains unless it already quotes.
if [ "$opened" = 1 ] || ! status | jq -e '(.refusals | length) == 0' >/dev/null 2>&1; then
	bash scripts/pace-blocks.sh
	# The bridge samples each tip as it polls, so it sees few of a burst of
	# paced blocks; it reads the last 150 only as it starts.
	$COMPOSE restart lf1 >/dev/null 2>&1
	wait_for "lf1 back" 120 lnd_ready lf1
	wait_for "lf1 synced after pacing" 180 lnd_synced lf1
	wait_for "lnd-sha synced after pacing" 180 lnd_synced lnd-sha
	wait_for "lnd-sha2 synced after pacing" 180 lnd_synced lnd-sha2
	wait_for "cln at the tip after pacing" 180 cln_synced
	wait_for "cln reconnected to lf1" 120 cln_peer_up
fi
pass "cln $CLN has $(cln_to_lf1_msat) msat with lf1 $LF1, over channels opened from each side"

step "bridge-cln: the payer's bridge code"
wait_ready 300
if ! status | jq -e '.rate == 1' >/dev/null; then
	lf1 bridge setrate 1.0 >/dev/null
	$COMPOSE restart lf1 >/dev/null 2>&1
	wait_ready 300
	wait_for "cln reconnected to lf1" 120 cln_peer_up
fi
PIN=$($COMPOSE exec -T lf1 cat /root/.lnd/tls.cert | pin_of)
code=$(lf1 bridge code --url https://lf1:8080 --label cln --cert "$PIN")
CODEJSON=$(echo "$code" | jq -r .code | python3 -c '
import base64, sys
s = sys.stdin.read().strip()
assert s.startswith("lfbridge:"), s
s = s[len("lfbridge:"):]
print(base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)).decode())')
PMAC=$(echo "$CODEJSON" | jq -r .macaroon)
CODE_NODE=$(echo "$CODEJSON" | jq -r .node)
served=$(docker exec "$CLN_CONTAINER" python3 -c 'import ssl; print(ssl.get_server_certificate(("lf1", 8080)))' | pin_of)
[ "$(echo "$CODEJSON" | jq -r .v)" = 1 ] || fail "code version: $CODEJSON"
[ "$served" = "$(echo "$CODEJSON" | jq -r .cert)" ] || fail "lf1:8080 presents $served, the code pins $(echo "$CODEJSON" | jq -r .cert)"
[ "$CODE_NODE" = "$LF1" ] || fail "the code names $CODE_NODE, lf1 is $LF1"
INFO=$(rest_as "$PMAC" GET /v2/bridge/info | sed '$d')
echo "$INFO" | jq -e --arg n "$CODE_NODE" '.version == 1 and .node == $n and ([.directions[] | select(.open)] | length == 2)' >/dev/null \
	|| fail "info: $INFO"
pass "code v1 for lf1; the endpoint presents the pinned certificate; info answers the participant, both directions open"

step "bridge-cln: Core Lightning pays a Bitcoin invoice through the bridge"
dest=$(lndsha2 addinvoice --amt_msat="$AMT" --memo "from cln" | jq -r .payment_request)
dhash=$(lndsha2 decodepayreq "$dest" | jq -r .payment_hash)
agreed=$(estimate toSHA256 "$AMT")
q=$(payer quote "{\"invoice\":\"$dest\"}")
[ "$(echo "$q" | jq -r .direction)" = toSHA256 ] || fail "quote: $q"
hash=$(echo "$q" | jq -r .hash)
why=$(cln_payer_checks "$dest" "$q" "$agreed") || fail "payer check $why"
pass "toSHA256 quote; all five payer checks hold on Core Lightning: $why"
wait_for "cln at the tip" 120 cln_synced
before=$(cln_to_lf1_msat)
cln pay "$(echo "$q" | jq -r .hold_invoice)" >/dev/null 2>&1 &
wait_for_state "$hash" settled 180
wait
inv=$(lndsha2 lookupinvoice "$dhash")
[ "$(echo "$inv" | jq -r .state)" = SETTLED ] && [ "$(echo "$inv" | jq -r .amt_paid_msat)" = "$AMT" ] \
	|| fail "lnd-sha2's invoice: $(echo "$inv" | jq -c '{state, amt_paid_msat}')"
pre=$(cln listpays -k payment_hash="$dhash" | jq -r '.pays[] | select(.status == "complete") | .preimage' | head -1)
[ -n "$pre" ] && [ "$(sha256_hex "$pre")" = "$dhash" ] || fail "Core Lightning holds no preimage for $dhash"
[ "$(b64_to_hex "$(payer swap "{\"hash\":\"$hash\"}" | jq -r .preimage)")" = "$pre" ] \
	|| fail "the bridge reports another preimage"
pass "settled: lnd-sha2's invoice paid $AMT msat, Core Lightning paid $((before - $(cln_to_lf1_msat))) msat and holds the preimage"

step "bridge-cln: lnd-sha2 pays a Core Lightning invoice through the bridge"
label="bridge-cln-$(date +%s)"
cinv=$(cln invoice "$AMT" "$label" "from Bitcoin")
chash=$(echo "$cinv" | jq -r .payment_hash)
agreed=$(estimate toBLAKE2b "$AMT")
q=$(payer quote "{\"invoice\":\"$(echo "$cinv" | jq -r .bolt11)\"}")
[ "$(echo "$q" | jq -r .direction)" = toBLAKE2b ] || fail "quote: $q"
hash=$(echo "$q" | jq -r .hash)
dec=$(lndsha2 decodepayreq "$(echo "$q" | jq -r .hold_invoice)")
exp=$(echo "$q" | jq -r .expires_at)
# The same checks from the payer on the Bitcoin side. Checks 2 and 3 are
# written for toSHA256; here the hold invoice is the bridge's Bitcoin node's,
# so it pays lnd-sha and does not set option_blake2b.
[ "$(echo "$dec" | jq -r .payment_hash)" = "$chash" ] && [ "$(b64_to_hex "$hash")" = "$chash" ] \
	|| fail "1: the hold invoice is for $(echo "$dec" | jq -r .payment_hash), Core Lightning's for $chash"
[ "$(echo "$dec" | jq -r .destination)" = "$(pubkey_of lnd-sha)" ] || fail "2: the hold invoice pays $(echo "$dec" | jq -r .destination)"
echo "$dec" | jq -e '.features | has("512") or has("513") | not' >/dev/null || fail "3: a Bitcoin hold invoice sets option_blake2b"
[ "$(echo "$dec" | jq -r .num_msat)" -le "$agreed" ] && [ "$(echo "$dec" | jq -r .num_msat)" = "$(echo "$q" | jq -r .incoming_msat)" ] \
	|| fail "4: $(echo "$dec" | jq -r .num_msat) msat against $agreed agreed"
[ $((exp - $(date +%s))) -ge 10 ] || fail "5: too little time before expires_at"
pass "toBLAKE2b quote; the payer's checks hold on lnd-sha2"
lndsha2 payinvoice --force --timeout=120s "$(echo "$q" | jq -r .hold_invoice)" >/dev/null 2>&1 &
wait_for_state "$hash" settled 180
wait
ci=$(cln listinvoices "$label" | jq '.invoices[0]')
[ "$(echo "$ci" | jq -r .status)" = paid ] && [ "$(echo "$ci" | jq -r .amount_received_msat)" = "$AMT" ] \
	|| fail "Core Lightning's invoice: $(echo "$ci" | jq -c '{status, amount_received_msat}')"
pre=$(lndsha2 listpayments --max_payments 50 | jq -r --arg h "$chash" '.payments[] | select(.payment_hash == $h and .status == "SUCCEEDED") | .payment_preimage' | head -1)
[ -n "$pre" ] && [ "$pre" = "$(echo "$ci" | jq -r .payment_preimage)" ] || fail "lnd-sha2 holds '$pre'"
pass "settled: Core Lightning received $AMT msat, and lnd-sha2 holds its preimage"

step "bridge-cln: the destination cancels, Core Lightning gets its money back"
dest=$(lndsha2 addinvoice --amt_msat="$AMT" --memo "cancelled" | jq -r .payment_request)
dhash=$(lndsha2 decodepayreq "$dest" | jq -r .payment_hash)
agreed=$(estimate toSHA256 "$AMT")
q=$(payer quote "{\"invoice\":\"$dest\"}")
[ "$(echo "$q" | jq -r .direction)" = toSHA256 ] || fail "quote: $q"
hash=$(echo "$q" | jq -r .hash)
lndsha2 cancelinvoice "$dhash" >/dev/null
why=$(cln_payer_checks "$dest" "$q" "$agreed") || fail "payer check $why"
wait_for "cln at the tip" 120 cln_synced
before=$(cln_to_lf1_msat)
if cln pay "$(echo "$q" | jq -r .hold_invoice)" >/dev/null 2>&1; then
	fail "Core Lightning paid through to a cancelled invoice"
fi
wait_for_state "$hash" failed 120
pays=$(cln listpays -k payment_hash="$dhash")
[ "$(echo "$pays" | jq '[.pays[] | select(.status == "complete")] | length')" = 0 ] \
	&& [ "$(echo "$pays" | jq '[.pays[] | select(.status == "failed")] | length')" -ge 1 ] \
	|| fail "Core Lightning's payments: $(echo "$pays" | jq -c '[.pays[] | {status, preimage}]')"
wait_for "no HTLCs left between cln and lf1" 60 sh -c "[ \"\$(docker exec $CLN_CONTAINER lightning-cli --network=regtest --lightning-dir=/data listpeerchannels $LF1 | jq '[.channels[].htlcs[]] | length')\" = 0 ]"
[ "$(cln_to_lf1_msat)" = "$before" ] || fail "Core Lightning's balance went from $before to $(cln_to_lf1_msat) msat"
[ "$(lndsha2 lookupinvoice "$dhash" | jq -r .state)" = CANCELED ] || fail "lnd-sha2's invoice is not CANCELED"
pass "failed; Core Lightning's pay failed with no preimage and its balance is unchanged at $before msat"

echo; echo "ALL CLN BRIDGE SCENARIOS PASSED"
