// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

contract PriceOracleMock {
    int256 private _answer;
    uint256 private _updatedAt;

    constructor(int256 answer_, uint256 updatedAt_) {
        setRoundData(answer_, updatedAt_);
    }

    function setRoundData(int256 answer_, uint256 updatedAt_) public {
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}
