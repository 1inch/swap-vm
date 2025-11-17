// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Vm } from "forge-std/Vm.sol";

library FormatLib {
    using FormatLib for Vm;

    function toFixedString(Vm vm, uint256 amount) internal pure returns (string memory result) {
        return toFixedString(vm, amount, 18);
    }

    function toFixedString(Vm vm, uint256 amount, uint256 decimals) internal pure returns (string memory result) {
        uint256 integerPart = amount / (10 ** decimals);
        uint256 fractionalPart = amount % (10 ** decimals);
        return string.concat(
            vm.toString(integerPart),
            ".",
            vm.padLeft(vm.toString(fractionalPart), decimals, '0')
        );
    }

    function formatAmount(Vm vm, uint256 amount) internal pure returns (string memory) {
        uint256 whole = amount / 1e18;
        uint256 decimal = (amount % 1e18) / 1e16;
        return string.concat(
            vm.toString(whole),
            ".",
            decimal < 10 ? "0" : "",
            vm.toString(decimal)
        );
    }

    function formatPrice(Vm vm, uint256 price) internal pure returns (string memory) {
        uint256 whole = price / 10000;
        uint256 decimal = (price % 10000) / 100;
        return string.concat(
            vm.toString(whole),
            ".",
            decimal < 10 ? "0" : "",
            vm.toString(decimal)
        );
    }

    function formatRate(Vm vm, uint256 rate) internal pure returns (string memory) {
        uint256 whole = rate / 1e18;
        uint256 decimal = (rate % 1e18) / 1e14; // 4 decimal places
        return string.concat(
            vm.toString(whole),
            ".",
            decimal < 1000 ? "0" : "",
            decimal < 100 ? "0" : "",
            decimal < 10 ? "0" : "",
            vm.toString(decimal)
        );
    }

    function formatBps(Vm vm, uint256 bps) internal pure returns (string memory) {
        if (bps >= 100) {
            uint256 whole = bps / 100;
            uint256 decimal = bps % 100;
            return string.concat(
                vm.toString(whole),
                ".",
                decimal < 10 ? "0" : "",
                vm.toString(decimal), "%"
            );
        } else {
            return string.concat("0.", bps < 10 ? "0" : "", vm.toString(bps), "%");
        }
    }

    function padLeft(Vm vm, string memory str, uint256 width) internal pure returns (string memory) {
        return padLeft(vm, str, width, " ");
    }

    function padLeft(Vm /* vm */, string memory str, uint256 width, bytes1 fillChar) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        if (strBytes.length >= width) return str;

        bytes memory pad = new bytes(width - strBytes.length);
        for (uint256 i = 0; i < pad.length; i++) {
            pad[i] = fillChar;
        }

        return string.concat(string(pad), str);
    }

    function padRight(Vm vm, string memory str, uint256 width) internal pure returns (string memory) {
        return padRight(vm, str, width, " ");
    }

    function padRight(Vm /* vm */, string memory str, uint256 width, bytes1 fillChar) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        if (strBytes.length >= width) return str;

        bytes memory pad = new bytes(width - strBytes.length);
        for (uint256 i = 0; i < pad.length; i++) {
            pad[i] = fillChar;
        }

        return string.concat(str, string(pad));
    }
}
