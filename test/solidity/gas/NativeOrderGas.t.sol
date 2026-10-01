// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { IWETH } from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { ISwapVM } from "../../../contracts/interfaces/ISwapVM.sol";
import { LimitSwapVMRouter } from "../../../contracts/routers/LimitSwapVMRouter.sol";
import { MakerTraitsLib } from "../../../contracts/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../../contracts/libs/TakerTraits.sol";
import { StaticBalances } from "../../../contracts/instructions/Balances.sol";
import { LimitSwap } from "../../../contracts/instructions/LimitSwap.sol";
import { Deadline } from "../../../contracts/instructions/Controls.sol";
import { InvalidateTokenOut } from "../../../contracts/instructions/Invalidators.sol";
import { WETHMock } from "../mocks/WETHMock.sol";

import { NativeOrderEscrow } from "../../../contracts/prototypes/nativeorder/NativeOrderEscrow.sol";
import { NativeOrderEscrowFactory } from "../../../contracts/prototypes/nativeorder/NativeOrderEscrowFactory.sol";
import { IBaseEscrow } from "../../../contracts/prototypes/nativeorder/vendor/interfaces/IBaseEscrow.sol";
import { Timelocks, TimelocksLib } from "../../../contracts/prototypes/nativeorder/vendor/libraries/TimelocksLib.sol";

