import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

// All three SwapVM routers share the same constructor:
//   (address aqua, address weth, address owner, string name, string version)
// This factory builds an Ignition module for one of them. Every parameter is
// required (no default) — a missing value fails Ignition's pre-deploy validation,
// mirroring the *DoesNotExist() reverts in the former script/utils/Config.sol.
export function routerModule(moduleId: string, contractName: string) {
  return buildModule(moduleId, (m) => {
    const aqua = m.getParameter("aqua");
    const weth = m.getParameter("weth");
    const owner = m.getParameter("owner");
    const name = m.getParameter("name");
    const version = m.getParameter("version");

    const router = m.contract(contractName, [aqua, weth, owner, name, version]);

    return { router };
  });
}
