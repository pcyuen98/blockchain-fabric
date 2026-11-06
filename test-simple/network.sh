#!/usr/bin/env bash

set -Eeuo pipefail

ROOTDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOTDIR"

export PATH="$ROOTDIR/../bin:$PATH"
export FABRIC_CFG_PATH="$ROOTDIR/configtx"

CHANNEL_NAME=${CHANNEL_NAME:-mychannel}
CHAINCODE_NAME=basic
CHAINCODE_VERSION=1.0
CHAINCODE_SEQUENCE=1
export ORDERER_PORT=${ORDERER_PORT:-17050}
export PEER_PORT=${PEER_PORT:-17051}
export ORDERER_ADMIN_PORT=${ORDERER_ADMIN_PORT:-17053}
export COMPOSE_PROJECT_NAME=fabricminimalpoc
CHAINCODE_PATH="$ROOTDIR/../asset-transfer-basic/chaincode-go"
COMPOSE_FILE="$ROOTDIR/compose/compose-test-net.yaml"
ORDERER_CA="$ROOTDIR/organizations/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem"
ORDERER_ADMIN_CERT="$ROOTDIR/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.crt"
ORDERER_ADMIN_KEY="$ROOTDIR/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.key"
PEER_TLS_CA="$ROOTDIR/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
PEER_ADMIN_MSP="$ROOTDIR/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
CHANNEL_BLOCK="$ROOTDIR/minimal-artifacts/${CHANNEL_NAME}.block"
CHAINCODE_PACKAGE="$ROOTDIR/minimal-artifacts/basic.tar.gz"
DOCKER_SOCK=${DOCKER_HOST:-/var/run/docker.sock}
DOCKER_SOCK=${DOCKER_SOCK#unix://}

usage() {
  cat <<'EOF'
Usage: ./network.sh <command> [arguments]

Commands:
  up                         Start the one-peer network, create the channel,
                             and deploy the basic asset chaincode.
  createChannel              Create the channel and join the peer.
  restart                    Restart services without deleting ledger data.
  down                       Stop services while preserving ledger data.
  create <id> <color> <size> <owner> <value>
  update <id> <color> <size> <owner> <value>
  delete <id>
  query <id>

Set CHANNEL_NAME to use a channel name other than mychannel.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

compose() {
  ensure_podman_api
  DOCKER_SOCK="$DOCKER_SOCK" docker compose -f "$COMPOSE_FILE" "$@"
}

peer_env() {
  export FABRIC_CFG_PATH="$ROOTDIR/../config"
  export CORE_PEER_LOCALMSPID=Org1MSP
  export CORE_PEER_MSPCONFIGPATH="$PEER_ADMIN_MSP"
  export CORE_PEER_ADDRESS="localhost:${PEER_PORT}"
  export CORE_PEER_TLS_ENABLED=true
  export CORE_PEER_TLS_ROOTCERT_FILE="$PEER_TLS_CA"
  export CORE_PEER_TLS_SERVERHOSTOVERRIDE=peer0.org1.example.com
}

orderer_env() {
  export ORDERER_CA
}

ensure_crypto() {
  if [[ -f "$ORDERER_CA" && -f "$PEER_TLS_CA" && -d "$PEER_ADMIN_MSP" ]]; then
    return
  fi

  require_command cryptogen
  mkdir -p organizations
  cryptogen generate \
    --config=organizations/cryptogen/crypto-config-orderer.yaml \
    --output=organizations
  cryptogen generate \
    --config=organizations/cryptogen/crypto-config-org1.yaml \
    --output=organizations
}

ensure_podman_api() {
  if [[ "${CONTAINER_CLI:-docker}" != podman ]] && ! docker --version 2>&1 | grep -qi podman; then
    return
  fi

  local socket=/run/podman/podman.sock
  if curl -fsS --max-time 2 --unix-socket "$socket" http://localhost/_ping >/dev/null 2>&1; then
    DOCKER_SOCK="$socket"
    return
  fi

  mkdir -p /run/podman
  podman system service --time=0 "unix://$socket" >/tmp/fabric-podman-api.log 2>&1 &
  local i
  for ((i = 0; i < 20; i++)); do
    if curl -fsS --max-time 2 --unix-socket "$socket" http://localhost/_ping >/dev/null 2>&1; then
      DOCKER_SOCK="$socket"
      return
    fi
    sleep 1
  done
  fail "Podman API did not become ready; see /tmp/fabric-podman-api.log"
}

start_services() {
  require_command docker
  require_command peer
  require_command configtxgen
  require_command jq
  ensure_crypto
  ensure_podman_api
  compose up -d

  local port attempt
  for port in "$ORDERER_PORT" "$PEER_PORT" "$ORDERER_ADMIN_PORT"; do
    for ((attempt = 0; attempt < 60; attempt++)); do
      if (echo >/dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
    (echo >/dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1 || fail "Fabric service did not open port $port"
  done
}

orderer_has_channel() {
  local listing
  listing=$(osnadmin channel list \
    -o "localhost:${ORDERER_ADMIN_PORT}" \
    --ca-file "$ORDERER_CA" \
    --client-cert "$ORDERER_ADMIN_CERT" \
    --client-key "$ORDERER_ADMIN_KEY") || return 1
  grep -Fq "$CHANNEL_NAME" <<<"$listing"
}

peer_has_channel() {
  peer channel list 2>/dev/null | grep -Fxq "$CHANNEL_NAME"
}

create_channel() {
  require_command osnadmin
  peer_env
  orderer_env
  mkdir -p minimal-artifacts

  if [[ ! -s "$CHANNEL_BLOCK" ]]; then
    configtxgen -profile ChannelUsingRaft \
      -outputBlock "$CHANNEL_BLOCK" \
      -channelID "$CHANNEL_NAME"
  fi

  if ! orderer_has_channel; then
    osnadmin channel join \
      --channelID "$CHANNEL_NAME" \
      --config-block "$CHANNEL_BLOCK" \
      -o "localhost:${ORDERER_ADMIN_PORT}" \
      --ca-file "$ORDERER_CA" \
      --client-cert "$ORDERER_ADMIN_CERT" \
      --client-key "$ORDERER_ADMIN_KEY"
  fi

  if ! peer_has_channel; then
    peer channel join -b "$CHANNEL_BLOCK"
  fi
}

chaincode_committed() {
  peer lifecycle chaincode querycommitted \
    --channelID "$CHANNEL_NAME" \
    --name "$CHAINCODE_NAME" >/dev/null 2>&1
}

deploy_chaincode() {
  peer_env
  orderer_env
  [[ -d "$CHAINCODE_PATH" ]] || fail "Basic Go chaincode not found at $CHAINCODE_PATH"
  if chaincode_committed; then
    printf 'Chaincode %s is already committed on %s.\n' "$CHAINCODE_NAME" "$CHANNEL_NAME"
    return
  fi

  peer lifecycle chaincode package "$CHAINCODE_PACKAGE" \
    --path "$CHAINCODE_PATH" \
    --lang golang \
    --label "${CHAINCODE_NAME}_${CHAINCODE_VERSION}"
  local package_id
  package_id=$(peer lifecycle chaincode calculatepackageid "$CHAINCODE_PACKAGE")
  [[ "$package_id" == "${CHAINCODE_NAME}_${CHAINCODE_VERSION}:"* ]] ||
    fail "Could not calculate a valid chaincode package ID: $package_id"

  if ! peer lifecycle chaincode queryinstalled --output json |
    jq -e --arg package_id "$package_id" '.installed_chaincodes[]? | select(.package_id == $package_id)' >/dev/null; then
    peer lifecycle chaincode install "$CHAINCODE_PACKAGE"
  fi

  peer lifecycle chaincode approveformyorg \
    -o "localhost:${ORDERER_PORT}" \
    --ordererTLSHostnameOverride orderer.example.com \
    --tls --cafile "$ORDERER_CA" \
    --channelID "$CHANNEL_NAME" \
    --name "$CHAINCODE_NAME" \
    --version "$CHAINCODE_VERSION" \
    --package-id "$package_id" \
    --sequence "$CHAINCODE_SEQUENCE" \
    --signature-policy "OR('Org1MSP.peer')"

  peer lifecycle chaincode commit \
    -o "localhost:${ORDERER_PORT}" \
    --ordererTLSHostnameOverride orderer.example.com \
    --tls --cafile "$ORDERER_CA" \
    --channelID "$CHANNEL_NAME" \
    --name "$CHAINCODE_NAME" \
    --version "$CHAINCODE_VERSION" \
    --sequence "$CHAINCODE_SEQUENCE" \
    --signature-policy "OR('Org1MSP.peer')" \
    --peerAddresses "localhost:${PEER_PORT}" \
    --tlsRootCertFiles "$PEER_TLS_CA"
}

ensure_ready() {
  start_services
  create_channel
  deploy_chaincode
}

json_quote() {
  jq -cn --arg value "$1" '$value'
}

valid_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

invoke_asset() {
  local function=$1
  shift
  local constructor
  constructor=$(jq -cn --arg function "$function" --args '{function:$function,Args:$ARGS.positional}' "$@")

  peer_env
  orderer_env
  peer chaincode invoke \
    -o "localhost:${ORDERER_PORT}" \
    --ordererTLSHostnameOverride orderer.example.com \
    --tls --cafile "$ORDERER_CA" \
    -C "$CHANNEL_NAME" \
    -n "$CHAINCODE_NAME" \
    --peerAddresses "localhost:${PEER_PORT}" \
    --tlsRootCertFiles "$PEER_TLS_CA" \
    -c "$constructor" \
    --waitForEvent
}

main() {
  local command=${1:-help}
  shift || true
  [[ "$CHANNEL_NAME" =~ ^[a-z][a-z0-9.-]{0,248}$ ]] ||
    fail "Invalid channel name: use lowercase letters, digits, dots, and hyphens"
  case "$command" in
    up)
      ensure_ready
      printf 'Fabric POC is ready: channel=%s chaincode=%s\n' "$CHANNEL_NAME" "$CHAINCODE_NAME"
      ;;
    createChannel)
      start_services
      create_channel
      ;;
    restart)
      require_command docker
      if [[ "$(docker inspect -f '{{.State.Running}}' fabric-poc-orderer 2>/dev/null || true)" == true ]] &&
        [[ "$(docker inspect -f '{{.State.Running}}' fabric-poc-peer 2>/dev/null || true)" == true ]]; then
        compose restart
      fi
      ensure_ready
      printf 'Fabric POC restarted; channel and ledger data were preserved.\n'
      ;;
    down)
      compose down
      ;;
    create|update)
      [[ $# -eq 5 ]] || fail "Usage: $command <id> <color> <size> <owner> <value>"
      valid_integer "$3" || fail "Size must be a non-negative integer"
      valid_integer "$5" || fail "Appraised value must be a non-negative integer"
      ensure_ready
      local function=CreateAsset
      [[ "$command" == update ]] && function=UpdateAsset
      invoke_asset "$function" "$@"
      ;;
    delete)
      [[ $# -eq 1 ]] || fail "Usage: delete <id>"
      ensure_ready
      invoke_asset DeleteAsset "$1"
      ;;
    query)
      [[ $# -eq 1 ]] || fail "Usage: query <id>"
      ensure_ready
      peer_env
      peer chaincode query -C "$CHANNEL_NAME" -n "$CHAINCODE_NAME" \
        -c "{\"Args\":[\"ReadAsset\",$(json_quote "$1")]}"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage >&2
      fail "Unknown command: $command"
      ;;
  esac
}

main "$@"
