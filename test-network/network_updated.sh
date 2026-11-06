#!/usr/bin/env bash
#
# Copyright IBM Corp All Rights Reserved
#
# SPDX-License-Identifier: Apache-2.0
#

# This script brings up a Hyperledger Fabric network for testing smart contracts
# and applications. The test network consists of two organizations with one
# peer each, and a single node Raft ordering service. Users can also use this
# script to create a channel deploy a chaincode on the channel
#
# prepending $PWD/../bin to PATH to ensure we are picking up the correct binaries
# this may be commented out to resolve installed version of tools if desired
#
# However using PWD in the path has the side effect that location that
# this script is run from is critical. To ease this, get the directory
# this script is actually in and infer location from there. (putting first)

ROOTDIR=$(cd "$(dirname "$0")" && pwd)
export PATH=${ROOTDIR}/../bin:${PWD}/../bin:$PATH
export FABRIC_CFG_PATH=${ROOTDIR}/configtx
export VERBOSE=false

# push to the required directory & set a trap to go back if needed
pushd ${ROOTDIR} > /dev/null
trap "popd > /dev/null" EXIT

. scripts/utils.sh

# Prefer Podman when running the Fabric test network inside the CentOS container.
if [[ -z "${CONTAINER_CLI:-}" ]] && command -v podman >/dev/null 2>&1; then
  CONTAINER_CLI=podman
fi
: ${CONTAINER_CLI:="docker"}
if command -v ${CONTAINER_CLI}-compose > /dev/null 2>&1; then
    : ${CONTAINER_CLI_COMPOSE:="${CONTAINER_CLI}-compose"}
else
    : ${CONTAINER_CLI_COMPOSE:="${CONTAINER_CLI} compose"}
fi
infoln "Using ${CONTAINER_CLI} and ${CONTAINER_CLI_COMPOSE}"

# Obtain CONTAINER_IDS and remove them
# This function is called when you bring a network down
function clearContainers() {
  infoln "Removing remaining containers"
  ${CONTAINER_CLI} rm -f $(${CONTAINER_CLI} ps -aq --filter label=service=hyperledger-fabric) 2>/dev/null || true
  ${CONTAINER_CLI} rm -f $(${CONTAINER_CLI} ps -aq --filter name='dev-peer*') 2>/dev/null || true
  ${CONTAINER_CLI} kill "$(${CONTAINER_CLI} ps -q --filter name=ccaas)" 2>/dev/null || true
}

# Delete any images that were generated as a part of this setup
# specifically the following images are often left behind:
# This function is called when you bring the network down
function removeUnwantedImages() {
  infoln "Removing generated chaincode docker images"
  ${CONTAINER_CLI} image rm -f $(${CONTAINER_CLI} images -aq --filter reference='dev-peer*') 2>/dev/null || true
}

# Versions of fabric known not to work with the test network
NONWORKING_VERSIONS="^1\.0\. ^1\.1\. ^1\.2\. ^1\.3\. ^1\.4\."

