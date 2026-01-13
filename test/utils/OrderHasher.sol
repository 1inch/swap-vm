// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SwapVM, ISwapVM } from "../../src/SwapVM.sol";

contract OrderHasher {
    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    address public immutable swapVM;
    string public name;
    string public version;

    constructor(string memory _name, string memory _version, address _swapVM) {
        swapVM = _swapVM;
        name = _name;
        version = _version;
    }

    function orderTypedData(ISwapVM.Order calldata order) public view returns (bytes memory) {
        bytes32 hash = keccak256(abi.encode(
            SwapVM(payable(swapVM)).ORDER_TYPEHASH(),
            order.maker,
            order.traits,
            keccak256(order.data)
        ));
        bytes32 domainSeparatorV4 = _buildDomainSeparator();
        return _toTypedData(domainSeparatorV4, hash);
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(TYPE_HASH, keccak256(bytes(name)), keccak256(bytes(version)), block.chainid, swapVM));
    }

    function _toTypedData(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator, structHash);
    }
}
