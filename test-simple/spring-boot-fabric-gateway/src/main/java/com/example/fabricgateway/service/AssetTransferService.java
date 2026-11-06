package com.example.fabricgateway.service;

import com.example.fabricgateway.config.FabricProperties;
import com.google.gson.Gson;
import com.google.gson.JsonParser;
import com.google.gson.reflect.TypeToken;
import io.grpc.Grpc;
import io.grpc.ManagedChannel;
import io.grpc.TlsChannelCredentials;
import org.hyperledger.fabric.client.Contract;
import org.hyperledger.fabric.client.CommitException;
import org.hyperledger.fabric.client.CommitStatusException;
import org.hyperledger.fabric.client.EndorseException;
import org.hyperledger.fabric.client.Gateway;
import org.hyperledger.fabric.client.Hash;
import org.hyperledger.fabric.client.SubmitException;
import org.hyperledger.fabric.client.identity.Identities;
import org.hyperledger.fabric.client.identity.Identity;
import org.hyperledger.fabric.client.identity.Signer;
import org.hyperledger.fabric.client.identity.Signers;
import org.hyperledger.fabric.client.identity.X509Identity;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.lang.reflect.Type;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.InvalidKeyException;
import java.security.cert.CertificateException;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

@Service
public class AssetTransferService {
    private static final Gson GSON = new Gson();
    private static final Type MAP_TYPE = new TypeToken<Map<String, Object>>() {}.getType();
    private static final Type LIST_MAP_TYPE = new TypeToken<List<Map<String, Object>>>() {}.getType();

    private final Gateway gateway;
    private final FabricProperties properties;

    public AssetTransferService(FabricProperties properties) throws Exception {
        this.properties = properties;
        this.gateway = createGateway();
    }

    private Gateway createGateway() throws Exception {
        var channel = newGrpcConnection();
        try {
            return Gateway.newInstance()
                    .identity(newIdentity())
                    .signer(newSigner())
                    .hash(Hash.SHA256)
                    .connection(channel)
                    .evaluateOptions(options -> options.withDeadlineAfter(5, TimeUnit.SECONDS))
                    .endorseOptions(options -> options.withDeadlineAfter(15, TimeUnit.SECONDS))
                    .submitOptions(options -> options.withDeadlineAfter(5, TimeUnit.SECONDS))
                    .commitStatusOptions(options -> options.withDeadlineAfter(1, TimeUnit.MINUTES))
                    .connect();
        } catch (Exception e) {
            channel.shutdownNow().awaitTermination(5, TimeUnit.SECONDS);
            throw e;
        }
    }

    private ManagedChannel newGrpcConnection() throws IOException {
        var tlsCertPath = Path.of(properties.getCryptoPath()).resolve("peers/peer0.org1.example.com/tls/ca.crt");
        var credentials = TlsChannelCredentials.newBuilder()
                .trustManager(tlsCertPath.toFile())
                .build();

        return Grpc.newChannelBuilder(properties.getPeerEndpoint(), credentials)
                .overrideAuthority(properties.getPeerOverrideAuthority())
                .build();
    }

    private Identity newIdentity() throws IOException, CertificateException {
        var certDir = Path.of(properties.getCryptoPath())
                .resolve("users/User1@org1.example.com/msp/signcerts");
        try (var certReader = Files.newBufferedReader(firstFileInDirectory(certDir))) {
            var certificate = Identities.readX509Certificate(certReader);
            return new X509Identity(properties.getMspId(), certificate);
        }
    }

    private Signer newSigner() throws IOException, InvalidKeyException {
        var keyDir = Path.of(properties.getCryptoPath())
                .resolve("users/User1@org1.example.com/msp/keystore");
        try (var keyReader = Files.newBufferedReader(firstFileInDirectory(keyDir))) {
            var privateKey = Identities.readPrivateKey(keyReader);
            return Signers.newPrivateKeySigner(privateKey);
        }
    }

    private static Path firstFileInDirectory(Path dir) throws IOException {
        try (var stream = Files.list(dir)) {
            return stream.findFirst()
                    .orElseThrow(() -> new IllegalStateException("No file found in " + dir));
        }
    }

    public String initLedger() {
        try {
            submitTransaction("InitLedger");
            return "Ledger initialized successfully";
        } catch (Exception e) {
            throw new IllegalStateException("Unable to initialize ledger", e);
        }
    }

    public List<Map<String, Object>> getAllAssets() {
        byte[] result = evaluateTransaction("GetAllAssets");
        return GSON.fromJson(new String(result, StandardCharsets.UTF_8), LIST_MAP_TYPE);
    }

    public Map<String, Object> readAsset(String assetId) {
        byte[] result = evaluateTransaction("ReadAsset", assetId);
        return GSON.fromJson(new String(result, StandardCharsets.UTF_8), MAP_TYPE);
    }

    public String createAsset(String assetId, String color, String size, String owner, String appraisedValue) {
        try {
            return new String(
                    submitTransaction("CreateAsset", assetId, color, size, owner, appraisedValue),
                    StandardCharsets.UTF_8
            );
        } catch (Exception e) {
            throw new IllegalStateException("Unable to create asset: " + assetId, e);
        }
    }

    public String transferAsset(String assetId, String newOwner) {
        try {
            return new String(
                    submitTransaction("TransferAsset", assetId, newOwner),
                    StandardCharsets.UTF_8
            );
        } catch (Exception e) {
            throw new IllegalStateException("Unable to transfer asset: " + assetId, e);
        }
    }

    public String prettyPrint(String json) {
        return JsonParser.parseString(json).toString();
    }

    private Contract getContract() {
        return gateway.getNetwork(properties.getChannelName())
                .getContract(properties.getChaincodeName());
    }

    private byte[] submitTransaction(String functionName, String... args)
            throws EndorseException, SubmitException, CommitStatusException, CommitException {
        var proposal = getContract().newProposal(functionName)
                .addArguments(args)
                .setEndorsingOrganizations(properties.getEndorsingOrganizations().toArray(String[]::new))
                .build();
        return proposal.endorse().submit();
    }

    private byte[] evaluateTransaction(String functionName, String... args) {
        try {
            if (args.length == 0) {
                return getContract().evaluateTransaction(functionName);
            }
            return getContract().evaluateTransaction(functionName, args);
        } catch (Exception e) {
            throw new IllegalStateException("Unable to evaluate transaction: " + functionName, e);
        }
    }
}