# Do some basic sanity checking to make sure that the appropriate versions of fabric
# binaries/images are available. In the future, additional checking for the presence
# of go or other items could be added.
function checkPrereqs() {
  ## Check if your have cloned the peer binaries and configuration files.
  peer version > /dev/null 2>&1

  if [[ $? -ne 0 || ! -d "../config" ]]; then
    errorln "Peer binary and configuration files not found.."
    errorln
    errorln "Follow the instructions in the Fabric docs to install the Fabric Binaries:"
    errorln "https://hyperledger-fabric.readthedocs.io/en/latest/install.html"
    exit 1
  fi
  # use the fabric peer container to see if the samples and binaries match your
  # docker images
  LOCAL_VERSION=$(peer version | sed -ne 's/^ Version: //p')
  DOCKER_IMAGE_VERSION=$(${CONTAINER_CLI} run --rm hyperledger/fabric-peer:latest peer version | sed -ne 's/^ Version: //p')

  infoln "LOCAL_VERSION=$LOCAL_VERSION"
  infoln "DOCKER_IMAGE_VERSION=$DOCKER_IMAGE_VERSION"

  if [ "$LOCAL_VERSION" != "$DOCKER_IMAGE_VERSION" ]; then
    warnln "Local fabric binaries and docker images are out of sync. This may cause problems."
  fi

  for UNSUPPORTED_VERSION in $NONWORKING_VERSIONS; do
    infoln "$LOCAL_VERSION" | grep -q $UNSUPPORTED_VERSION
    if [ $? -eq 0 ]; then
      fatalln "Local Fabric binary version of $LOCAL_VERSION does not match the versions supported by the test network."
    fi

    infoln "$DOCKER_IMAGE_VERSION" | grep -q $UNSUPPORTED_VERSION
    if [ $? -eq 0 ]; then
      fatalln "Fabric Docker image version of $DOCKER_IMAGE_VERSION does not match the versions supported by the test network."
    fi
  done

  ## check for cfssl binaries
  if [ "$CRYPTO" == "cfssl" ]; then
  
    cfssl version > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
      errorln "cfssl binary not found.."
      errorln
      errorln "Follow the instructions to install the cfssl and cfssljson binaries:"
      errorln "https://github.com/cloudflare/cfssl#installation"
      exit 1
    fi
  fi

  ## Check for fabric-ca
  if [ "$CRYPTO" == "Certificate Authorities" ]; then

    fabric-ca-client version > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
      errorln "fabric-ca-client binary not found.."
      errorln
      errorln "Follow the instructions in the Fabric docs to install the Fabric Binaries:"
      errorln "https://hyperledger-fabric.readthedocs.io/en/latest/install.html"
      exit 1
    fi
    CA_LOCAL_VERSION=$(fabric-ca-client version | sed -ne 's/ Version: //p')
    CA_DOCKER_IMAGE_VERSION=$(${CONTAINER_CLI} run --rm hyperledger/fabric-ca:latest fabric-ca-client version | sed -ne 's/ Version: //p' | head -1)
    infoln "CA_LOCAL_VERSION=$CA_LOCAL_VERSION"
    infoln "CA_DOCKER_IMAGE_VERSION=$CA_DOCKER_IMAGE_VERSION"

    if [ "$CA_LOCAL_VERSION" != "$CA_DOCKER_IMAGE_VERSION" ]; then
      warnln "Local fabric-ca binaries and docker images are out of sync. This may cause problems."
    fi
  fi
}

# Before you can bring up a network, each organization needs to generate the crypto
# material that will define that organization on the network. Because Hyperledger
# Fabric is a permissioned blockchain, each node and user on the network needs to
# use certificates and keys to sign and verify its actions. In addition, each user
# needs to belong to an organization that is recognized as a member of the network.
# You can use the Cryptogen tool or Fabric CAs to generate the organization crypto
# material.

# By default, the sample network uses cryptogen. Cryptogen is a tool that is
# meant for development and testing that can quickly create the certificates and keys
# that can be consumed by a Fabric network. The cryptogen tool consumes a series
# of configuration files for each organization in the "organizations/cryptogen"
# directory. Cryptogen uses the files to generate the crypto  material for each
# org in the "organizations" directory.

# You can also use Fabric CAs to generate the crypto material. CAs sign the certificates
# and keys that they generate to create a valid root of trust for each organization.
# The script uses Docker Compose to bring up three CAs, one for each peer organization
# and the ordering organization. The configuration file for creating the Fabric CA
# servers are in the "organizations/fabric-ca" directory. Within the same directory,
# the "registerEnroll.sh" script uses the Fabric CA client to create the identities,
# certificates, and MSP folders that are needed to create the test network in the
# "organizations/ordererOrganizations" directory.

