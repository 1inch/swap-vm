// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

// ---- SwapVM ----
import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { LimitSwapVMRouter } from "../src/routers/LimitSwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { LimitOpcodesDebug } from "../src/opcodes/LimitOpcodesDebug.sol";
import { BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { LimitSwapArgsBuilder } from "../src/instructions/LimitSwap.sol";
import { InvalidatorsArgsBuilder } from "../src/instructions/Invalidators.sol";
import { WhitelistArgsBuilder } from "../src/instructions/Whitelist.sol";
import { PiecewiseLinearScaleArgsBuilder } from "../src/instructions/PiecewiseLinearScale.sol";
import { Program, ProgramBuilder } from "../test/utils/ProgramBuilder.sol";
import { dynamic } from "../test/utils/Dynamic.sol";

// ---- LOP / Fusion (real LimitOrderProtocol + SimpleSettlement amount-getter extension) ----
import { LimitOrderProtocol } from "@1inch/limit-order-protocol/LimitOrderProtocol.sol";
import { IOrderMixin } from "@1inch/limit-order-protocol/interfaces/IOrderMixin.sol";
import { MakerTraits } from "@1inch/limit-order-protocol/libraries/MakerTraitsLib.sol";
import { TakerTraits } from "@1inch/limit-order-protocol/libraries/TakerTraitsLib.sol";
import { Address } from "@1inch/solidity-utils/contracts/libraries/AddressLib.sol";
import { IWETH } from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";
import { WrappedTokenMock } from "@1inch/limit-order-protocol/mocks/WrappedTokenMock.sol";

/// @title  GasCompare — end-to-end gas comparison: SwapVM vs LOP vs Fusion, via real broadcast.
/// @notice A forge SCRIPT that deploys the real contracts to a node and BROADCASTS the fills as actual
///         transactions, so the node (and forge's receipts) report the true end-to-end gas used — intrinsic
///         + calldata + execution — with a real per-transaction cold access list. Unlike a simulation, the
///         gas here is whatever the EVM actually charges; we don't compute anything.
///
///         Each fill is a full exact-out buy of the whole makingAmount. Scenarios:
///           1. simplest LOP order                          (bit-invalidator slot starts zero)
///           2. simplest order, nonce-slot already non-zero (warm/dirty SSTORE — set by scenario 1)
///           3. Fusion order WITHOUT fusion features         (SimpleSettlement getter, rate bump 0)
///           4. Fusion order WITH Dutch auction              (SimpleSettlement getter, rate bump > 0)
///           5. private order                                (LOP allowedSender / SwapVM whitelistSingleTaker)
///
///         Run against a local node (e.g. anvil), nothing on a real network:
///           anvil  # 127.0.0.1:8545
///           forge script script/GasCompare.s.sol \
///             --rpc-url http://127.0.0.1:8545 --broadcast \
///             --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///         Per-tx gasUsed is in broadcast/GasCompare.s.sol/<chainid>/run-latest.json (receipts[].gasUsed);
///         the console labels below print in broadcast order so each fill maps to its scenario.
contract GasCompare is Script, LimitOpcodesDebug {
    using ProgramBuilder for Program;

    uint256 internal constant MAKER_PK = 0xA11CE;
    uint256 internal constant TAKER_PK = 0xB0B;
    address internal maker;
    address internal taker;

    Aqua internal aqua;
    LimitOrderProtocol internal lop;
    LimitSwapVMRouter internal swapVM;
    address internal settlement;
    IWETH internal weth;
    TokenMock internal tokenA; // takerAsset / tokenIn
    TokenMock internal tokenB; // makerAsset / tokenOut

    uint256 internal constant MAKING = 1_000e18;
    uint256 internal constant TAKING = 2_000e18;
    uint32 internal auctionStartTime;                        // set to block.timestamp at run time
    uint24 internal constant AUCTION_DURATION = 1800;        // 30 min — fills land near the start
    uint24 internal constant INITIAL_RATE_BUMP = 1_000_000;  // 10% in Fusion's 1e7 base

    uint256 internal constant FUSION_BASE_POINTS = 10_000_000;
    uint256 internal constant SCALE_ONE = (1 << 24) - 1;

    uint256 internal constant M_NO_PARTIAL_FILLS = 1 << 255;
    uint256 internal constant M_HAS_EXTENSION = 1 << 249;
    uint256 internal constant M_NONCE_OFFSET = 120;
    uint256 internal constant T_MAKER_AMOUNT = 1 << 255;
    uint256 internal constant T_ARGS_EXTENSION_LENGTH_OFFSET = 224;

    constructor() LimitOpcodesDebug(address(0)) {}


// console.log("  tx: scenario 1 - LOP    - simplest order (clean nonce slot)");
// ##### anvil-hardhat
// ✅  [Success] Hash: 0x546cb95053de23133fb70b2ae42c336149dee68a0fde0f5f22ccd78b87ec3c91
// Contract: LimitOrderProtocol
// Function: fillOrderArgs((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256),bytes32,bytes32,uint256,uint256,bytes)
// Block: 18
// Paid: 0.00001130302845459 ETH (96497 gas * 0.11713347 gwei)


// console.log("  tx: scenario 1 - SwapVM - simplest order (clean bit slot)");
// ##### anvil-hardhat
// ✅  [Success] Hash: 0xa0402964170c5e6c1879d43c9f93e457a484672dfab5dba064a331388760e647
// Contract: LimitSwapVMRouter
// Function: swap((address,uint256,bytes),uint256,bytes)
// Block: 19
// Paid: 0.000010937204151085 ETH (106615 gas * 0.102585979 gwei)


// console.log("  tx: scenario 2 - LOP    - nonce slot already non-zero");
// ##### anvil-hardhat
// ✅  [Success] Hash: 0x0c36b0517f723369bb036d801854c4ceaa24e5071063dfea2efc0e3b644bafb8
// Contract: LimitOrderProtocol
// Function: fillOrderArgs((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256),bytes32,bytes32,uint256,uint256,bytes)
// Block: 20
// Paid: 0.000007136284685796 ETH (79421 gas * 0.089853876 gwei)


// console.log("  tx: scenario 2 - SwapVM - bit slot already non-zero");
// ##### anvil-hardhat
// ✅  [Success] Hash: 0x739492f5cd1f2460bcf436b7bf0a325ed32ade4571709003ec2ce695c362109d
// Contract: LimitSwapVMRouter
// Function: swap((address,uint256,bytes),uint256,bytes)
// Block: 21
// Paid: 0.000007043184408665 ETH (89515 gas * 0.078681611 gwei)


// console.log("  tx: scenario 3 - Fusion - no fusion features (rate bump 0)");
// ##### anvil-hardhat
// ✅  [Success] Hash: 0x9b4192c22dec6d0c80755fb4bea8f5c7158ed2ad2e7511bcddb635d4bf380f96
// Contract: LimitOrderProtocol
// Function: fillOrderArgs((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256),bytes32,bytes32,uint256,uint256,bytes)
// Block: 22
// Paid: 0.00000753959637026 ETH (109420 gas * 0.068905103 gwei)


// console.log("  tx: scenario 3 - SwapVM - plain limit");
// ##### anvil-hardhat
// ✅  [Success] Hash: 0x49f17b11b59448c5f0b2742518b9a3326da9cef930dd7ae523b697f2bfd42fb4
// Contract: LimitSwapVMRouter
// Function: swap((address,uint256,bytes),uint256,bytes)
// Block: 23
// Paid: 0.00000643472657554 ETH (106615 gas * 0.060354796 gwei)


// console.log("  tx: scenario 4 - Fusion - Dutch auction");
// ##### anvil-hardhat
// ✅  [Success] Hash: 0x28d2438424b12dcafeb54b34ffb688d5110f6144dadbe7e87b1b052219f856cf
// Contract: LimitOrderProtocol
// Function: fillOrderArgs((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256),bytes32,bytes32,uint256,uint256,bytes)
// Block: 24
// Paid: 0.00000578798129616 ETH (109488 gas * 0.05286407 gwei)


// console.log("  tx: scenario 4 - SwapVM - PiecewiseLinearScale auction");
// ##### anvil-hardhat
// ✅  [Success] Hash: 0x11cae6f0f29a5437b6a1e8bce1c35f5bdaaaa7c063fb9b2f8bce9e9b8ec4d81b
// Contract: LimitSwapVMRouter
// Function: swap((address,uint256,bytes),uint256,bytes)
// Block: 25
// Paid: 0.000005034341865285 ETH (108723 gas * 0.046304295 gwei)


// console.log("  tx: scenario 5 - LOP    - private (allowedSender)");
// ##### anvil-hardhat
// ✅  [Success] Hash: 0x60051243e16fac70dd1979d69cd7ea9ae702fa4445ca819aec226debcb32ea1f
// Contract: LimitOrderProtocol
// Function: fillOrderArgs((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256),bytes32,bytes32,uint256,uint256,bytes)
// Block: 26
// Paid: 0.00000391954560768 ETH (96640 gas * 0.040558212 gwei)


// console.log("  tx: scenario 5 - SwapVM - private (whitelistSingleTaker)");
// ##### anvil-hardhat
// ✅  [Success] Hash: 0x147a02936a27cc17889ea518ff76321c89186d58c00c23ee7a950bfc06f877b2
// Contract: LimitSwapVMRouter
// Function: swap((address,uint256,bytes),uint256,bytes)
// Block: 27
// Paid: 0.000003833827736169 ETH (107931 gas * 0.035521099 gwei)


    function run() external {
        maker = vm.addr(MAKER_PK);
        taker = vm.addr(TAKER_PK);
        auctionStartTime = uint32(block.timestamp); // real node time => fills land just after the start

        _deployFundApprove();

        console.log("");
        console.log("Broadcast order of metered fill transactions (gasUsed reported by the node):");

        // Each call below is one broadcast transaction; gasUsed is in run-latest.json receipts (same order).
        console.log("  tx: scenario 1 - LOP    - simplest order (clean nonce slot)");
        _fillLop(0, "", address(0));
        console.log("  tx: scenario 1 - SwapVM - simplest order (clean bit slot)");
        _fillVm(_vmLimitProgram(0));

        console.log("  tx: scenario 2 - LOP    - nonce slot already non-zero");
        _fillLop(1, "", address(0));
        console.log("  tx: scenario 2 - SwapVM - bit slot already non-zero");
        _fillVm(_vmLimitProgram(1));

        console.log("  tx: scenario 3 - Fusion - no fusion features (rate bump 0)");
        _fillLop(256, _fusionExtension(0), address(0));
        console.log("  tx: scenario 3 - SwapVM - plain limit");
        _fillVm(_vmLimitProgram(256));

        console.log("  tx: scenario 4 - Fusion - Dutch auction");
        _fillLop(512, _fusionExtension(INITIAL_RATE_BUMP), address(0));
        console.log("  tx: scenario 4 - SwapVM - PiecewiseLinearScale auction");
        _fillVm(_vmAuctionProgram(512, INITIAL_RATE_BUMP));

        console.log("  tx: scenario 5 - LOP    - private (allowedSender)");
        _fillLop(768, "", taker);
        console.log("  tx: scenario 5 - SwapVM - private (whitelistSingleTaker)");
        _fillVm(_vmWhitelistedLimitProgram(768, taker));
    }

    // =============================================================================================
    // Deployment, funding, approvals — all broadcast
    // =============================================================================================

    function _deployFundApprove() internal {
        vm.startBroadcast(); // deployer = the CLI sender (a funded node account)
        aqua = new Aqua();
        weth = IWETH(address(new WrappedTokenMock("Wrapped Ether", "WETH")));
        lop = new LimitOrderProtocol(weth);
        swapVM = new LimitSwapVMRouter(address(aqua), address(weth), maker, "SwapVM", "1.0.0");
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        settlement = deployCode(
            "SimpleSettlement.sol:SimpleSettlement",
            abi.encode(address(lop), IERC20(address(tokenA)), address(weth), maker)
        );

        // Both tokens to both parties so every balance slot starts non-zero (scenario 1 vs 2 then differ
        // only by the invalidator slot). Fund maker/taker with ETH so they can send their own transactions.
        tokenA.mint(maker, type(uint224).max);
        tokenB.mint(maker, type(uint224).max);
        tokenA.mint(taker, type(uint224).max);
        tokenB.mint(taker, type(uint224).max);
        (bool s1,) = maker.call{ value: 1 ether }("");
        (bool s2,) = taker.call{ value: 1 ether }("");
        require(s1 && s2, "funding failed");
        vm.stopBroadcast();

        vm.startBroadcast(MAKER_PK);
        tokenB.approve(address(lop), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
        vm.stopBroadcast();

        vm.startBroadcast(TAKER_PK);
        tokenA.approve(address(lop), type(uint256).max);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.stopBroadcast();
    }

    // =============================================================================================
    // LOP / Fusion order build + broadcast fill
    // =============================================================================================

    function _toAddress(address a) internal pure returns (Address) {
        return Address.wrap(uint256(uint160(a)));
    }

    /// @notice Build + sign a single-fill LOP order and broadcast a full exact-out fill (one transaction).
    function _fillLop(uint40 nonce, bytes memory extension, address allowedSender) internal {
        uint256 mt = M_NO_PARTIAL_FILLS | (uint256(nonce) << M_NONCE_OFFSET)
            | (uint256(uint160(allowedSender)) & type(uint80).max);
        if (extension.length > 0) mt |= M_HAS_EXTENSION;

        uint256 salt = uint256(keccak256(abi.encode("lop", nonce, extension, allowedSender)));
        if (extension.length > 0) {
            salt = (salt & ~uint256(type(uint160).max)) | (uint256(keccak256(extension)) & type(uint160).max);
        }

        IOrderMixin.Order memory order = IOrderMixin.Order({
            salt: salt,
            maker: _toAddress(maker),
            receiver: _toAddress(address(0)),
            makerAsset: _toAddress(address(tokenB)),
            takerAsset: _toAddress(address(tokenA)),
            makingAmount: MAKING,
            takingAmount: TAKING,
            makerTraits: MakerTraits.wrap(mt)
        });

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PK, lop.hashOrder(order));
        bytes32 vs = bytes32(uint256(s) | (uint256(v - 27) << 255)); // EIP-2098
        uint256 tt = T_MAKER_AMOUNT | (extension.length << T_ARGS_EXTENSION_LENGTH_OFFSET); // exact-out full making

        vm.broadcast(TAKER_PK);
        lop.fillOrderArgs(order, r, vs, MAKING, TakerTraits.wrap(tt), extension);
    }

    /// @notice SimpleSettlement getter (no gas bump, single segment, zero fees/whitelist) in the LOP extension.
    function _fusionExtension(uint24 rateBump) internal view returns (bytes memory) {
        bytes memory getter = abi.encodePacked(
            bytes3(0), bytes4(0),
            uint32(auctionStartTime), uint24(AUCTION_DURATION), uint24(rateBump), uint8(0),
            uint16(0), uint8(0), uint16(0), uint8(0), uint8(0)
        );
        bytes memory data = abi.encodePacked(settlement, getter);
        uint256 m = data.length;
        uint256 mt = m + data.length;
        uint256 offsets = (m << 64) | (mt << 96) | (mt << 128) | (mt << 160) | (mt << 192) | (mt << 224);
        return abi.encodePacked(bytes32(offsets), data, data);
    }

    // =============================================================================================
    // SwapVM order build + broadcast fill
    // =============================================================================================

    function _vmLimitProgram(uint32 bit) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_staticBalancesXD, BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([TAKING, MAKING]))),
            p.build(_invalidateBit1D, InvalidatorsArgsBuilder.buildInvalidateBit(bit)),
            p.build(_limitSwapOnlyFull1D, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );
    }

    function _vmWhitelistedLimitProgram(uint32 bit, address allowedTaker) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_staticBalancesXD, BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([TAKING, MAKING]))),
            p.build(_whitelistSingleTaker, WhitelistArgsBuilder.buildWhitelistSingleTaker(allowedTaker)),
            p.build(_invalidateBit1D, InvalidatorsArgsBuilder.buildInvalidateBit(bit)),
            p.build(_limitSwapOnlyFull1D, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );
    }

    function _vmAuctionProgram(uint32 bit, uint24 rateBump) internal view returns (bytes memory) {
        uint256 denom = FUSION_BASE_POINTS + rateBump;
        uint24 scaleEnd = uint24(((uint256(1) << 24) * FUSION_BASE_POINTS + denom / 2) / denom - 1);
        uint16[] memory durations = new uint16[](1);
        durations[0] = uint16(AUCTION_DURATION);
        uint24[] memory scales = new uint24[](2);
        scales[0] = uint24(SCALE_ONE);
        scales[1] = scaleEnd;
        uint256 balanceIn = PiecewiseLinearScaleArgsBuilder.unscaleValue(TAKING, scaleEnd);

        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(_staticBalancesXD, BalancesArgsBuilder.build(dynamic([address(tokenA), address(tokenB)]), dynamic([balanceIn, MAKING]))),
            p.build(_piecewiseLinearScaleBalanceIn1D, PiecewiseLinearScaleArgsBuilder.build(auctionStartTime, durations, scales)),
            p.build(_invalidateBit1D, InvalidatorsArgsBuilder.buildInvalidateBit(bit)),
            p.build(_limitSwapOnlyFull1D, LimitSwapArgsBuilder.build(address(tokenA), address(tokenB)))
        );
    }

    /// @notice Build + sign the SwapVM order and broadcast a full exact-out fill (one transaction).
    function _fillVm(bytes memory program) internal {
        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: false,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(0),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: program
        }));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MAKER_PK, swapVM.hash(order));
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            getTokenBForTokenA: true,
            isExactIn: false,               // exact-out: buy the full makingAmount
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: taker,
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: abi.encodePacked(r, s, v)
        }));

        vm.broadcast(TAKER_PK);
        swapVM.swap(order, MAKING, takerData);
    }
}
