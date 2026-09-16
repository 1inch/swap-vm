import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";

describe("Hardhat network", function () {
  it("responds to JSON-RPC requests", async function () {
    const connection = await network.create();

    try {
      const chainId = await connection.provider.request({
        method: "eth_chainId",
      });

      assert.equal(chainId, "0x7a69");
    } finally {
      await connection.close();
    }
  });
});