# Create Organization crypto material using cryptogen or CAs
function createOrgs() {
  if [ -d "organizations/peerOrganizations" ]; then
    rm -Rf organizations/peerOrganizations && rm -Rf organizations/ordererOrganizations
  fi

  # Create crypto material using cryptogen
  if [ "$CRYPTO" == "cryptogen" ]; then
    which cryptogen
    if [ "$?" -ne 0 ]; then
      fatalln "cryptogen tool not found. exiting"
    fi
    infoln "Generating certificates using cryptogen tool"

    infoln "Creating Org1 Identities"

    set -x
    cryptogen generate --config=./organizations/cryptogen/crypto-config-org1.yaml --output="organizations"
    res=$?
    { set +x; } 2>/dev/null
    if [ $res -ne 0 ]; then
      fatalln "Failed to generate certificates..."
    fi

    infoln "Creating Org2 Identities"

    set -x
    cryptogen generate --config=./organizations/cryptogen/crypto-config-org2.yaml --output="organizations"
    res=$?
    { set +x; } 2>/dev/null
    if [ $res -ne 0 ]; then
      fatalln "Failed to generate certificates..."
    fi

    infoln "Creating Orderer Org Identities"

    set -x
    cryptogen generate --config=./organizations/cryptogen/crypto-config-orderer.yaml --output="organizations"
    res=$?
    { set +x; } 2>/dev/null
    if [ $res -ne 0 ]; then
      fatalln "Failed to generate certificates..."
    fi

  fi

  # Create crypto material using cfssl
  if [ "$CRYPTO" == "cfssl" ]; then

    . organizations/cfssl/registerEnroll.sh
    #function_name cert-type   CN   org
    peer_cert peer peer0.org1.example.com org1
    peer_cert admin Admin@org1.example.com org1

    infoln "Creating Org2 Identities"
    #function_name cert-type   CN   org
    peer_cert peer peer0.org2.example.com org2
    peer_cert admin Admin@org2.example.com org2

    infoln "Creating Orderer Org Identities"
    #function_name cert-type   CN   
    orderer_cert orderer orderer.example.com
    orderer_cert admin Admin@example.com

  fi 

  # Create crypto material using Fabric CA
  if [ "$CRYPTO" == "Certificate Authorities" ]; then
    infoln "Generating certificates using Fabric CA"
    ${CONTAINER_CLI_COMPOSE} -f compose/$COMPOSE_FILE_CA up -d 2>&1

    . organizations/fabric-ca/registerEnroll.sh

    # Make sure CA files have been created
    while :
    do
      if [ ! -f "organizations/fabric-ca/org1/tls-cert.pem" ]; then
        sleep 1
      else
        break
      fi
    done

    # Make sure CA service is initialized and can accept requests before making register and enroll calls
    export FABRIC_CA_CLIENT_HOME=${PWD}/organizations/peerOrganizations/org1.example.com/
    COUNTER=0
    rc=1
    while [[ $rc -ne 0 && $COUNTER -lt $MAX_RETRY ]]; do
      sleep 1
      set -x
      fabric-ca-client getcainfo -u https://admin:adminpw@localhost:7054 --caname ca-org1 --tls.certfiles "${PWD}/organizations/fabric-ca/org1/ca-cert.pem"
      res=$?
    { set +x; } 2>/dev/null
    rc=$res  # Update rc
    COUNTER=$((COUNTER + 1))
    done

    infoln "Creating Org1 Identities"

    createOrg1

    infoln "Creating Org2 Identities"

    createOrg2

    infoln "Creating Orderer Org Identities"

    createOrderer

  fi

  infoln "Generating CCP files for Org1 and Org2"
  ./organizations/ccp-generate.sh
}

# Once you create the organization crypto material, you need to create the
# genesis block of the application channel.

# The configtxgen tool is used to create the genesis block. Configtxgen consumes a
# "configtx.yaml" file that contains the definitions for the sample network. The
# genesis block is defined using the "ChannelUsingRaft" profile at the bottom
# of the file. This profile defines an application channel consisting of our two Peer Orgs.
# The peer and ordering organizations are defined in the "Profiles" section at the
# top of the file. As part of each organization profile, the file points to the
# location of the MSP directory for each member. This MSP is used to create the channel
# MSP that defines the root of trust for each organization. In essence, the channel
# MSP allows the nodes and users to be recognized as network members.
#
# If you receive the following warning, it can be safely ignored:
#
# [bccsp] GetDefault -> WARN 001 Before using BCCSP, please call InitFactories(). Falling back to bootBCCSP.
#
# You can ignore the logs regarding intermediate certs, we are not using them in
# this crypto implementation.

# After we create the org crypto material and the application channel genesis block,
# we can now bring up the peers and ordering service. By default, the base
# file for creating the network is "docker-compose-test-net.yaml" in the ``docker``
# folder. This file defines the environment variables and file mounts that
# point the crypto material and genesis block that were created in earlier.

# Bring up the peer and orderer nodes using docker compose.
function networkUp() {

  checkPrereqs

  # generate artifacts if they don't exist
  if [ ! -d "organizations/peerOrganizations" ]; then
    createOrgs
  fi

  COMPOSE_FILES="-f compose/${COMPOSE_FILE_BASE} -f compose/${CONTAINER_CLI}/${CONTAINER_CLI}-${COMPOSE_FILE_BASE}"

  if [ "${DATABASE}" == "couchdb" ]; then
    COMPOSE_FILES="${COMPOSE_FILES} -f compose/${COMPOSE_FILE_COUCH}"
  fi

  DOCKER_SOCK="${DOCKER_SOCK}" ${CONTAINER_CLI_COMPOSE} ${COMPOSE_FILES} up -d 2>&1 || return 1

  $CONTAINER_CLI ps -a
  if [ $? -ne 0 ]; then
    fatalln "Unable to start network"
  fi
}

