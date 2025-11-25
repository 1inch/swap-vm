// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

abstract contract TestConstants {
    uint256 constant ONE = 1e18;

    // Common balances
    uint256 constant INITIAL_BALANCE_A = 1000e18;
    uint256 constant INITIAL_BALANCE_B = 2000e18;

    // Common amounts
    uint256 constant DUST_AMOUNT = 1;
    uint256 constant TINY_AMOUNT = 1e3;
    uint256 constant SMALL_AMOUNT = 1e6;
    uint256 constant MEDIUM_AMOUNT = 1e18;
    uint256 constant LARGE_AMOUNT = 1000e18;
    uint256 constant MAX_REASONABLE_AMOUNT = type(uint128).max;
    uint256 constant MAX_REASONABLE_BALANCE = type(uint128).max;
    uint256 constant MAX_AQUA_AMOUNT = type(uint248).max;
    uint256 constant OVERFLOW_AMOUNT = type(uint256).max;

    // Get base price from initial balances
    function getBasePrice() public pure returns (uint256) {
        return (INITIAL_BALANCE_B * ONE) / INITIAL_BALANCE_A; // 2.0
    }
}
