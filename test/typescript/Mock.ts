import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
const { ethers } = await network.create({ override: { allowUnlimitedContractSize: true } });

describe("SwapVM", function () {
    it("executes a limit swap strategy", async function () {
        const LIQUIDITY = 100n * 10n ** 18n;
        const SWAP_AMOUNT = 10n * 10n ** 18n;

        const [owner, taker] = await ethers.getSigners();
        const maker = ethers.Wallet.createRandom().connect(ethers.provider);
        const uint256 = (value: bigint) => ethers.zeroPadValue(ethers.toBeHex(value), 32);
        const instruction = (opcode: number, args: string) =>
            ethers.concat([ethers.toBeHex(opcode, 1), ethers.toBeHex(ethers.getBytes(args).length, 1), args]);

        await (await owner.sendTransaction({ to: maker.address, value: 10n ** 18n })).wait();

        const firstToken = await ethers.deployContract("TokenMock", ["Token A", "TKA"], owner);
        const secondToken = await ethers.deployContract("TokenMock", ["Token B", "TKB"], owner);
        await Promise.all([firstToken.waitForDeployment(), secondToken.waitForDeployment()]);

        const firstTokenAddress = await firstToken.getAddress();
        const secondTokenAddress = await secondToken.getAddress();
        const [tokenA, tokenB] =
            BigInt(firstTokenAddress) < BigInt(secondTokenAddress) ? [firstToken, secondToken] : [secondToken, firstToken];
        const tokenAAddress = await tokenA.getAddress();
        const tokenBAddress = await tokenB.getAddress();

        const router = await ethers.deployContract(
            "LimitSwapVMRouter", [ethers.ZeroAddress, ethers.ZeroAddress, await owner.getAddress(), "SwapVM", "1.0.0"], owner
        );
        await router.waitForDeployment();
        const routerAddress = await router.getAddress();

        await (await tokenA.mint(maker.address, LIQUIDITY)).wait();
        await (await tokenB.mint(await taker.getAddress(), LIQUIDITY)).wait();
        await (await tokenA.connect(maker).getFunction("approve")(routerAddress, ethers.MaxUint256)).wait();
        await (await tokenB.connect(taker).getFunction("approve")(routerAddress, ethers.MaxUint256)).wait();

        const strategy = ethers.concat([
            instruction(0x90, ethers.concat([uint256(LIQUIDITY), uint256(LIQUIDITY)])),
            instruction(0x53, "0x00"),
        ]);
        const order = {
            maker: maker.address,
            traits: 0x0028002800280028n << 160n,
            data: ethers.concat([tokenAAddress, tokenBAddress, strategy]),
        };
        const orderHash = await router.hash(order);
        const signature = ethers.Signature.from(maker.signingKey.sign(orderHash)).serialized;
        const takerData = ethers.concat([`0x${"00".repeat(20)}`, "0x0021", signature]);

        const swap = router.connect(taker).getFunction("swap");
        const [amountIn, amountOut] = await swap.staticCall(order, SWAP_AMOUNT, takerData);
        assert.equal(amountIn, SWAP_AMOUNT);
        assert.equal(amountOut, SWAP_AMOUNT);

        await (await swap(order, SWAP_AMOUNT, takerData)).wait();

        assert.equal(await tokenA.balanceOf(maker.address), LIQUIDITY - SWAP_AMOUNT);
        assert.equal(await tokenB.balanceOf(maker.address), SWAP_AMOUNT);
        assert.equal(await tokenA.balanceOf(await taker.getAddress()), SWAP_AMOUNT);
        assert.equal(await tokenB.balanceOf(await taker.getAddress()), LIQUIDITY - SWAP_AMOUNT);
    });
});
