// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.0;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

// dynamic(uint256[1..5]) => uint256[]

function dynamic(uint256[1] memory arr) pure returns (uint256[] memory res) {
    res = new uint256[](1);
    for (uint256 i = 0; i < arr.length; i++) {
        res[i] = arr[i];
    }
}

function dynamic(uint256[2] memory arr) pure returns (uint256[] memory res) {
    res = new uint256[](2);
    for (uint256 i = 0; i < arr.length; i++) {
        res[i] = arr[i];
    }
}

function dynamic(uint256[3] memory arr) pure returns (uint256[] memory res) {
    res = new uint256[](3);
    for (uint256 i = 0; i < arr.length; i++) {
        res[i] = arr[i];
    }
}

function dynamic(uint256[4] memory arr) pure returns (uint256[] memory res) {
    res = new uint256[](4);
    for (uint256 i = 0; i < arr.length; i++) {
        res[i] = arr[i];
    }
}

function dynamic(uint256[5] memory arr) pure returns (uint256[] memory res) {
    res = new uint256[](5);
    for (uint256 i = 0; i < arr.length; i++) {
        res[i] = arr[i];
    }
}

function dynamic(uint256[6] memory arr) pure returns (uint256[] memory res) {
    res = new uint256[](6);
    for (uint256 i = 0; i < arr.length; i++) {
        res[i] = arr[i];
    }
}

function dynamic(uint256[7] memory arr) pure returns (uint256[] memory res) {
    res = new uint256[](7);
    for (uint256 i = 0; i < arr.length; i++) {
        res[i] = arr[i];
    }
}

function dynamic(uint256[8] memory arr) pure returns (uint256[] memory res) {
    res = new uint256[](8);
    for (uint256 i = 0; i < arr.length; i++) {
        res[i] = arr[i];
    }
}

// dynamic(address[1..5]) => address[]

function dynamic(address[1] memory arr) pure returns (address[] memory res) {
    res = new address[](1);
    for (uint256 i = 0; i < arr.length; i++) {
        res[i] = arr[i];
    }
}

function dynamic(address[2] memory arr) pure returns (address[] memory res) {
    res = new address[](2);
    for (uint256 i = 0; i < arr.length; i++) {
        res[i] = arr[i];
    }
}

function dynamic(address[3] memory arr) pure returns (address[] memory res) {
    res = new address[](3);
    for (uint256 i = 0; i < arr.length; i++) {
        res[i] = arr[i];
    }
}

function dynamic(address[4] memory arr) pure returns (address[] memory res) {
    res = new address[](4);
    for (uint256 i = 0; i < arr.length; i++) {
        res[i] = arr[i];
    }
}

function dynamic(address[5] memory arr) pure returns (address[] memory res) {
    res = new address[](5);
    for (uint256 i = 0; i < arr.length; i++) {
        res[i] = arr[i];
    }
}
