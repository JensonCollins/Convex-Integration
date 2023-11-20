// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Interface for the base reward pool
interface IBaseRewardPool {
    function withdraw(uint256 amount, bool claim) external returns (bool);

    function withdrawAll(bool claim) external;

    function withdrawAndUnwrap(
        uint256 amount,
        bool claim
    ) external returns (bool);

    function withdrawAllAndUnwrap(bool claim) external;

    function stakingToken() external returns (IERC20);

    function earned(address account) external view returns (uint256);

    function getReward(
        address _account,
        bool _claimExtras
    ) external returns (bool);
}
