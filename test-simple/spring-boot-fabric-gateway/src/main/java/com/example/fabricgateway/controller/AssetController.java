package com.example.fabricgateway.controller;

import com.example.fabricgateway.service.AssetTransferService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/api")
@Tag(name = "Assets", description = "Asset Transfer Basic chaincode operations")
public class AssetController {
    private final AssetTransferService assetTransferService;

    public AssetController(AssetTransferService assetTransferService) {
        this.assetTransferService = assetTransferService;
    }

    @GetMapping("/health")
    public Map<String, String> health() {
        return Map.of("status", "UP");
    }

    @PostMapping("/assets/init")
    @Operation(summary = "Initialize the asset ledger")
    public Map<String, String> initLedger() {
        return Map.of("status", "OK", "message", assetTransferService.initLedger());
    }

    @GetMapping("/assets")
    public List<Map<String, Object>> getAllAssets() {
        return assetTransferService.getAllAssets();
    }

    @GetMapping("/assets/{id}")
    public Map<String, Object> readAsset(@PathVariable("id") String id) {
        return assetTransferService.readAsset(id);
    }

    @PostMapping("/assets")
    public Map<String, Object> createAsset(@RequestBody CreateAssetRequest request) {
        String result = assetTransferService.createAsset(
                request.getId(),
                request.getColor(),
                request.getSize(),
                request.getOwner(),
                request.getAppraisedValue()
        );

        var payload = new LinkedHashMap<String, Object>();
        payload.put("assetId", request.getId());
        payload.put("status", "created");
        payload.put("result", result);
        return payload;
    }

    @PutMapping("/assets/{id}/transfer")
    public Map<String, Object> transferAsset(@PathVariable("id") String id, @RequestBody TransferAssetRequest request) {
        String result = assetTransferService.transferAsset(id, request.getNewOwner());

        var payload = new LinkedHashMap<String, Object>();
        payload.put("assetId", id);
        payload.put("newOwner", request.getNewOwner());
        payload.put("result", result);
        return payload;
    }

    public static class CreateAssetRequest {
        private String id;
        private String color;
        private String size;
        private String owner;
        private String appraisedValue;

        public String getId() {
            return id;
        }

        public void setId(String id) {
            this.id = id;
        }

        public String getColor() {
            return color;
        }

        public void setColor(String color) {
            this.color = color;
        }

        public String getSize() {
            return size;
        }

        public void setSize(String size) {
            this.size = size;
        }

        public String getOwner() {
            return owner;
        }

        public void setOwner(String owner) {
            this.owner = owner;
        }

        public String getAppraisedValue() {
            return appraisedValue;
        }

        public void setAppraisedValue(String appraisedValue) {
            this.appraisedValue = appraisedValue;
        }
    }

    public static class TransferAssetRequest {
        private String newOwner;

        public String getNewOwner() {
            return newOwner;
        }

        public void setNewOwner(String newOwner) {
            this.newOwner = newOwner;
        }
    }
}
