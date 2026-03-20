// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { KycNft } from "../mocks/KycNft.sol";

/// @title DeployKycNft
/// @notice Deploy the KYC NFT contract and optionally mint to a list of addresses.
/// @dev Usage:
///
///   # Deploy only (owner = broadcaster):
///   forge script test/mocks/DeployKycNft.s.sol \
///     --rpc-url $RPC_URL --private-key $PK --broadcast
///
///   # Deploy + mint to addresses (comma-separated):
///   MINT_TO=0xAlice,0xBob \
///   forge script test/mocks/DeployKycNft.s.sol \
///     --rpc-url $RPC_URL --private-key $PK --broadcast
// solhint-disable no-console
contract DeployKycNft is Script {
    function run() external {
        vm.startBroadcast();

        KycNft nft = new KycNft(msg.sender);
        console2.log("KycNft deployed:", address(nft));
        console2.log("Owner:          ", msg.sender);

        string memory mintToRaw = vm.envOr("MINT_TO", string(""));
        if (bytes(mintToRaw).length > 0) {
            address[] memory recipients = _parseAddresses(mintToRaw);
            for (uint256 i; i < recipients.length; ++i) {
                uint256 tokenId = nft.mint(recipients[i]);
                console2.log("Minted tokenId", tokenId, "->", recipients[i]);
            }
        }

        vm.stopBroadcast();

        _saveResult(address(nft));
    }

    function _parseAddresses(string memory csv) internal pure returns (address[] memory) {
        bytes memory raw = bytes(csv);
        uint256 count = 1;
        for (uint256 i; i < raw.length; ++i) {
            if (raw[i] == ",") count++;
        }

        address[] memory result = new address[](count);
        uint256 start;
        uint256 idx;
        for (uint256 i; i <= raw.length; ++i) {
            if (i == raw.length || raw[i] == ",") {
                bytes memory segment = new bytes(i - start);
                for (uint256 j = start; j < i; ++j) {
                    segment[j - start] = raw[j];
                }
                result[idx++] = vm.parseAddress(string(segment));
                start = i + 1;
            }
        }
        return result;
    }

    function _saveResult(address nft) internal {
        string memory obj = "result";
        vm.serializeAddress(obj, "kycNft", nft);
        string memory json = vm.serializeAddress(obj, "owner", msg.sender);

        string memory dir = string.concat("deployments/utils/", vm.toString(block.chainid));
        vm.createDir(dir, true);
        string memory path = string.concat(dir, "/kyc-nft.json");
        vm.writeJson(json, path);
        console2.log("Result saved:", path);
    }
}
// solhint-enable no-console
