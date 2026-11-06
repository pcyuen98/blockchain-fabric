# Minimal Hyperledger Fabric CLI POC

This project runs a single-organization Fabric network with one peer and one
Raft orderer. The peer hosts the ledger and starts the Basic asset chaincode
when it is first invoked. There is no application server or CA container.

See [how.html](./how.html) for prerequisites, startup, restart, and asset
management commands.

```bash
./network.sh up
./network.sh create asset100 blue 10 Alice 500
./network.sh query asset100
./network.sh update asset100 green 12 Bob 750
./network.sh delete asset100
./network.sh restart
```

`down` stops the containers without removing their ledger volumes. `restart`
restarts running services and preserves the channel and asset state.
