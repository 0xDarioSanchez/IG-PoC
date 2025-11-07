//SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {

    uint8 private constant USDC_DECIMALS = 6;

    constructor() ERC20("USDC", "USDC") {
        //It mints a initial supply of 1 million USDC to the deployer
        _mint(msg.sender, 1_000_000_000_000_000_000 * 10 ** USDC_DECIMALS);
    }

    //In case of needing to mint more USDC for testing
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}