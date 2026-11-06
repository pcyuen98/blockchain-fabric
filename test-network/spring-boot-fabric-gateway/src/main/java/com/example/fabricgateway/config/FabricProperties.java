package com.example.fabricgateway.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.util.ArrayList;
import java.util.List;

@ConfigurationProperties(prefix = "fabric")
public class FabricProperties {
    private String mspId = "Org1MSP";
    private String channelName = "mychannel";
    private String chaincodeName = "basic";
    private List<String> endorsingOrganizations = new ArrayList<>(List.of("Org1MSP", "Org2MSP"));
    private String peerEndpoint = "localhost:7051";
    private String peerOverrideAuthority = "peer0.org1.example.com";
    private String cryptoPath = "../organizations/peerOrganizations/org1.example.com";

    public String getMspId() {
        return mspId;
    }

    public void setMspId(String mspId) {
        this.mspId = mspId;
    }

    public String getChannelName() {
        return channelName;
    }

    public void setChannelName(String channelName) {
        this.channelName = channelName;
    }

    public String getChaincodeName() {
        return chaincodeName;
    }

    public void setChaincodeName(String chaincodeName) {
        this.chaincodeName = chaincodeName;
    }

    public List<String> getEndorsingOrganizations() {
        return endorsingOrganizations;
    }

    public void setEndorsingOrganizations(List<String> endorsingOrganizations) {
        this.endorsingOrganizations = endorsingOrganizations;
    }

    public String getPeerEndpoint() {
        return peerEndpoint;
    }

    public void setPeerEndpoint(String peerEndpoint) {
        this.peerEndpoint = peerEndpoint;
    }

    public String getPeerOverrideAuthority() {
        return peerOverrideAuthority;
    }

    public void setPeerOverrideAuthority(String peerOverrideAuthority) {
        this.peerOverrideAuthority = peerOverrideAuthority;
    }

    public String getCryptoPath() {
        return cryptoPath;
    }

    public void setCryptoPath(String cryptoPath) {
        this.cryptoPath = cryptoPath;
    }
}