# Non-destructive recovery for the Podman-in-Docker Fabric test network.
# Never remove containers, volumes, certificates or ledgers here.
function ensurePodmanAPI() {
  [[ "$CONTAINER_CLI" == "podman" ]] || return 0
  local socket=/run/podman/podman.sock
  if curl -fsS --max-time 2 --unix-socket "$socket" http://localhost/_ping >/dev/null 2>&1; then
    infoln "Podman API ready"
    return 0
  fi
  mkdir -p /run/podman
  infoln "Starting Podman Docker-compatible API"
  nohup podman system service --time=0 "unix://$socket" \
    >/tmp/fabric-podman-api.log 2>&1 </dev/null &
  local i
  for ((i=0; i<20; i++)); do
    if curl -fsS --max-time 2 --unix-socket "$socket" http://localhost/_ping >/dev/null 2>&1; then
      infoln "Podman API ready"
      return 0
    fi
    sleep 1
  done
  errorln "Podman API unavailable; see /tmp/fabric-podman-api.log"
  return 1
}

function containerExists() {
  "$CONTAINER_CLI" container exists "$1" >/dev/null 2>&1
}

# Check real process state rather than trusting Podman's cached "running" flag.
function containerHealthy() {
  local name=$1 pid
  [[ "$("$CONTAINER_CLI" inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == true ]] || return 1
  pid=$("$CONTAINER_CLI" inspect -f '{{.State.Pid}}' "$name" 2>/dev/null) || return 1
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 && -d "/proc/$pid" ]] || return 1
  # A valid PID alone is insufficient after nested Podman loses its namespace.
  "$CONTAINER_CLI" exec "$name" true >/dev/null 2>&1
}

function waitForContainer() {
  local name=$1 i
  for ((i=0; i<15; i++)); do
    containerHealthy "$name" && return 0
    sleep 1
  done
  return 1
}

function showContainerDiagnostics() {
  local name=$1
  warnln "Diagnostics for $name:"
  "$CONTAINER_CLI" inspect -f 'Status={{.State.Status}} PID={{.State.Pid}} ExitCode={{.State.ExitCode}}' "$name" 2>&1 || true
  "$CONTAINER_CLI" logs --tail 35 "$name" 2>&1 || true
}

