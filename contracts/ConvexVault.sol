// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IBooster.sol";
import "./interfaces/IBaseRewardPool.sol";
import "./interfaces/IConvexToken.sol";

// Vault contract, inheriting from Ownable
contract Vault is Ownable {
    struct RewardIndex {
        uint256 cvxIndex; // CVX reward Index
        uint256 crvIndex; // CRV reward Index
    }

    struct UserInfo {
        uint256 cvxEarned;
        uint256 crvEarned;
        uint256 amount; // LP token amount that user has provided.
        RewardIndex rewardIndex;
    }

    // Pool information structure
    struct PoolInfo {
        IERC20 lpToken; // LP token address
        uint256 convexPid;
        uint256 allocPoint; // How many allocation points assigned to this pool
        uint256 totalSupply;
    }

    // Constants and contract instances
    IBooster public constant cvxBooster =
        IBooster(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
    IConvexToken public constant cvxToken =
        IConvexToken(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20 public constant crvToken =
        IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    uint private constant MULTIPLIER = 1e18;

    // Arrays and mappings to store pool and user information
    PoolInfo[] public poolInfo;
    uint256 public totalAllocPoint = 0;
    mapping(uint256 => mapping(address => UserInfo)) public userInfos;
    mapping(uint256 => RewardIndex) public rewardIndexs;

    // Event emitted on deposit
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    // Event emitted on withdrawal
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);

    // Event emitted on reward payment
    event RewardPaid(
        address indexed user,
        uint256 indexed pid,
        uint256 crvReward,
        uint256 cvxReward
    );

    // Function to get the number of pools
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Function to get information about a Convex pool
    function getConvexPoolInfo(
        uint256 _pid
    ) public view returns (IBooster.PoolInfo memory) {
        return cvxBooster.poolInfo(poolInfo[_pid].convexPid);
    }

    // Function to add a new pool
    function addPool(
        uint256 _allocPoint,
        address _lpToken,
        uint256 _pid
    ) public onlyOwner {
        IBooster.PoolInfo memory cvxPoolInfo = cvxBooster.poolInfo(_pid);
        require(_lpToken == cvxPoolInfo.lptoken, "Pid is wrong");
        totalAllocPoint = totalAllocPoint + _allocPoint;
        poolInfo.push(
            PoolInfo({
                lpToken: IERC20(_lpToken),
                convexPid: _pid,
                allocPoint: _allocPoint,
                totalSupply: 0
            })
        );
    }

    // Function to get rewards from Convex and update reward indices
    function getVaultRewards(uint256 _pid) public {
        uint256 crvBalance = crvToken.balanceOf(address(this));
        uint256 cvxBalance = cvxToken.balanceOf(address(this));
        IBooster.PoolInfo memory convexPool = getConvexPoolInfo(_pid);
        IBaseRewardPool(convexPool.crvRewards).getReward(address(this), true);

        uint256 updatedCrvBalance = crvToken.balanceOf(address(this));
        uint256 updatedCvxBalance = cvxToken.balanceOf(address(this));

        if (updatedCrvBalance > crvBalance && poolInfo[_pid].totalSupply > 0) {
            rewardIndexs[_pid].crvIndex +=
                ((updatedCrvBalance - crvBalance) * MULTIPLIER) /
                poolInfo[_pid].totalSupply;
        }
        if (updatedCvxBalance > cvxBalance && poolInfo[_pid].totalSupply > 0) {
            rewardIndexs[_pid].cvxIndex +=
                ((updatedCvxBalance - cvxBalance) * MULTIPLIER) /
                poolInfo[_pid].totalSupply;
        }
    }

    // Function to get the total rewards earned by a user
    function calculateRewardsEarned(
        address _account,
        uint256 _pid
    ) external view returns (uint rewardCrv, uint rewardCvx) {
        IBooster.PoolInfo memory convexPool = getConvexPoolInfo(_pid);
        UserInfo memory info = userInfos[_pid][_account];
        uint256 pendingCrvReward = IBaseRewardPool(convexPool.crvRewards)
            .earned(address(this));
        uint256 pendingCvxReward = getCvxRewardFromCrv(pendingCrvReward);
        if (poolInfo[_pid].totalSupply != 0) {
            uint256 newCvxIndex = rewardIndexs[_pid].cvxIndex +
                (pendingCvxReward * MULTIPLIER) /
                poolInfo[_pid].totalSupply;
            uint256 newCrvIndex = rewardIndexs[_pid].crvIndex +
                (pendingCrvReward * MULTIPLIER) /
                poolInfo[_pid].totalSupply;

            uint cvxReward = (info.amount *
                (newCvxIndex - info.rewardIndex.cvxIndex)) / MULTIPLIER;
            uint crvReward = (info.amount *
                (newCrvIndex - info.rewardIndex.crvIndex)) / MULTIPLIER;

            rewardCrv = userInfos[_pid][_account].crvEarned + crvReward;
            rewardCvx = userInfos[_pid][_account].cvxEarned + cvxReward;
        }
    }

    function getCvxRewardFromCrv(
        uint256 _crvAmount
    ) internal view returns (uint256) {
        uint256 amount = 0;
        uint256 supply = cvxToken.totalSupply();
        uint256 reductionPerCliff = cvxToken.reductionPerCliff();
        uint256 totalCliffs = cvxToken.totalCliffs();
        uint256 cliff = supply / reductionPerCliff;
        uint256 maxSupply = cvxToken.maxSupply();
        if (cliff < totalCliffs) {
            uint256 reduction = totalCliffs - cliff;
            //reduce
            amount = _crvAmount * reduction / totalCliffs;

            //supply cap check
            uint256 amtTillMax = maxSupply - supply;
            if (amount > amtTillMax) {
                amount = amtTillMax;
            }
        }
        return amount;
    }

    // Function to update user rewards
    modifier _updateRewards(address _account, uint256 _pid) {
        getVaultRewards(_pid);
        UserInfo storage info = userInfos[_pid][_account];
        uint cvxReward = (info.amount *
            (rewardIndexs[_pid].cvxIndex - info.rewardIndex.cvxIndex)) /
            MULTIPLIER;
        uint crvReward = (info.amount *
            (rewardIndexs[_pid].crvIndex - info.rewardIndex.crvIndex)) /
            MULTIPLIER;
        info.crvEarned += crvReward;
        info.cvxEarned += cvxReward;
        info.rewardIndex = rewardIndexs[_pid];
        _;
    }

    // Function to deposit LP tokens into ConvexVault
    function deposit(
        uint256 _pid,
        uint256 _amount
    ) public _updateRewards(msg.sender, _pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfos[_pid][msg.sender];

        pool.lpToken.transferFrom(address(msg.sender), address(this), _amount);

        user.amount = user.amount + _amount;
        pool.totalSupply = pool.totalSupply + _amount;

        uint balance = pool.lpToken.balanceOf(address(this));
        pool.lpToken.approve(address(cvxBooster), balance);
        cvxBooster.deposit(pool.convexPid, balance, true);

        emit Deposit(msg.sender, _pid, _amount);
    }

    // Function to withdraw LP tokens from ConvexVault
    function withdraw(
        uint256 _pid,
        uint256 _amount
    ) public _updateRewards(msg.sender, _pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfos[_pid][msg.sender];
        IBooster.PoolInfo memory convexPool = getConvexPoolInfo(_pid);
        require(user.amount >= _amount, "withdraw: not good");
        claim(_pid, msg.sender);

        IBaseRewardPool(convexPool.crvRewards).withdraw(_amount, true);
        cvxBooster.withdraw(pool.convexPid, _amount);

        user.amount = user.amount - _amount;
        pool.totalSupply = pool.totalSupply - _amount;
        pool.lpToken.transfer(address(msg.sender), _amount);

        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Function to claim rewards
    function claim(
        uint256 _pid,
        address _account
    ) public _updateRewards(_account, _pid) {
        UserInfo storage user = userInfos[_pid][_account];
        uint256 cvxReward = user.cvxEarned;
        uint256 crvReward = user.crvEarned;
        if (cvxReward > 0) {
            user.cvxEarned = 0;
            cvxToken.transfer(_account, cvxReward);
        }
        if (crvReward > 0) {
            user.crvEarned = 0;
            crvToken.transfer(_account, crvReward);
        }

        emit RewardPaid(_account, _pid, crvReward, cvxReward);
    }
}
