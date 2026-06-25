// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.23;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

/// @dev The real Fusion {SimpleSettlement} is pinned to solc 0.8.23 and pulls in the matching 0.8.23 LOP
///      copy nested under the settlement package (routed by the @1inch/limit-order-protocol-contract/
///      remapping). The 0.8.30 test files cannot import it (incompatible single import graph), so they
///      deploy it by artifact name via vm.deployCode. This 0.8.23 re-export exists solely to pull
///      SimpleSettlement into the build so that artifact ("SimpleSettlement.sol:SimpleSettlement") exists.
import { SimpleSettlement } from "@1inch/fusion-protocol/SimpleSettlement.sol";
