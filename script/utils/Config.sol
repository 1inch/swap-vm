// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Vm } from "forge-std/Vm.sol";

// solhint-disable no-console
import { console2 } from "forge-std/console2.sol";

library Config {
    error AquaAddressDoesNotExist();
    error NameDoesNotExist();
    error VersionDoesNotExist();

    function readSwapVMRouterParameters(Vm vm) internal view returns (
        address aquaAddress,
        string memory name,
        string memory version
    ) {
        uint256 chain = block.chainid;

        string memory path = string.concat(vm.projectRoot(), "/config/constants.json");
        string memory json = vm.readFile(path);
        string memory key = string.concat(".", vm.toString(chain));

        aquaAddress = vm.parseJsonAddress(json, string.concat(".aqua", key));
        if (aquaAddress == address(0)) revert AquaAddressDoesNotExist();
        console2.log("Aqua address:", aquaAddress);

        name = vm.parseJsonString(json, string.concat(".swapVmRouterName", key));
        if (bytes(name).length == 0) revert NameDoesNotExist();
        console2.log("Name:", name);

        version = vm.parseJsonString(json, string.concat(".swapVmRouterVersion", key));
        if (bytes(version).length == 0) revert VersionDoesNotExist();
        console2.log("Version:", version);
    }
}
