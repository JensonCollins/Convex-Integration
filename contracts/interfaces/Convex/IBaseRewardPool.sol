// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBaseRewardPool {
    function earned(address account) external view returns (uint256);

    function withdraw(uint256 amount, bool claim) external returns (bool);

    function withdrawAll(bool claim) external;

    function getReward(
        address _account,
        bool _claimExtras
    ) external returns (bool);

    function withdrawAndUnwrap(
        uint256 amount,
        bool claim
    ) external returns (bool);

    function stakingToken() external returns (IERC20);
}
