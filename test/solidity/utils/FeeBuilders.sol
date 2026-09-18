// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { FeeProtocol, FeeProtocolSurplus } from "../../../contracts/instructions/FeeProtocol.sol";

/// @notice Test helpers building common single-target FeeProtocol instructions
library FeeBuilders {
    function protocolFeeIn(uint24 feeBps, address receiver) internal pure returns (bytes memory) {
        return _single(true, receiver, feeBps, 0, 0);
    }

    function protocolFeeOut(uint24 feeBps, address receiver) internal pure returns (bytes memory) {
        return _single(false, receiver, feeBps, 0, 0);
    }

    function protocolSurplusIn(uint24 surplusBps, address receiver, uint256 estimate) internal pure returns (bytes memory) {
        return _single(true, receiver, 0, surplusBps, estimate);
    }

    function protocolSurplusOut(uint24 surplusBps, address receiver, uint256 estimate) internal pure returns (bytes memory) {
        return _single(false, receiver, 0, surplusBps, estimate);
    }

    function protocolFlatSurplusIn(uint24 feeBps, uint24 surplusBps, address receiver, uint256 estimate) internal pure returns (bytes memory) {
        return _single(true, receiver, feeBps, surplusBps, estimate);
    }

    function protocolFlatSurplusOut(uint24 feeBps, uint24 surplusBps, address receiver, uint256 estimate) internal pure returns (bytes memory) {
        return _single(false, receiver, feeBps, surplusBps, estimate);
    }

    function protocolProviderIn(address provider) internal pure returns (bytes memory) {
        return _provider(true, provider);
    }

    function protocolProviderOut(address provider) internal pure returns (bytes memory) {
        return _provider(false, provider);
    }

    function _single(
        bool isTokenIn,
        address receiver,
        uint24 feeBps,
        uint24 surplusBps,
        uint256 estimate
    ) private pure returns (bytes memory) {
        FeeProtocol.ReceiverConfig[] memory receivers = new FeeProtocol.ReceiverConfig[](1);
        receivers[0] = FeeProtocol.ReceiverConfig({ receiver: receiver, feeBps: feeBps, surplusBps: surplusBps });
        bytes memory feeProtocol = FeeProtocol.build(isTokenIn, receivers, new FeeProtocol.ProviderConfig[](0));
        return surplusBps == 0 ? feeProtocol : bytes.concat(feeProtocol, FeeProtocolSurplus.build(isTokenIn, estimate));
    }

    function _provider(bool isTokenIn, address provider) private pure returns (bytes memory) {
        FeeProtocol.ProviderConfig[] memory providers = new FeeProtocol.ProviderConfig[](1);
        providers[0] = FeeProtocol.ProviderConfig({ provider: provider, takeFlatFee: true, takeSurplusFee: false });
        return FeeProtocol.build(isTokenIn, new FeeProtocol.ReceiverConfig[](0), providers);
    }
}
