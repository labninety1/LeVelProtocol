// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10; 

interface ILP {
    function approve(address _spender, uint _amount) external;
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}