/// @title NativeOrderGas
/// @notice Native ETH order (escrow clone) gas benchmarks: lifecycle calls of the escrow flow, plus the same
/// WETH-selling program as a plain EOA-signed order for reference. Values include calldata cost.
contract NativeOrderGas is Test {
    uint256 private constant WETH_AMOUNT = 1 ether;
    uint256 private constant DAI_AMOUNT = 3000e18;
    uint32 private constant EXPIRY_OFFSET = 1 days;
    uint32 private constant PUBLIC_CANCEL_OFFSET = 1 days + 1 hours;
    uint32 private constant RESCUE_DELAY = 7 days;

    LimitSwapVMRouter public swapVM;
    WETHMock public weth;
    TokenMock public dai;
    NativeOrderEscrowFactory public factory;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public resolver;
    bool public isAToB;

    ISwapVM.Order internal makerOrder;
    ISwapVM.Order internal filledOrder;
    IBaseEscrow.Immutables internal immutables;
    NativeOrderEscrow internal escrow;
    bytes32 internal filledOrderHash;

    function setUp() public {
        maker = vm.addr(makerPK);
        resolver = makeAddr("resolver");

        weth = new WETHMock();
        dai = new TokenMock("DAI", "DAI");
        TokenMock accessToken = new TokenMock("Resolver Access", "RAT");
        swapVM = new LimitSwapVMRouter(address(0), address(weth), address(this), "SwapVM", "1.0.0");
        factory = new NativeOrderEscrowFactory(
            ISwapVM(address(swapVM)),
            IWETH(address(weth)),
            IERC20(address(accessToken)),
            RESCUE_DELAY
        );

        vm.deal(maker, 100 ether);
        accessToken.mint(resolver, 1);
        dai.mint(address(this), 1e30);
        dai.approve(address(swapVM), type(uint256).max);

        // The program sells WETH regardless of token sort order
        isAToB = address(dai) < address(weth);
        vm.fee(1 gwei);
    }

    // === Escrow lifecycle ===

    function test_gas_NativeOrder_create() public {
        makerOrder = _buildOrder();
        Timelocks timelocks = _timelocks();
        vm.prank(maker);
        factory.create{ value: WETH_AMOUNT }(makerOrder, timelocks);
        _snapshot("create", abi.encodeCall(NativeOrderEscrowFactory.create, (makerOrder, timelocks)));
    }

    function test_gas_NativeOrder_swap_exactIn() public {
        _createEscrow();
        _snapshotSwap("swap_exactIn", filledOrder, DAI_AMOUNT, _escrowTakerData(true));
    }

    function test_gas_NativeOrder_swap_exactOut() public {
        _createEscrow();
        _snapshotSwap("swap_exactOut", filledOrder, WETH_AMOUNT, _escrowTakerData(false));
    }

    function test_gas_NativeOrder_quote_exactIn() public {
        _createEscrow();
        _snapshotQuote("quote_exactIn", filledOrder, DAI_AMOUNT, _escrowTakerData(true));
    }

    function test_gas_NativeOrder_quote_exactOut() public {
        _createEscrow();
        _snapshotQuote("quote_exactOut", filledOrder, WETH_AMOUNT, _escrowTakerData(false));
    }

    function test_gas_NativeOrder_cancel() public {
        _createEscrow();
        vm.prank(maker);
        escrow.cancel(immutables, filledOrderHash);
        _snapshot("cancel", abi.encodeCall(NativeOrderEscrow.cancel, (immutables, filledOrderHash)));
    }

    function test_gas_NativeOrder_publicCancel() public {
        _createEscrow();
        vm.warp(block.timestamp + PUBLIC_CANCEL_OFFSET);
        vm.prank(resolver);
        escrow.publicCancel(immutables, filledOrderHash, type(uint256).max);
        _snapshot(
            "publicCancel",
            abi.encodeCall(NativeOrderEscrow.publicCancel, (immutables, filledOrderHash, type(uint256).max))
        );
    }

    // === Reference: same program as a plain EOA-signed WETH order ===

    function test_gas_NativeOrder_referenceEoaSwap_exactIn() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _eoaOrder(true);
        _snapshotSwap("referenceEoaSwap_exactIn", order, DAI_AMOUNT, takerData);
    }

    function test_gas_NativeOrder_referenceEoaSwap_exactOut() public {
        (ISwapVM.Order memory order, bytes memory takerData) = _eoaOrder(false);
        _snapshotSwap("referenceEoaSwap_exactOut", order, WETH_AMOUNT, takerData);
    }

    // === Helpers ===

    function _snapshotSwap(string memory name, ISwapVM.Order memory order, uint256 amount, bytes memory takerData) internal {
        swapVM.swap(order, amount, takerData);
        _snapshot(name, abi.encodeCall(ISwapVM.swap, (order, amount, takerData)));
    }

    function _snapshotQuote(string memory name, ISwapVM.Order memory order, uint256 amount, bytes memory takerData) internal {
        swapVM.asView().quote(order, amount, takerData);
        _snapshot(name, abi.encodeCall(ISwapVM.quote, (order, amount, takerData)));
    }

    /// @dev Must be called right after the measured call.
    function _snapshot(string memory name, bytes memory callData) internal {
        uint256 gasUsed = uint256(vm.lastCallGas().gasTotalUsed);
        vm.snapshotValue("NativeOrder", name, gasUsed + _calldataGas(callData));
    }

    function _calldataGas(bytes memory data) internal pure returns (uint256 gas) {
        for (uint256 i; i < data.length; i++) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }

    function _createEscrow() internal {
        makerOrder = _buildOrder();
        vm.prank(maker);
        (address escrowAddr, bytes32 fHash, IBaseEscrow.Immutables memory imm) =
            factory.create{ value: WETH_AMOUNT }(makerOrder, _timelocks());

        escrow = NativeOrderEscrow(payable(escrowAddr));
        filledOrderHash = fHash;
        immutables = imm;
        filledOrder = makerOrder;
        filledOrder.maker = escrowAddr;
    }

    /// @dev Exact WETH allowance, matching what the escrow grants, so the comparison isolates the escrow overhead.
    function _eoaOrder(bool isExactIn) internal returns (ISwapVM.Order memory order, bytes memory takerData) {
        vm.startPrank(maker);
        weth.deposit{ value: WETH_AMOUNT }();
        weth.approve(address(swapVM), WETH_AMOUNT);
        vm.stopPrank();

        order = _buildOrder();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, swapVM.hash(order));
        takerData = _takerData(isExactIn, abi.encodePacked(r, s, v));
    }

    function _buildOrder() internal view returns (ISwapVM.Order memory) {
        MakerTraitsLib.Args memory args;
        args.maker = maker;
        args.receiver = maker;
        (args.tokenA, args.tokenB) = isAToB ? (address(dai), address(weth)) : (address(weth), address(dai));
        args.program = bytes.concat(
            Deadline.build(uint40(block.timestamp + EXPIRY_OFFSET)),
            StaticBalances.build(DAI_AMOUNT, WETH_AMOUNT),
            InvalidateTokenOut.build(),
            LimitSwap.build(address(dai), address(weth))
        );
        return MakerTraitsLib.build(args);
    }

    function _timelocks() internal pure returns (Timelocks) {
        return Timelocks.wrap(
            (uint256(EXPIRY_OFFSET) << (uint256(TimelocksLib.Stage.SrcCancellation) * 32)) |
            (uint256(PUBLIC_CANCEL_OFFSET) << (uint256(TimelocksLib.Stage.SrcPublicCancellation) * 32))
        );
    }

    function _escrowTakerData(bool isExactIn) internal view returns (bytes memory) {
        return _takerData(isExactIn, abi.encode(immutables, makerOrder.traits, keccak256(makerOrder.data)));
    }

    function _takerData(bool isExactIn, bytes memory signature) internal view returns (bytes memory) {
        TakerTraitsLib.Args memory args;
        args.isExactIn = isExactIn;
        args.isAToB = isAToB;
        args.to = address(this);
        args.signature = signature;
        return TakerTraitsLib.build(args);
    }
}
