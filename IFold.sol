// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

interface IFold {
    function approve(address _spender, uint _amount) external;
    function mint(uint _amount) external;
    function balanceOf(address who) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}