# Do not force-restart a healthy container: this avoids triggering netavark
# cleanup errors and preserves live chaincode services. Recover only broken ones.
function recoverContainer() {
  local name=$1 attempt
  containerExists "$name" || { errorln "Missing container: $name"; return 1; }
  if containerHealthy "$name"; then
    infoln "Already healthy: $name"
    return 0
  fi
  infoln "Recovering stopped/stale service: $name"
  # A failed restart may transition stale state to exited; start it afterwards.
  for attempt in 1 2; do
    if [[ "$("$CONTAINER_CLI" inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == true ]]; then
      "$CONTAINER_CLI" restart --time 5 "$name" || warnln "Restart attempt $attempt failed: $name"
    else
      "$CONTAINER_CLI" start "$name" || warnln "Start attempt $attempt failed: $name"
    fi
    if waitForContainer "$name"; then
      infoln "Recovered: $name"
      return 0
    fi
    # If a container is reported running but cannot exec, avoid deleting it.
    warnln "Attempt $attempt did not produce a healthy service: $name"
  done
  showContainerDiagnostics "$name"
  errorln "Unable to recover $name without destructive container operations"
  return 1
}

function waitForPort() {
  local port=$1 i
  for ((i=0; i<30; i++)); do
    (echo >/dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1 && return 0
    sleep 1
  done
  errorln "Port $port not reachable on 127.0.0.1"
  return 1
}

function ensureFabricServices() {
  ensurePodmanAPI || return 1
  local name missing=false
  for name in orderer.example.com peer0.org1.example.com peer0.org2.example.com; do
    containerExists "$name" || missing=true
  done
  if [[ "$missing" == true ]]; then
    infoln "Creating missing Fabric nodes with compose"
    networkUp || return 1
  fi
  # Orderer must be reachable before peers are checked.
  recoverContainer orderer.example.com || return 1
  waitForPort 7050 || { showContainerDiagnostics orderer.example.com; return 1; }
  waitForPort 7053 || { showContainerDiagnostics orderer.example.com; return 1; }
  recoverContainer peer0.org1.example.com || return 1
  recoverContainer peer0.org2.example.com || return 1
  waitForPort 7051 || { showContainerDiagnostics peer0.org1.example.com; return 1; }
  waitForPort 9051 || { showContainerDiagnostics peer0.org2.example.com; return 1; }
  # Chaincode is launched by Fabric on demand. Do not restart running chaincode.
  # Existing stopped chaincode containers can be restarted opportunistically.
  if [[ "$CONTAINER_CLI" == podman ]]; then
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      if ! containerHealthy "$name"; then
        recoverContainer "$name" || warnln "Chaincode $name may be launched on demand"
      fi
    done < <("$CONTAINER_CLI" ps -a --format '{{.Names}}' | grep '^dev-peer' || true)
  fi
  infoln "Fabric services and published ports ready"
}

function setChannelPeerEnv() {
  local org=$1 port=$2
  export FABRIC_CFG_PATH="${ROOTDIR}/../config"
  export CORE_PEER_LOCALMSPID="Org${org}MSP"
  export CORE_PEER_MSPCONFIGPATH="${ROOTDIR}/organizations/peerOrganizations/org${org}.example.com/users/Admin@org${org}.example.com/msp"
  export CORE_PEER_TLS_ENABLED=true
  export CORE_PEER_ADDRESS="127.0.0.1:${port}"
  export CORE_PEER_TLS_SERVERHOSTOVERRIDE="peer0.org${org}.example.com"
  export CORE_PEER_TLS_ROOTCERT_FILE="${ROOTDIR}/organizations/peerOrganizations/org${org}.example.com/peers/peer0.org${org}.example.com/tls/ca.crt"
}

function peerHasChannel() {
  local org=$1 port=$2 channel=$3 output
  setChannelPeerEnv "$org" "$port"
  output=$(peer channel list 2>&1) || { errorln "Cannot query Org${org} channels: $output"; return 2; }
  grep -Fxq "$channel" <<< "$output"
}

function ensureChannel() {
  local channel=$1 bft_true=$2 rc
  [[ -n "$channel" ]] || { errorln "Channel name is empty"; return 1; }
  peerHasChannel 1 7051 "$channel"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    infoln "Channel '$channel' already exists on Org1; preserving ledger"
  elif [[ "$rc" -eq 2 ]]; then
    return 1
  else
    # The channel might exist on the orderer or Org2 but not Org1.
    # Do not blindly recreate it and risk conflicting genesis blocks.
    peerHasChannel 2 9051 "$channel"
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
      errorln "Channel '$channel' exists on Org2 but not Org1; refusing to recreate it. Join Org1 using its existing block."
      return 1
    elif [[ "$rc" -eq 2 ]]; then
      return 1
    fi
    infoln "Channel '$channel' not joined on either peer; invoking channel creation"
    # Channel creation uses configtxgen and the original Fabric helper scripts.
    # Those scripts may still need localhost/IPv4 fixes in some environments.
    export FABRIC_CFG_PATH="${ROOTDIR}/configtx"
    scripts/createChannel.sh "$channel" "$CLI_DELAY" "$MAX_RETRY" "$VERBOSE" "$bft_true" || return 1
  fi
  peerHasChannel 1 7051 "$channel" || { errorln "Org1 has not joined '$channel'"; return 1; }
  peerHasChannel 2 9051 "$channel" || { errorln "Org2 has not joined '$channel'"; return 1; }
  infoln "Verified channel '$channel' on Org1 and Org2"
}

function createChannel() {
  ensureFabricServices || return 1
  ensureChannel "$CHANNEL_NAME" "$1"
}


## Call the script to deploy a chaincode to the channel
function deployCC() {
  scripts/deployCC.sh $CHANNEL_NAME $CC_NAME $CC_SRC_PATH $CC_SRC_LANGUAGE $CC_VERSION $CC_SEQUENCE $CC_INIT_FCN $CC_END_POLICY $CC_COLL_CONFIG $CLI_DELAY $MAX_RETRY $VERBOSE

  if [ $? -ne 0 ]; then
    fatalln "Deploying chaincode failed"
  fi
}

## Call the script to deploy a chaincode to the channel
function deployCCAAS() {
  scripts/deployCCAAS.sh $CHANNEL_NAME $CC_NAME $CC_SRC_PATH $CCAAS_DOCKER_RUN $CC_VERSION $CC_SEQUENCE $CC_INIT_FCN $CC_END_POLICY $CC_COLL_CONFIG $CLI_DELAY $MAX_RETRY $VERBOSE $CCAAS_DOCKER_RUN

  if [ $? -ne 0 ]; then
    fatalln "Deploying chaincode-as-a-service failed"
  fi
}

## Call the script to package the chaincode
function packageChaincode() {

  infoln "Packaging chaincode"

  scripts/packageCC.sh $CC_NAME $CC_SRC_PATH $CC_SRC_LANGUAGE $CC_VERSION true

  if [ $? -ne 0 ]; then
    fatalln "Packaging the chaincode failed"
  fi

}

## Call the script to list installed and committed chaincode on a peer
function listChaincode() {

  export FABRIC_CFG_PATH=${PWD}/../config

  . scripts/envVar.sh
  . scripts/ccutils.sh

  setGlobals $ORG

  println
  queryInstalledOnPeer
  println

  listAllCommitted

}

## Call the script to invoke 
function invokeChaincode() {

  export FABRIC_CFG_PATH=${PWD}/../config

  . scripts/envVar.sh
  . scripts/ccutils.sh

  setGlobals $ORG

  chaincodeInvoke $ORG $CHANNEL_NAME $CC_NAME $CC_INVOKE_CONSTRUCTOR

}

## Call the script to query chaincode 
function queryChaincode() {

  export FABRIC_CFG_PATH=${PWD}/../config
  
  . scripts/envVar.sh
  . scripts/ccutils.sh

  setGlobals $ORG

  chaincodeQuery $ORG $CHANNEL_NAME $CC_NAME $CC_QUERY_CONSTRUCTOR

}


# Tear down running network
function networkDown() {
  local temp_compose=$COMPOSE_FILE_BASE
  COMPOSE_FILE_BASE=compose-bft-test-net.yaml
  COMPOSE_BASE_FILES="-f compose/${COMPOSE_FILE_BASE} -f compose/${CONTAINER_CLI}/${CONTAINER_CLI}-${COMPOSE_FILE_BASE}"
  COMPOSE_COUCH_FILES="-f compose/${COMPOSE_FILE_COUCH}"
  COMPOSE_CA_FILES="-f compose/${COMPOSE_FILE_CA}"
  COMPOSE_FILES="${COMPOSE_BASE_FILES} ${COMPOSE_COUCH_FILES} ${COMPOSE_CA_FILES}"

  # stop org3 containers also in addition to org1 and org2, in case we were running sample to add org3
  COMPOSE_ORG3_BASE_FILES="-f addOrg3/compose/${COMPOSE_FILE_ORG3_BASE} -f addOrg3/compose/${CONTAINER_CLI}/${CONTAINER_CLI}-${COMPOSE_FILE_ORG3_BASE}"
  COMPOSE_ORG3_COUCH_FILES="-f addOrg3/compose/${COMPOSE_FILE_ORG3_COUCH} -f addOrg3/compose/${CONTAINER_CLI}/${CONTAINER_CLI}-${COMPOSE_FILE_ORG3_COUCH}"
  COMPOSE_ORG3_CA_FILES="-f addOrg3/compose/${COMPOSE_FILE_ORG3_CA} -f addOrg3/compose/${CONTAINER_CLI}/${CONTAINER_CLI}-${COMPOSE_FILE_ORG3_CA}"
  COMPOSE_ORG3_FILES="${COMPOSE_ORG3_BASE_FILES} ${COMPOSE_ORG3_COUCH_FILES} ${COMPOSE_ORG3_CA_FILES}"

  if [ "${CONTAINER_CLI}" == "docker" ]; then
    DOCKER_SOCK=$DOCKER_SOCK ${CONTAINER_CLI_COMPOSE} ${COMPOSE_FILES} ${COMPOSE_ORG3_FILES} down --volumes --remove-orphans
  elif [ "${CONTAINER_CLI}" == "podman" ]; then
    ${CONTAINER_CLI_COMPOSE} ${COMPOSE_FILES} ${COMPOSE_ORG3_FILES} down --volumes
  else
    fatalln "Container CLI  ${CONTAINER_CLI} not supported"
  fi

  COMPOSE_FILE_BASE=$temp_compose

  # Don't remove the generated artifacts -- note, the ledgers are always removed
  if [ "$MODE" != "restart" ]; then
    # Bring down the network, deleting the volumes
    ${CONTAINER_CLI} volume rm docker_orderer.example.com docker_peer0.org1.example.com docker_peer0.org2.example.com
    #Cleanup the chaincode containers
    clearContainers
    #Cleanup images
    removeUnwantedImages
    # remove orderer block and other channel configuration transactions and certs
    ${CONTAINER_CLI} run --rm -v "$(pwd):/data" busybox sh -c 'cd /data && rm -rf system-genesis-block/*.block organizations/peerOrganizations organizations/ordererOrganizations'
    ## remove fabric ca artifacts
    ${CONTAINER_CLI} run --rm -v "$(pwd):/data" busybox sh -c 'cd /data && rm -rf organizations/fabric-ca/org1/msp organizations/fabric-ca/org1/tls-cert.pem organizations/fabric-ca/org1/ca-cert.pem organizations/fabric-ca/org1/IssuerPublicKey organizations/fabric-ca/org1/IssuerRevocationPublicKey organizations/fabric-ca/org1/fabric-ca-server.db'
    ${CONTAINER_CLI} run --rm -v "$(pwd):/data" busybox sh -c 'cd /data && rm -rf organizations/fabric-ca/org2/msp organizations/fabric-ca/org2/tls-cert.pem organizations/fabric-ca/org2/ca-cert.pem organizations/fabric-ca/org2/IssuerPublicKey organizations/fabric-ca/org2/IssuerRevocationPublicKey organizations/fabric-ca/org2/fabric-ca-server.db'
    ${CONTAINER_CLI} run --rm -v "$(pwd):/data" busybox sh -c 'cd /data && rm -rf organizations/fabric-ca/ordererOrg/msp organizations/fabric-ca/ordererOrg/tls-cert.pem organizations/fabric-ca/ordererOrg/ca-cert.pem organizations/fabric-ca/ordererOrg/IssuerPublicKey organizations/fabric-ca/ordererOrg/IssuerRevocationPublicKey organizations/fabric-ca/ordererOrg/fabric-ca-server.db'
    ${CONTAINER_CLI} run --rm -v "$(pwd):/data" busybox sh -c 'cd /data && rm -rf addOrg3/fabric-ca/org3/msp addOrg3/fabric-ca/org3/tls-cert.pem addOrg3/fabric-ca/org3/ca-cert.pem addOrg3/fabric-ca/org3/IssuerPublicKey addOrg3/fabric-ca/org3/IssuerRevocationPublicKey addOrg3/fabric-ca/org3/fabric-ca-server.db'
    # remove channel and script artifacts
    ${CONTAINER_CLI} run --rm -v "$(pwd):/data" busybox sh -c 'cd /data && rm -rf channel-artifacts log.txt *.tar.gz'
  fi
}

. ./network.config

# use this as the default docker-compose yaml definition
COMPOSE_FILE_BASE=compose-test-net.yaml
# docker-compose.yaml file if you are using couchdb
COMPOSE_FILE_COUCH=compose-couch.yaml
# certificate authorities compose file
COMPOSE_FILE_CA=compose-ca.yaml
# use this as the default docker-compose yaml definition for org3
COMPOSE_FILE_ORG3_BASE=compose-org3.yaml
# use this as the docker compose couch file for org3
COMPOSE_FILE_ORG3_COUCH=compose-couch-org3.yaml
# certificate authorities compose file
COMPOSE_FILE_ORG3_CA=compose-ca-org3.yaml
#

# Get docker sock path from environment variable
SOCK="${DOCKER_HOST:-/var/run/docker.sock}"
DOCKER_SOCK="${SOCK##unix://}"

# BFT activated flag
BFT=0

# Parse commandline args

## Parse mode
if [[ $# -lt 1 ]] ; then
  printHelp
  exit 0
else
  MODE=$1
  shift
fi

## if no parameters are passed, show the help for cc
if [ "$MODE" == "cc" ] && [[ $# -lt 1 ]]; then
  printHelp $MODE
  exit 0
fi

# parse subcommands if used
if [[ $# -ge 1 ]] ; then
  key="$1"
  # check for the createChannel subcommand
  if [[ "$key" == "createChannel" ]]; then
      export MODE="createChannel"
      shift
  # check for the cc command
  elif [[ "$MODE" == "cc" ]]; then
    if [ "$1" != "-h" ]; then
      export SUBCOMMAND=$key
      shift
    fi
  fi
fi


# parse flags

while [[ $# -ge 1 ]] ; do
  key="$1"
  case $key in
  -h )
    printHelp $MODE
    exit 0
    ;;
  -c )
    CHANNEL_NAME="$2"
    shift
    ;;
  -bft )
    BFT=1
    ;;
  -ca )
    CRYPTO="Certificate Authorities"
    ;;
  -cfssl )
    CRYPTO="cfssl"
    ;;
  -r )
    MAX_RETRY="$2"
    shift
    ;;
  -d )
    CLI_DELAY="$2"
    shift
    ;;
  -s )
    DATABASE="$2"
    shift
    ;;
  -ccl )
    CC_SRC_LANGUAGE="$2"
    shift
    ;;
  -ccn )
    CC_NAME="$2"
    shift
    ;;
  -ccv )
    CC_VERSION="$2"
    shift
    ;;
  -ccs )
    CC_SEQUENCE="$2"
    shift
    ;;
  -ccp )
    CC_SRC_PATH="$2"
    shift
    ;;
  -ccep )
    CC_END_POLICY="$2"
    shift
    ;;
  -cccg )
    CC_COLL_CONFIG="$2"
    shift
    ;;
  -cci )
    CC_INIT_FCN="$2"
    shift
    ;;
  -ccaasdocker )
    CCAAS_DOCKER_RUN="$2"
    shift
    ;;
  -verbose )
    VERBOSE=true
    ;;
  -org )
    ORG="$2"
    shift
    ;;
  -i )
    IMAGETAG="$2"
    shift
    ;;
  -cai )
    CA_IMAGETAG="$2"
    shift
    ;;
  -ccic )
    CC_INVOKE_CONSTRUCTOR="$2"
    shift
    ;;
  -ccqc )
    CC_QUERY_CONSTRUCTOR="$2"
    shift
    ;;    
  * )
    errorln "Unknown flag: $key"
    printHelp
    exit 1
    ;;
  esac
  shift
