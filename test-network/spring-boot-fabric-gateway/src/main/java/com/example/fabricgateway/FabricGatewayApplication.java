package com.example.fabricgateway;

import com.example.fabricgateway.config.FabricProperties;
import io.swagger.v3.oas.annotations.OpenAPIDefinition;
import io.swagger.v3.oas.annotations.info.Info;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;

@SpringBootApplication
@EnableConfigurationProperties(FabricProperties.class)
@OpenAPIDefinition(info = @Info(
        title = "Fabric Asset Transfer API",
        version = "1.0",
        description = "REST API for the Hyperledger Fabric asset-transfer-basic chaincode"
))
public class FabricGatewayApplication {
    public static void main(String[] args) {
        SpringApplication.run(FabricGatewayApplication.class, args);
    }
}
