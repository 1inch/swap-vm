// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

/**
 * @title TokenMockDecimals
 * @dev TokenMock with configurable decimals for testing (e.g., USDC = 6)
 */
contract TokenMockDecimals is TokenMock {
    uint8 private immutable _decimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) TokenMock(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
