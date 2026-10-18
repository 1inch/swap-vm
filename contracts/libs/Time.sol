// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Context } from "./VM.sol";
import { OrderRegistratorLib } from "../extensions/OrderRegistrator.sol";

library Time {
    /// @dev High timestamp bit set -> treat timestamp as time since announceAt
    uint40 constant RELATIVE_TIME_FLAG = 1 << 39;
    uint40 constant TIMESTAMP_MASK = 0x7fffffffff;

    function resolve(Context memory ctx, uint40 ts) internal returns (uint40) {
        if (ts & RELATIVE_TIME_FLAG != 0) {
            return (ts & TIMESTAMP_MASK) + OrderRegistratorLib.announcedAt(ctx.query.orderHash, ctx.vm.isStaticContext);
        }

        return ts;
    }
}
