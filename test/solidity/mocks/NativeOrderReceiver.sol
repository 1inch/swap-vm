// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { IERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { NativeOrderEscrow } from "../../../contracts/extensions/nativeorder/NativeOrderEscrow.sol";
import { NativeOrder } from "../../../contracts/extensions/nativeorder/NativeOrderLib.sol";

/// @dev Maker/resolver fixture exercising ETH failure and callback paths.
contract NativeOrderReceiver {
    error RejectEther();

    NativeOrderEscrow private _escrow;
    NativeOrder private _order;
    bool private _rejectsEther;
    bool private _reenters;
    bool private _rescuesEther;

    uint256 public received;
    uint256 public callbacks;
    uint256 public rescueAttempts;
    uint256 public rescuedDuringCallback;
    bytes4 public reentrantError;

    function configure(
        NativeOrderEscrow escrow,
        NativeOrder calldata order,
        bool rejectsEther,
        bool reenters
    ) external {
        _escrow = escrow;
        _order = order;
        _rejectsEther = rejectsEther;
        _reenters = reenters;
    }

    function enableRescueDuringCallback() external {
        _rescuesEther = true;
    }

    receive() external payable {
        require(!_rejectsEther, RejectEther());
        received += msg.value;
        ++callbacks;

        if (_rescuesEther) {
            _rescuesEther = false;
            ++rescueAttempts;
            rescuedDuringCallback = address(_escrow).balance;
            _escrow.rescueFunds(_order, IERC20(address(0)), rescuedDuringCallback);
        }

        if (_reenters) {
            _reenters = false;
            try _escrow.cancelExpiredForReward(_order) {} catch (bytes memory reason) {
                if (reason.length >= 4) reentrantError = bytes4(reason);
            }
        }
    }
}
