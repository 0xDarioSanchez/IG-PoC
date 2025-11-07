//SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

interface IUSDC {
    function transferFrom(address from, address to, uint256 amount) external returns(bool);
    function transfer(address to, uint256 amount) external returns(bool);
}