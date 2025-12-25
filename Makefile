# SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
# Makefile for deploying and managing SwapVMRouter contracts
#
# Conditionally include .env or .env.automation based on OPS_LAUNCH_MODE
ifeq ($(OPS_LAUNCH_MODE),auto)
-include .env.automation
else
-include .env
endif
export

CURRENT_DIR:=$(shell pwd)

FILE_CONSTANTS_JSON:=$(CURRENT_DIR)/config/constants.json

OPS_NETWORK := $(subst ",,$(OPS_NETWORK))
OPS_CHAIN_ID := $(subst ",,$(OPS_CHAIN_ID))

PREFIX:=$(shell echo "$(OPS_NETWORK)" | sed -r 's/([a-z0-9])([A-Z])/\1_\2/g' | tr '[:lower:]' '[:upper:]')
REGOP_ENV_RPC_URL:=$(PREFIX)_RPC_URL
REGOP_ENV_PK:=$(PREFIX)_PRIVATE_KEY

RPC_URL=$(shell echo "$${!REGOP_ENV_RPC_URL}" | tr -d '"')
PRIVATE_KEY=$(shell echo "$${!REGOP_ENV_PK}" | tr -d '"')

COMPILER_VERSION:=$(shell grep 'solc_version' foundry.toml | head -1 | sed 's/.*"\(.*\)".*/\1/')

deploy-swap-vm:
	@$(MAKE) FILE_DEPLOY_NAME=SwapVMRouter validate-swap-vm-router deploy-swap-vm-router-impl save-deployments

deploy-swap-vm-aqua:
	@$(MAKE) FILE_DEPLOY_NAME=AquaSwapVMRouter validate-swap-vm-router deploy-swap-vm-router-impl save-deployments

deploy-swap-vm-limit:
	@$(MAKE) FILE_DEPLOY_NAME=LimitSwapVMRouter validate-swap-vm-router deploy-swap-vm-router-impl save-deployments

verify-swap-vm:
	@$(MAKE) FILE_DEPLOY_NAME=SwapVMRouter validate-verify verify-swap-vm-router-impl

verify-swap-vm-aqua:
	@$(MAKE) FILE_DEPLOY_NAME=AquaSwapVMRouter validate-verify verify-swap-vm-router-impl

verify-swap-vm-limit:
	@$(MAKE) FILE_DEPLOY_NAME=LimitSwapVMRouter validate-verify verify-swap-vm-router-impl

deploy-swap-vm-router-impl:
	@{ \
	    $(MAKE) ID=FILE_DEPLOY_NAME validate || exit 1; \
        forge script $(CURRENT_DIR)/script/Deploy$${FILE_DEPLOY_NAME}.s.sol:Deploy$${FILE_DEPLOY_NAME} \
            --rpc-url $(RPC_URL) \
            --private-key $(PRIVATE_KEY) \
            --broadcast -vvvv; \
	}

verify-swap-vm-router-impl:
	@{ \
	    $(MAKE) ID=FILE_DEPLOY_NAME validate || exit 1; \
	    DEPLOYMENT_FILE="$(CURRENT_DIR)/deployments/$(OPS_NETWORK)/$${FILE_DEPLOY_NAME}.json"; \
	    if [ ! -f $$DEPLOYMENT_FILE ]; then \
	        echo "Deployment file $$DEPLOYMENT_FILE does not exist! Deploy first."; \
	        exit 1; \
	    fi; \
        echo "Compiler version: $${COMPILER_VERSION}"; \
	    CONTRACT_ADDRESS=$$($(MAKE) contract-address DEPLOYMENT_FILE=$$DEPLOYMENT_FILE); \
	    echo "Verifying $${FILE_DEPLOY_NAME} at $$CONTRACT_ADDRESS on $(OPS_NETWORK)..."; \
	    echo "Constructor args: aqua=$(OPS_AQUA_ADDRESS), name=$(OPS_SWAP_VM_ROUTER_NAME), version=$(OPS_SWAP_VM_ROUTER_VERSION)"; \
	    CONSTRUCTOR_ARGS=$$(cast abi-encode "constructor(address,string,string)" \
	        $(OPS_AQUA_ADDRESS) \
	        $(OPS_SWAP_VM_ROUTER_NAME) \
	        $(OPS_SWAP_VM_ROUTER_VERSION)); \
	    forge verify-contract $$CONTRACT_ADDRESS \
	        src/routers/$${FILE_DEPLOY_NAME}.sol:$${FILE_DEPLOY_NAME} \
	        --constructor-args $$CONSTRUCTOR_ARGS \
            --skip-is-verified-check \
            --rpc-url $(RPC_URL) \
	        --chain-id $(OPS_CHAIN_ID) \
	        --watch \
	        --compiler-version $(COMPILER_VERSION); \
	}

# Helper targets
save-deployments:
	@{ \
		$(MAKE) ID=FILE_DEPLOY_NAME validate || exit 1; \
		DEPLOYMENT_FILE="$(CURRENT_DIR)/broadcast/Deploy$${FILE_DEPLOY_NAME}.s.sol/$(OPS_CHAIN_ID)/run-latest.json"; \
		DIRECTORY="$(CURRENT_DIR)/deployments/$(OPS_NETWORK)"; \
		mkdir -p $$DIRECTORY; \
		if [ -f $$DEPLOYMENT_FILE ]; then \
			cp -f $$DEPLOYMENT_FILE "$${DIRECTORY}/$${FILE_DEPLOY_NAME}.json"; \
		else \
			echo "Deployment file $$DEPLOYMENT_FILE does not exist!"; \
			exit 1; \
		fi; \
	}

contract-address:
	@{ \
		$(MAKE) ID=DEPLOYMENT_FILE validate || exit 1; \
		echo $$(jq -r '.transactions[0].contractAddress' $(DEPLOYMENT_FILE)); \
	}

# Validation targets
validate-swap-vm-router:
		@{ \
		$(MAKE) ID=OPS_NETWORK validate || exit 1; \
		$(MAKE) ID=OPS_CHAIN_ID validate || exit 1; \
		$(MAKE) ID=OPS_AQUA_ADDRESS validate || exit 1; \
		$(MAKE) ID=OPS_SWAP_VM_ROUTER_NAME validate || exit 1; \
		$(MAKE) ID=OPS_SWAP_VM_ROUTER_VERSION validate || exit 1; \
		$(MAKE) process-aqua-address process-swap-vm-router-name process-swap-vm-router-version || exit 1; \
		}

validate-verify:
	@{ \
	$(MAKE) ID=OPS_NETWORK validate || exit 1; \
	$(MAKE) ID=OPS_CHAIN_ID validate || exit 1; \
	$(MAKE) ID=OPS_AQUA_ADDRESS validate || exit 1; \
	$(MAKE) ID=OPS_SWAP_VM_ROUTER_NAME validate || exit 1; \
	$(MAKE) ID=OPS_SWAP_VM_ROUTER_VERSION validate || exit 1; \
	}

validate:
		@{ \
			VALUE=$$(echo "$${!ID}" | tr -d '"'); \
			if [ -z "$${VALUE}" ]; then \
				echo "$${ID} is not set (Value: '$${VALUE}')!"; \
				exit 1; \
			fi; \
		}

# Process constant functions for new addresses
process-aqua-address:
		@if [ -n "$$OPS_AQUA_ADDRESS" ]; then $(MAKE) OPS_GEN_VAL='$(OPS_AQUA_ADDRESS)' OPS_GEN_KEY='aqua' upsert-constant; fi

process-swap-vm-router-name:
		@$(MAKE) OPS_GEN_VAL='$(OPS_SWAP_VM_ROUTER_NAME)' OPS_GEN_KEY='swapVmRouterName' upsert-constant

process-swap-vm-router-version:
		@$(MAKE) OPS_GEN_VAL='$(OPS_SWAP_VM_ROUTER_VERSION)' OPS_GEN_KEY='swapVmRouterVersion' upsert-constant

upsert-constant:
		@{ \
		$(MAKE) ID=OPS_GEN_VAL validate || exit 1; \
		$(MAKE) ID=OPS_GEN_KEY validate || exit 1; \
		$(MAKE) ID=OPS_CHAIN_ID validate || exit 1; \
		tmpfile=$$(mktemp); \
		jq '.$(OPS_GEN_KEY)."$(OPS_CHAIN_ID)" = $(OPS_GEN_VAL)' $(FILE_CONSTANTS_JSON) > $$tmpfile && mv $$tmpfile $(FILE_CONSTANTS_JSON); \
		echo "Updated $(OPS_GEN_KEY)[$(OPS_CHAIN_ID)] = $(OPS_GEN_VAL)"; \
		}

# Get deployed contract addresses from deployment files
get:
		@{ \
		$(MAKE) ID=PARAMETER validate || exit 1; \
		$(MAKE) ID=OPS_NETWORK validate || exit 1; \
		if [ ! -d "$(CURRENT_DIR)/deployments/$(OPS_NETWORK)" ]; then \
			echo "Error: Directory $(CURRENT_DIR)/deployments/$(OPS_NETWORK) does not exist"; \
			exit 1; \
		fi; \
		CONTRACT_FILE=""; \
		contracts_list=$$(ls $(CURRENT_DIR)/deployments/$(OPS_NETWORK)/*.json | xargs -n1 basename | sed 's/\.json$$//'); \
		found=0; \
		for contract in $$contracts_list; do \
			contract_upper=$$(echo $$contract | sed 's/\([A-Z][a-z]\)/_\1/g' | sed 's/^_//' | tr 'a-z' 'A-Z'); \
			if [ "$(PARAMETER)" = "OPS_$${contract_upper}_ADDRESS" ]; then \
				CONTRACT_FILE="$${contract}.json"; \
				found=1; \
				break; \
			fi; \
		done; \
		if [ "$$found" -eq 0 ]; then \
			echo "Error: Unknown parameter $(PARAMETER)"; exit 1; \
		fi; \
		DEPLOYMENT_FILE="$(CURRENT_DIR)/deployments/$(OPS_NETWORK)/$$CONTRACT_FILE"; \
		if [ ! -f "$$DEPLOYMENT_FILE" ]; then \
			echo "Error: Deployment file $$DEPLOYMENT_FILE not found"; \
			exit 1; \
		fi; \
		ADDRESS=$$($(MAKE) contract-address DEPLOYMENT_FILE=$$DEPLOYMENT_FILE); \
		echo "$$ADDRESS"; \
		}

get-outputs:
		@{ \
		$(MAKE) ID=OPS_NETWORK validate || exit 1; \
		if [ ! -d "$(CURRENT_DIR)/deployments/$(OPS_NETWORK)" ]; then \
			echo "Error: Directory $(CURRENT_DIR)/deployments/$(OPS_NETWORK) does not exist"; \
			exit 1; \
		fi; \
		result="{"; \
		first=1; \
		for file in $(CURRENT_DIR)/deployments/$(OPS_NETWORK)/*.json; do \
			filename=$$(basename $$file .json); \
			key="OPS_$$(echo $$filename | sed 's/\([A-Z][a-z]\)/_\1/g' | sed 's/^_//' | tr 'a-z' 'A-Z')_ADDRESS"; \
			if [ $$first -eq 1 ]; then \
				result="$$result\"$$key\": \"$$key\""; \
				first=0; \
			else \
				result="$$result, \"$$key\": \"$$key\""; \
			fi; \
		done; \
		result="$$result}"; \
		echo "$$result"; \
		}

update:; forge update

build:; forge build

tests :; forge test -vvv --gas-report

coverage :; mkdir -p coverage && FOUNDRY_PROFILE=default forge coverage --report lcov --ir-minimum --report-file coverage/lcov.info

snapshot :; forge snapshot --no-match-test "testFuzz_*"

snapshot-check :; forge snapshot --check --no-match-test "testFuzz_*"

gas-snapshot :; forge test --match-path "test/gas/*.t.sol" -vv && echo "\n=== LimitSwap Gas ===" && cat snapshots/LimitSwapGas.json && echo "\n=== AMM Gas ===" && cat snapshots/AMMGas.json

gas-snapshot-check :; @{ \
	cp snapshots/LimitSwapGas.json snapshots/LimitSwapGas.json.old 2>/dev/null || true; \
	cp snapshots/AMMGas.json snapshots/AMMGas.json.old 2>/dev/null || true; \
	forge test --match-path "test/gas/*.t.sol" -vv; \
	if diff -q snapshots/LimitSwapGas.json snapshots/LimitSwapGas.json.old >/dev/null 2>&1 && \
	   diff -q snapshots/AMMGas.json snapshots/AMMGas.json.old >/dev/null 2>&1; then \
		echo "✅ Gas snapshots match"; \
		rm -f snapshots/*.old; \
	else \
		echo "❌ Gas snapshots differ!"; \
		echo "=== LimitSwapGas diff ==="; \
		diff snapshots/LimitSwapGas.json.old snapshots/LimitSwapGas.json || true; \
		echo "=== AMMGas diff ==="; \
		diff snapshots/AMMGas.json.old snapshots/AMMGas.json || true; \
		rm -f snapshots/*.old; \
		exit 1; \
	fi; \
}

format :; forge fmt

clean :; forge clean

lint :; forge fmt --check

anvil :;  anvil --fork-url $(NODE_URL) --steps-tracing --chain-id $(OPS_CHAIN_ID) --host 127.0.0.1 --port 8546 -vvvvv

balance :; cast balance $(ADDRESS) --rpc-url $(RPC_URL) | cast from-wei

balance-erc20 :; cast call $(TOKEN) "balanceOf(address)(uint256)" $(ADDRESS) --rpc-url $(RPC_URL) | cast from-wei

help:
		@echo "Available targets:"
		@grep -E '^[a-zA-Z0-9_.-]+:' $(CURRENT_DIR)/Makefile | grep -v '^\.' | awk -F: '{print "  " $$1}' | sort -u

.PHONY: deploy-swap-vm deploy-swap-vm-aqua deploy-swap-vm-limit deploy-swap-vm-router-impl verify-swap-vm verify-swap-vm-aqua \
        verify-swap-vm-limit verify-swap-vm-router-impl save-deployments contract-address validate-swap-vm-router validate-verify \
        validate process-aqua-address process-swap-vm-router-name process-swap-vm-router-version upsert-constant \
        get get-outputs update build tests coverage snapshot snapshot-check format clean lint anvil balance balance-erc20 help
