// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { IPermit2 } from "@1inch/solidity-utils/contracts/interfaces/IPermit2.sol";

library Permit2TestLib {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function install() internal {
        string memory artifact = VM.readFile("node_modules/@1inch/solidity-utils/dist/src/permit2.json");
        VM.etch(PERMIT2, VM.parseJsonBytes(artifact, ".bytecode"));
    }

    function approve(address token, address owner, address spender, uint160 amount, uint48 expiration) internal {
        VM.startPrank(owner);
        IERC20(token).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(token, spender, amount, expiration);
        VM.stopPrank();
    }

    function allowance(address owner, address token, address spender) internal view returns (IPermit2.PackedAllowance memory) {
        return IPermit2(PERMIT2).allowance(owner, token, spender);
    }
}
