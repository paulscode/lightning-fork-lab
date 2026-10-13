#!/usr/bin/env bash
# Splicing against the Core Lightning port: helpers for the containers
# sp-lf (Lightning Fork, splicing build) and sp-cln (the port's release), on
# the lab network and its BLAKE2b regtest.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
N=lightning-fork-lab_lab
LF_IMAGE=${LF_IMAGE:-lightning-fork:splice}
CLN_IMAGE=${CLN_IMAGE:-cln-blake2b-release:v7}

lf()  { docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 "$@"; }
cln() { docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data "$@"; }

# start_lf [NAME [FLAGS...]]: extra flags go to lnd.
start_lf() {
	local n=${1:-sp-lf}
	[ $# -gt 0 ] && shift
	docker run -d --name "$n" --network $N -v "$n-data:/root/.lnd" "$LF_IMAGE" \
		--noseedbackup --bitcoin.regtest --bitcoin.node=bitcoind \
		--bitcoin.blake2b-activation-height="${ACTIVATION_HEIGHT:-20}" \
		--fee.url=http://fees:8080/fees.json \
		--bitcoind.rpchost=knots-b2b:18443 --bitcoind.rpcuser=lab --bitcoind.rpcpass=lab \
		--bitcoind.zmqpubrawblock=tcp://knots-b2b:28332 --bitcoind.zmqpubrawtx=tcp://knots-b2b:28333 \
		--rpclisten=0.0.0.0:10009 --listen=0.0.0.0:9735 --externalip="$n:9735" \
		--tlsextradomain="$n" --alias="$n" \
		--debuglevel=info,PEER=debug,SPLC=trace,HSWC=debug,CNCT=debug,LNWL=debug,DISC=debug \
		--protocol.splice --accept-keysend "$@" >/dev/null
}

start_cln() {
	docker run -d --name sp-cln --network $N -v sp-cln-data:/data "$CLN_IMAGE" \
		--network=regtest --lightning-dir=/data --bitcoin-rpcconnect=knots-b2b \
		--bitcoin-rpcport=18443 --bitcoin-rpcuser=lab --bitcoin-rpcpassword=lab \
		--bind-addr=0.0.0.0:9735 --announce-addr=sp-cln:9735 --alias=sp-cln \
		--log-level=debug --disable-plugin=cln-grpc --disable-plugin=clnrest \
		--disable-plugin=cln-bip353 --experimental-splicing >/dev/null
}

lf_synced()  { [ "$(lf getinfo 2>/dev/null | jq -r .synced_to_chain)" = true ]; }
cln_synced() { [ "$(cln getinfo 2>/dev/null | jq -r .blockheight)" = "$(b2b getblockcount)" ]; }
wait_synced() {
	wait_for "sp-lf synced" 120 lf_synced
	wait_for "sp-cln synced" 120 cln_synced
}

# A Lightning Fork node with a seed, so its channels can be restored from a
# backup: created through the REST wallet unlocker.
start_seeded() {
	local n=$1
	docker run -d --name "$n" --network $N -v "$n-data:/root/.lnd" "$LF_IMAGE" \
		--bitcoin.regtest --bitcoin.node=bitcoind \
		--bitcoin.blake2b-activation-height="${ACTIVATION_HEIGHT:-20}" \
		--fee.url=http://fees:8080/fees.json \
		--bitcoind.rpchost=knots-b2b:18443 --bitcoind.rpcuser=lab --bitcoind.rpcpass=lab \
		--bitcoind.zmqpubrawblock=tcp://knots-b2b:28332 --bitcoind.zmqpubrawtx=tcp://knots-b2b:28333 \
		--rpclisten=0.0.0.0:10009 --restlisten=0.0.0.0:8080 --listen=0.0.0.0:9735 \
		--externalip="$n:9735" --tlsextradomain="$n" --alias="$n" \
		--debuglevel=info,PEER=debug,SPLC=trace,CNCT=debug,CHBU=debug \
		--protocol.splice >/dev/null
	wait_for "$n REST up" 60 sh -c "docker exec $n curl -sk https://127.0.0.1:8080/v1/genseed >/dev/null"
}

# init_wallet NODE MNEMONIC_JSON [BACKUP_FILE]: creates the wallet from a
# seed, restoring the channels of a multi-channel backup if given.
init_wallet() {
	local n=$1 seed=$2 backup=${3:-}
	local pw; pw=$(printf 'labpassword' | base64)
	local body
	if [ -n "$backup" ]; then
		body=$(jq -nc --arg pw "$pw" --argjson seed "$seed" --arg b "$(base64 -w0 < "$backup")" \
			'{wallet_password: $pw, cipher_seed_mnemonic: $seed, recovery_window: 200, channel_backups: {multi_chan_backup: {multi_chan_backup: $b}}}')
	else
		body=$(jq -nc --arg pw "$pw" --argjson seed "$seed" \
			'{wallet_password: $pw, cipher_seed_mnemonic: $seed}')
	fi
	docker exec "$n" curl -sk -X POST https://127.0.0.1:8080/v1/initwallet -d "$body" >/dev/null
	wait_for "$n RPC up" 60 sh -c "docker exec $n lncli --network=regtest getinfo >/dev/null"
}
