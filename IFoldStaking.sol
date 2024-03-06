// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

interface IFoldStaking {
    function LPStakes(address _lpAddress, address _userAddress) external view returns (uint256);
    function updatePool() external;
    function pendingRewards(address _address) external returns (uint256);
    function claimFoldToken(address _recipient) external;
    function claimSelfFoldToken() external;
    function deposit(uint _amount,address _to) external;
    function depositLP(uint256 _amount, address _lpAddress) external;
    function withdrawLP(uint256 _amount, address _lpAddress) external;
    function withdraw(uint _amount,address _from) external;
    function isValidLP(address _lpAddress) external view returns (bool isValid);
    function setContracts(address _address2652, address _addressFold, address _address91) external;
    function addValidLP(address _lpAddress) external;
    function removeValidLP(address _lpAddress) external;
    function addTimeRange(
        uint256 _amount,
        uint256 _startTimestamp,
        uint256 _endTimeStamp) external;
    function removeLastTimeRange() external;
    function transferOwnership(address newOwner) external;
}