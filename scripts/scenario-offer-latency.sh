#!/usr/bin/env bash
# What a BOLT 12 invoice fetch costs, and when it works at all.
#
# The fetch-first payout design makes an OCEAN payout atomic by inverting an
# order. Today the bridge issues the Bitcoin invoice itself, so it holds the
# preimage from the start and could collect without paying; the miner's only
# protection is that it does not. Instead, when a request arrives for the
# bridge's Bitcoin offer, the bridge first fetches an invoice from the *miner's*
# BLAKE2b offer and answers with that invoice's payment hash. It then cannot
# settle the Bitcoin leg without the preimage, and the only way to get it is to
# pay the miner.
#
# That inserts an onion-message round trip on another network into the middle of
# answering an invoice request, so the question was whether it fits inside the
# requesting payer's timeout:
#
#   BUDGET  how long the payer waits for a reply (ours is 60s; OCEAN's is S16)
#   COST    how long our fetch from the miner's offer takes
#
# It does, comfortably. The cost is milliseconds. What this measures instead is
# the thing that turned out to matter: about 15% of fetches do not complete at
# all, uniformly, whichever way round and whether or not the offer carries a
# blinded path. The matrix is four cells because a single case at low reps
# produced a confident and entirely false asymmetry.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

bash "$(dirname "$0")/bolt12-setup.sh"

json_field() {
	grep -m1 "\"$1\"" | sed 's/.*"'"$1"'": *"\{0,1\}\([^",]*\)"\{0,1\}.*/\1/'
}

now_ms() { date +%s%3N; }
median() { sort -n | awk '{a[NR]=$1} END{print (NR%2) ? a[(NR+1)/2] : int((a[NR/2]+a[NR/2+1])/2)}'; }

# try ISSUER FETCHER PATHFLAG REPS: mints an offer on ISSUER and has FETCHER
# fetch an invoice for it, REPS times. Prints "<ok>/<reps> median <ms>".
try() {
	local issuer=$1 fetcher=$2 flag=$3 reps=$4
	local lno ok=0 times
	times=$(mktemp)

	lno=$(lncli_on "$issuer" offer create \
		--description "payout matrix $flag" "$flag" 2>/dev/null |
		json_field bolt12) || true
	if [ -z "${lno:-}" ] || [[ "$lno" != lno1* ]]; then
		echo "offer-mint-failed"

		return
	fi

	for i in $(seq 1 "$reps"); do
		local t0 t1
		# Paced, because the issuer allows one request per second per
		# peer after a burst of five. Without this the matrix measures
		# the rate limiter and reports it as loss, which is exactly the
		# mistake that produced the first version of this script.
		[ "$i" = 1 ] || sleep 1.1
		t0=$(now_ms)
		if lncli_on "$fetcher" offer fetchinvoice "$lno" \
			--amount_msat 123000 --timeout 10 \
			--payer_note "matrix $i" >/dev/null 2>&1; then
			t1=$(now_ms)
			ok=$((ok + 1))
			echo $((t1 - t0)) >> "$times"
		fi
	done

	if [ "$ok" = 0 ]; then
		echo "$ok/$reps -"
	else
		echo "$ok/$reps $(median < "$times")ms"
	fi
}

REPS=${REPS:-5}

step "offer-latency: the matrix"
echo
echo "  Both nodes fall back to a blinded path starting at themselves, because"
echo "  in a two-node lab neither has a peer that could be an introduction node"
echo "  for the other. That fallback fires in every cell, so it is not the"
echo "  variable here -- and at 20 reps neither is anything else in the matrix."
echo
printf "  %-28s %-16s %s\n" "case" "with_paths" "no_paths"
printf "  %-28s %-16s %s\n" "----" "----------" "--------"

a=$(try lf1 lf2 --with_paths "$REPS")
b=$(try lf1 lf2 --no_paths "$REPS")
printf "  %-28s %-16s %s\n" "lf2 fetches from lf1" "$a" "$b"

c=$(try lf2 lf1 --with_paths "$REPS")
d=$(try lf2 lf1 --no_paths "$REPS")
printf "  %-28s %-16s %s\n" "lf1 fetches from lf2" "$c" "$d"

echo
record offer-latency lf2_from_lf1_paths "$a"
record offer-latency lf2_from_lf1_nopaths "$b"
record offer-latency lf1_from_lf2_paths "$c"
record offer-latency lf1_from_lf2_nopaths "$d"

step "offer-latency: what it means for the fetch-first design"
cat <<EOF

  Latency is not the risk. Where a fetch succeeds at all it completes in
  roughly a tenth of a second, against a 60s payer timeout in our own
  implementation. The round trip is not what would break this.

  Whether the fetch succeeds was the risk, and the answer turned out to be
  about this script as much as about the code. An earlier version passed
  --timeout_seconds, which lncli does not have for fetchinvoice; the flag is
  --timeout. Every fetch silently used the 60s default, and the uniform "15%
  failure" it reported across all four cells was the issuer's own per-peer
  rate limiter: a burst of five, then one per second. Uniform across
  direction and blinded paths because a rate limiter cares about neither.

  The limiting was correct. The silence was not: a requester that gets
  nothing cannot tell rate limiting from the issuer being offline, so it
  waited out a full timeout for something decided in microseconds. The
  server now answers the first over-limit request with an invoice_error and
  stays quiet for the rest of the window, so the same case fails in about a
  tenth of a second with a reason. See offerserve/server.go.

  If a cell below is not REPS/REPS, check the pace before suspecting loss:
  requests faster than one per second per peer are supposed to be refused.

  Still unmeasured, because they need an OCEAN account: how long OCEAN waits
  for an invoice reply (S16), and how long it takes to pay one (S17).
EOF
