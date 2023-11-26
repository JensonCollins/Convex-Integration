// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/Curve/ISPool.sol";
import "./interfaces/Convex/IBaseRewardPool.sol";
import "./interfaces/Convex/IBooster.sol";
import "./interfaces/IConvexToken.sol";
import "./interfaces/Uniswap/ISwapRouter.sol";

error InvalidToken();
error InvalidAmount();
error SwapFailed();
error CurveDepositFailed();
error InvalidUnderlyingAsset();

/**
 * @title ConvexVault Contract
 * @dev Main contract for the Convex Vault
 */
contract ConvexVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Structs declaration
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

    // Immutable and constants variables
    IBooster public constant cvxBooster =
        IBooster(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
    IConvexToken public constant cvxToken =
        IConvexToken(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20 public constant crvToken =
        IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint private constant MULTIPLIER = 1e18;

    IERC20 public immutable curveLP;
    IBaseRewardPool public immutable baseRewardPool;
    ISwapRouter public immutable swapRouter;
    ISPool public immutable curveSwap;
    uint256 public immutable convexPID;

    // State variables
    uint256 public totalSupply;
    uint256 public crvAmountPerShare;
    uint256 public cvxAmountPerShare;
    RewardIndex rewardIndex;

    // Arrays and mappings to store pool and user information
    mapping(address => bool) public underlyingAssets;
    mapping(address => UserInfo) public userInfos;

    // Events declaration
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 crvReward, uint256 cvxReward);

    constructor(ISwapRouter _swapRouter, ISPool _curveSwap, uint256 _pid) {
        swapRouter = _swapRouter;
        curveSwap = _curveSwap;
        baseRewardPool = IBaseRewardPool(cvxBooster.poolInfo(_pid).crvRewards);
        curveLP = IERC20(cvxBooster.poolInfo(_pid).lptoken);
        convexPID = _pid;
    }

    modifier _updateRewards(address _account) {
        getVaultRewards();
        UserInfo storage info = userInfos[_account];
        uint cvxReward = (info.amount *
            (rewardIndex.cvxIndex - info.rewardIndex.cvxIndex)) / MULTIPLIER;
        uint crvReward = (info.amount *
            (rewardIndex.crvIndex - info.rewardIndex.crvIndex)) / MULTIPLIER;
        info.crvEarned += crvReward;
        info.cvxEarned += cvxReward;
        info.rewardIndex = rewardIndex;
        _;
    }

    function _swapTokens(
        address tokenIn,
        address tokenOut,
        uint amountIn
    ) private returns (uint amountOut) {
        if (tokenIn != address(0)) {
            IERC20(tokenIn).approve(address(swapRouter), amountIn);
        }
        address inputToken = tokenIn == address(0) ? WETH : tokenIn;
        address outputToken = tokenOut == address(0) ? WETH : tokenOut;
        if (inputToken == WETH || outputToken == WETH) {
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
                .ExactInputSingleParams({
                    tokenIn: inputToken,
                    tokenOut: outputToken,
                    fee: 3000,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                });
            amountOut = swapRouter.exactInputSingle{
                value: tokenIn == address(0) ? amountIn : 0
            }(params);
        } else {
            bytes memory path = abi.encodePacked(
                inputToken,
                uint24(3000),
                WETH,
                uint24(3000),
                outputToken
            );
            ISwapRouter.ExactInputParams memory params = ISwapRouter
                .ExactInputParams({
                    path: path,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: 0
                });
            amountOut = swapRouter.exactInput{
                value: tokenIn == address(0) ? amountIn : 0
            }(params);
        }
    }

    // Owner functions
    function addUnderlyingAsset(address _token) external onlyOwner {
        if (underlyingAssets[_token]) revert InvalidUnderlyingAsset();
        underlyingAssets[_token] = true;
    }

    function removeUnderlyingAsset(address _token) external onlyOwner {
        if (!underlyingAssets[_token]) revert InvalidUnderlyingAsset();
        delete underlyingAssets[_token];
    }

    function getVaultRewards() public {
        uint256 crvBalance = crvToken.balanceOf(address(this));
        uint256 cvxBalance = cvxToken.balanceOf(address(this));
        IBaseRewardPool(baseRewardPool).getReward(address(this), true);

        uint256 updatedCrvBalance = crvToken.balanceOf(address(this));
        uint256 updatedCvxBalance = cvxToken.balanceOf(address(this));

        if (updatedCrvBalance > crvBalance && totalSupply > 0) {
            rewardIndex.crvIndex +=
                ((updatedCrvBalance - crvBalance) * MULTIPLIER) /
                totalSupply;
        }
        if (updatedCvxBalance > cvxBalance && totalSupply > 0) {
            rewardIndex.cvxIndex +=
                ((updatedCvxBalance - cvxBalance) * MULTIPLIER) /
                totalSupply;
        }
    }

    function calculateRewardsEarned(
        address _account
    ) external view returns (uint rewardCrv, uint rewardCvx) {
        UserInfo memory info = userInfos[_account];
        uint256 pendingCrvReward = baseRewardPool.earned(address(this));
        uint256 pendingCvxReward = getCvxRewardFromCrv(pendingCrvReward);
        if (totalSupply != 0) {
            uint256 newCvxIndex = rewardIndex.cvxIndex +
                (pendingCvxReward * MULTIPLIER) /
                totalSupply;
            uint256 newCrvIndex = rewardIndex.crvIndex +
                (pendingCrvReward * MULTIPLIER) /
                totalSupply;

            uint cvxReward = (info.amount *
                (newCvxIndex - info.rewardIndex.cvxIndex)) / MULTIPLIER;
            uint crvReward = (info.amount *
                (newCrvIndex - info.rewardIndex.crvIndex)) / MULTIPLIER;

            rewardCrv = userInfos[_account].crvEarned + crvReward;
            rewardCvx = userInfos[_account].cvxEarned + cvxReward;
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
            amount = (_crvAmount * reduction) / totalCliffs;

            //supply cap check
            uint256 amtTillMax = maxSupply - supply;
            if (amount > amtTillMax) {
                amount = amtTillMax;
            }
        }
        return amount;
    }

    function deposit(
        address _token,
        uint256 _amount
    ) external payable _updateRewards(msg.sender) {
        if (!underlyingAssets[_token]) revert InvalidToken();
        if (_amount <= 0) revert InvalidAmount();

        if (_token != address(0)) {
            IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        }

        uint256 lpBalanceBeforeDeposit = curveLP.balanceOf(address(this));

        uint256[3] memory amounts;
        if (curveSwap.coins(0) == _token) {
            amounts = [_amount, 0, 0];
            IERC20(_token).approve(address(curveSwap), _amount);
        } else if (curveSwap.coins(1) == _token) {
            amounts = [0, _amount, 0];
            IERC20(_token).approve(address(curveSwap), _amount);
        } else if (curveSwap.coins(2) == _token) {
            amounts = [0, 0, _amount];
            IERC20(_token).approve(address(curveSwap), _amount);
        } else {
            address tokenOut = curveSwap.coins(0);
            uint256 amountIn = _token == address(0) ? msg.value : _amount;
            uint256 token0Amount = _swapTokens(_token, tokenOut, amountIn);
            if (token0Amount == 0) revert SwapFailed();

            amounts = [token0Amount, 0, 0];
            IERC20(tokenOut).approve(address(curveSwap), token0Amount);
        }

        curveSwap.add_liquidity(amounts, 0);

        uint256 lpBalanceAfterDeposit = curveLP.balanceOf(address(this));

        uint256 lpBalance = lpBalanceAfterDeposit - lpBalanceBeforeDeposit;
        if (lpBalance == 0) revert CurveDepositFailed();

        UserInfo storage info = userInfos[msg.sender];

        info.amount += lpBalance;
        totalSupply = totalSupply + lpBalance;

        curveLP.approve(address(cvxBooster), lpBalance);
        cvxBooster.deposit(convexPID, lpBalance, true);

        emit Deposit(msg.sender, _amount);
    }

    function withdraw(
        uint256 _amount,
        address _swapToken,
        bool _swapRewards
    ) external _updateRewards(msg.sender) {
        if (_amount <= 0) revert InvalidAmount();

        UserInfo storage info = userInfos[msg.sender];
        if (_amount > info.amount) revert InvalidAmount();

        baseRewardPool.withdraw(_amount, true);
        cvxBooster.withdraw(convexPID, _amount);
        claim(_swapRewards, _swapToken);

        uint256[3] memory tokenBalancesBefore;
        uint256[3] memory tokenBalancesAfter;
        for (uint256 i; i < 3; ++i) {
            address token = curveSwap.coins(i);
            tokenBalancesBefore[i] = IERC20(token).balanceOf(address(this));
        }

        curveSwap.remove_liquidity(_amount, [uint256(0), 0, 0]);

        for (uint256 i; i < 3; ++i) {
            address token = curveSwap.coins(i);
            tokenBalancesAfter[i] = IERC20(token).balanceOf(address(this));
            uint256 amount = tokenBalancesAfter[i] - tokenBalancesBefore[i];
            if (amount > 0) {
                IERC20(token).safeTransfer(msg.sender, amount);
            }
        }

        info.amount -= _amount;
        totalSupply = totalSupply - _amount;

        emit Withdraw(msg.sender, _amount);
    }

    // Function to claim rewards
    function claim(
        bool _swapRewards,
        address _swapToken
    ) public nonReentrant _updateRewards(msg.sender) {
        UserInfo storage info = userInfos[msg.sender];
        uint256 cvxReward = info.cvxEarned;
        uint256 crvReward = info.crvEarned;

        if (crvReward > 0) {
            if (_swapRewards) {
                uint256 swapTokenAmount = _swapTokens(
                    address(crvToken),
                    _swapToken,
                    crvReward
                );
                if (swapTokenAmount == 0) revert SwapFailed();
                IERC20(_swapToken).transfer(msg.sender, swapTokenAmount);
            } else {
                crvToken.transfer(msg.sender, crvReward);
            }
            info.crvEarned = 0;
        }

        if (cvxReward > 0) {
            if (_swapRewards) {
                uint256 swapTokenAmount = _swapTokens(
                    address(cvxToken),
                    _swapToken,
                    cvxReward
                );
                if (swapTokenAmount == 0) revert SwapFailed();
                IERC20(_swapToken).transfer(msg.sender, swapTokenAmount);
            } else {
                cvxToken.transfer(msg.sender, cvxReward);
            }
            info.cvxEarned = 0;
        }

        emit Claim(msg.sender, crvReward, cvxReward);
    }

    receive() external payable {}
}
