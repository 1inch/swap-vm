// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IWETH } from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";

contract WETHMock is ERC20 {
    error WithdrawFailed();

    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit IWETH.Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, WithdrawFailed());
        emit IWETH.Withdrawal(msg.sender, amount);
    }

    receive() external payable {
        deposit();
    }
}