done

if [ $BFT -eq 1 ]; then
  export FABRIC_CFG_PATH=${PWD}/bft-config
  COMPOSE_FILE_BASE=compose-bft-test-net.yaml
fi

# Are we generating crypto material with this command?
if [ ! -d "organizations/peerOrganizations" ]; then
  CRYPTO_MODE="with crypto from '${CRYPTO}'"
else
  CRYPTO_MODE=""
fi

# Determine mode of operation and printing out what we asked for
if [ "$MODE" == "prereq" ]; then
  infoln "Installing binaries and fabric images. Fabric Version: ${IMAGETAG}  Fabric CA Version: ${CA_IMAGETAG}"
  installPrereqs
elif [ "$MODE" == "up" ]; then
  infoln "Starting nodes with CLI timeout of '${MAX_RETRY}' tries and CLI delay of '${CLI_DELAY}' seconds and using database '${DATABASE}' ${CRYPTO_MODE}"
  ensureFabricServices || exit 1
elif [ "$MODE" == "createChannel" ]; then
  infoln "Creating channel '${CHANNEL_NAME}'."
  infoln "If network is not up, starting nodes with CLI timeout of '${MAX_RETRY}' tries and CLI delay of '${CLI_DELAY}' seconds and using database '${DATABASE} ${CRYPTO_MODE}"
  createChannel "$BFT" || exit 1
elif [ "$MODE" == "down" ]; then
  infoln "Stopping network"
  networkDown
elif [ "$MODE" == "restart" ]; then
  infoln "Restarting network"
  ensureFabricServices || exit 1
  ensureChannel "${CHANNEL_NAME:-mychannel}" "$BFT" || exit 1
elif [ "$MODE" == "deployCC" ]; then
  infoln "deploying chaincode on channel '${CHANNEL_NAME}'"
  deployCC
elif [ "$MODE" == "deployCCAAS" ]; then
  infoln "deploying chaincode-as-a-service on channel '${CHANNEL_NAME}'"
  deployCCAAS
elif [ "$MODE" == "cc" ] && [ "$SUBCOMMAND" == "package" ]; then
  packageChaincode
elif [ "$MODE" == "cc" ] && [ "$SUBCOMMAND" == "list" ]; then
  listChaincode
elif [ "$MODE" == "cc" ] && [ "$SUBCOMMAND" == "invoke" ]; then
  invokeChaincode
elif [ "$MODE" == "cc" ] && [ "$SUBCOMMAND" == "query" ]; then
  queryChaincode
else
  printHelp
  exit 1
fi
