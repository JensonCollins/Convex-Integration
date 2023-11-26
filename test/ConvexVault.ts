import { expect } from "chai";
import { ethers, network } from "hardhat";
import { BigNumber, Signer } from "ethers";
import { formatEther, parseEther } from "ethers/lib/utils";
import { mine, time } from "@nomicfoundation/hardhat-network-helpers";
import { ConvexVault, IBooster, IERC20 } from "../typechain-types";

const lpTokenAddress = "0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490";
const swapRouterAddress = "0xE592427A0AEce92De3Edee1F18E0157C05861564";
const curveSwapAddress = "0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7";
const crvTokenAddress = "0xD533a949740bb3306d119CC777fa900bA034cd52";
const cvxTokenAddress = "0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B";
const daiAddress = "0x6B175474E89094C44Da98b954EedeAC495271d0F";
const usdcAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const wethAddress = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const convexPid = 9;

describe("ConvexVault Test", function () {
    let convexVault: ConvexVault;
    let signer0: Signer, signer1: Signer;
    let lpToken: IERC20, cvxToken: IERC20, crvToken: IERC20, daiToken: IERC20, usdcToken: IERC20, wethToken: IERC20;
    let booster: IBooster;

    beforeEach(async function () {

        const Vault = await ethers.getContractFactory("ConvexVault");

        convexVault = await Vault.deploy(swapRouterAddress, curveSwapAddress, convexPid);
        await convexVault.deployed();

        console.log(`ConvexVault deployed to ${convexVault.address}`);

        await network.provider.request({
            method: "hardhat_impersonateAccount",
            params: ["0xc499FEA2c04101Aa2d99455a016b4eb6189F1fA9"],
        });
        signer0 = await ethers.getSigner("0xc499FEA2c04101Aa2d99455a016b4eb6189F1fA9");

        await network.provider.request({
            method: "hardhat_impersonateAccount",
            params: ["0x3C5348c8981f2d9759f4219a6F14c87274675AB8"],
        });
        signer1 = await ethers.getSigner("0x3C5348c8981f2d9759f4219a6F14c87274675AB8");

        console.log("LP Token Address: ", lpTokenAddress);
        lpToken = await ethers.getContractAt("MockERC20", lpTokenAddress);
        crvToken = await ethers.getContractAt("MockERC20", crvTokenAddress);
        cvxToken = await ethers.getContractAt("MockERC20", cvxTokenAddress);
        daiToken = await ethers.getContractAt("MockERC20", daiAddress);
        usdcToken = await ethers.getContractAt("MockERC20", usdcAddress);
        wethToken = await ethers.getContractAt("MockERC20", wethAddress);

        booster = await ethers.getContractAt("IBooster", "0xF403C135812408BFbE8713b5A23a04b3D48AAE31");
        await booster.connect(signer1).earmarkRewards(convexPid);

        await convexVault.addUnderlyingAsset(usdcToken.address);
        await convexVault.addUnderlyingAsset(daiToken.address);
    });

    it('Should calculate rewards correctly without convexVault claim', async () => {
        const amount = parseEther("10000");
        const signerAddress = await signer0.getAddress();

        // Approve tokens
        await daiToken.connect(signer0).approve(convexVault.address, amount);
        console.log("Approved DAI for staking");
        // Deposit tokens && Stake
        await convexVault.connect(signer0).deposit(daiToken.address, amount);
        console.log("Deposited into convexVault and stake in the BaseRewardPool: ", formatEther(amount));

        // Get calculated rewards
        const rewards = await convexVault.calculateRewardsEarned(signerAddress);

        await time.increase(18000);
        await mine();
        // Get updated rewards
        const updatedRewards = await convexVault.calculateRewardsEarned(signerAddress);
        expect(updatedRewards[0].toString()).to.be.not.equal(rewards[0].toString());
        expect(updatedRewards[1].toString()).to.be.not.equal(rewards[1].toString());
        console.log("CRV Token Reward: ", parseFloat(formatEther(updatedRewards[0])) - parseFloat(formatEther(rewards[0])));
        console.log("CVX Token Reward: ", parseFloat(formatEther(updatedRewards[1])) - parseFloat(formatEther(rewards[1])));
        console.log("Confirmed rewards were genereated without getVaultRewards");
    }).timeout(300000);

    it('Should claim rewards correctly', async () => {
        const amount = parseEther("10000");
        const signerAddress = await signer0.getAddress();

        // Approve tokens
        await daiToken.connect(signer0).approve(convexVault.address, amount);
        console.log("Approved DAI for staking");
        // Deposit tokens && Stake
        await convexVault.connect(signer0).deposit(daiToken.address, amount);
        console.log("Deposited into convexVault and stake in the BaseRewardPool: ", formatEther(amount));

        // Get calculated rewards
        const rewards = await convexVault.calculateRewardsEarned(signerAddress);
        expect(rewards[0]).to.be.equal((0));
        expect(rewards[1]).to.be.equal((0));

        // Increaes 1 month
        await time.increase(3600 * 24 * 30);
        await convexVault.connect(signer0).getVaultRewards();

        // Claim rewards
        const crvBefore = await crvToken.balanceOf(signerAddress);
        const cvxBefore = await cvxToken.balanceOf(signerAddress);
        await convexVault.connect(signer0).claim(false, daiToken.address);
        const crvReward = await crvToken.balanceOf(signerAddress);
        const cvxReward = await cvxToken.balanceOf(signerAddress);

        console.log("CRV Token Reward: ", parseFloat(formatEther(crvReward)) - parseFloat(formatEther(crvBefore)));
        console.log("CVX Token Reward: ", parseFloat(formatEther(cvxReward)) - parseFloat(formatEther(cvxBefore)));
    }).timeout(300000);

    it('Should add or remove asset', async function () {

        await convexVault.addUnderlyingAsset(lpToken.address);

        let added = await convexVault.underlyingAssets(lpToken.address);
        expect(added).to.equal(true);

        await convexVault.removeUnderlyingAsset(lpToken.address);

        added = await convexVault.underlyingAssets(lpToken.address);
        expect(added).to.equal(false);
    });

    it('Should revert on wrong token address', async function () {
        const amount = parseEther("10000");
        await convexVault.removeUnderlyingAsset(daiToken.address);

        await daiToken.connect(signer0).approve(convexVault.address, amount);
        console.log("Approved tokens for staking");

        await expect(convexVault.connect(signer0).deposit(daiToken.address, amount)).to.be.revertedWith("Vault: Invalid asset");
    });


    it('Should deposit and withdraw tokens', async () => {
        const amount = parseEther("10000");
        const signerAddress = await signer0.getAddress();

        // Approve tokens
        await daiToken.connect(signer0).approve(convexVault.address, amount);
        console.log("Approved DAI for staking");
        // Deposit tokens && Stake
        await convexVault.connect(signer0).deposit(daiToken.address, amount);
        console.log("Deposited into convexVault and stake in the BaseRewardPool: ", formatEther(amount));

        // Check if the tokens were deposited
        const userInfo = await convexVault.userInfos(signerAddress);
        expect(userInfo.amount).to.be.not.equal(0);

        await convexVault.connect(signer0).withdraw(userInfo.amount.toString(), daiToken.address, false);
        console.log("Withdrawn from ConvexVault: ", formatEther(userInfo.amount.toString()));
        // Check if the tokens were withdrawn
        const userInfoAfterWithdraw = await convexVault.userInfos(signerAddress);
        expect(userInfoAfterWithdraw.amount).to.be.equal(0);
    }).timeout(300000);

    it('Should calculate rewards correctly', async () => {
        const amount = parseEther("10000");
        const signerAddress = await signer0.getAddress();

        // Approve tokens
        await daiToken.connect(signer0).approve(convexVault.address, amount);
        console.log("Approved DAI for staking");
        // Deposit tokens && Stake
        await convexVault.connect(signer0).deposit(daiToken.address, amount);
        console.log("Deposited into convexVault and stake in the BaseRewardPool: ", formatEther(amount));

        // Get calculated rewards
        const rewards = await convexVault.calculateRewardsEarned(signerAddress);
        expect(rewards[0]).to.be.equal((0));
        expect(rewards[1]).to.be.equal((0));

        await time.increase(18000);
        // Update rewards
        await convexVault.connect(signer0).getVaultRewards();

        // Get updated rewards
        const updatedRewards = await convexVault.calculateRewardsEarned(signerAddress);
        expect(updatedRewards[0].toString()).to.be.not.equal("0");
        expect(updatedRewards[1].toString()).to.be.not.equal("0");

        console.log("Confirmed rewards were genereated");
    }).timeout(300000);

    it('Should receive correct reward based on the staked amount', async () => {
        const amount0 = parseEther("1000");
        const amount1 = parseEther("10000");
        const signer0Address = await signer0.getAddress();
        const signer1Address = await signer1.getAddress();

        // Approve tokens
        await daiToken.connect(signer0).approve(convexVault.address, amount0);
        await daiToken.connect(signer1).approve(convexVault.address, amount1);
        console.log("Approved DAI for staking from Users");
        // Deposit tokens && Stake
        await convexVault.connect(signer0).deposit(daiToken.address, amount0);
        await convexVault.connect(signer1).deposit(daiToken.address, amount1);
        console.log("User 1 : Deposited into convexVault and stake in the BaseRewardPool: ", formatEther(amount0));
        console.log("User 2 : Deposited into convexVault and stake in the BaseRewardPool: ", formatEther(amount1));

        // Increaes 1 month
        await time.increase(18000);
        await convexVault.connect(signer0).getVaultRewards();

        // Claim rewards
        let crvReward0 = await crvToken.balanceOf(signer0Address);
        let cvxReward0 = await cvxToken.balanceOf(signer0Address);
        await convexVault.connect(signer0).claim(false, daiToken.address);
        crvReward0 = (await crvToken.balanceOf(signer0Address)).sub(crvReward0);
        cvxReward0 = (await cvxToken.balanceOf(signer0Address)).sub(cvxReward0);

        let crvReward1 = await crvToken.balanceOf(signer1Address);
        let cvxReward1 = await cvxToken.balanceOf(signer1Address);
        await convexVault.connect(signer1).claim(false, daiToken.address);
        crvReward1 = (await crvToken.balanceOf(signer1Address)).sub(crvReward1);
        cvxReward1 = (await cvxToken.balanceOf(signer1Address)).sub(cvxReward1);

        expect(crvReward0).to.be.within(crvReward1.toNumber() / 10 * 0.99, crvReward1.toNumber() / 10 * 1.01);
        expect(cvxReward0).to.be.within(cvxReward1.toNumber() / 10 * 0.99, cvxReward1.toNumber() / 10 * 1.01);
    }).timeout(300000);

    it('Check reward distributed based on the staked amount', async () => {
        const amount = parseEther("10000");
        const signer0Address = await signer0.getAddress();

        // Approve tokens
        await daiToken.connect(signer0).approve(convexVault.address, amount);
        console.log("Approved DAI for staking");
        // Deposit tokens && Stake
        await convexVault.connect(signer0).deposit(daiToken.address, amount);
        console.log("Deposited into convexVault and stake in the BaseRewardPool: ", formatEther(amount));
        // Increaes time
        await time.increase(18000);

        // Get calculated rewards
        const rewards0 = await convexVault.calculateRewardsEarned(signer0Address);
        console.log("CRV Reward calculated : ", formatEther(rewards0[0]));
        console.log("CVX Reward calculated : ", formatEther(rewards0[1]));
        await convexVault.connect(signer0).getVaultRewards();

        // Claim rewards
        let crvReward0 = await crvToken.balanceOf(signer0Address);
        let cvxReward0 = await cvxToken.balanceOf(signer0Address);
        await convexVault.connect(signer0).claim(false, daiToken.address);
        const cvxReward1 = await cvxToken.balanceOf(signer0Address);
        const crvReward1 = await crvToken.balanceOf(signer0Address);
        crvReward0 = crvReward1.sub(crvReward0);
        cvxReward0 = cvxReward1.sub(cvxReward0);
        console.log("CRV Reward received : ", formatEther(crvReward0));
        console.log("CVX Reward received : ", formatEther(cvxReward0));
        expect(parseFloat(crvReward0.toString())).to.be.within(rewards0[0].toNumber() * 0.99, rewards0[0].toNumber() * 1.01);
        expect(parseFloat(cvxReward0.toString())).to.be.within(rewards0[1].toNumber() * 0.99, rewards0[1].toNumber() * 1.01);
    }).timeout(300000);

    it('Should check the events', async () => {
        const amount = parseEther("10000");
        const signer0Address = await signer0.getAddress();

        // Approve tokens
        await daiToken.connect(signer0).approve(convexVault.address, amount);
        console.log("Approved DAI for staking");
        // Deposit tokens && Stake
        // Deposit tokens && Stake
        await expect(convexVault.connect(signer0).deposit(daiToken.address, amount)).to.be.emit(convexVault, "Deposit").withArgs(signer0Address, amount);
        console.log("User 1 : Deposited into convexVault and stake in the BaseRewardPool: ", formatEther(amount));
        // Increaes 1 month
        await time.increase(18000);

        // Get calculated rewards
        const rewards0 = await convexVault.calculateRewardsEarned(signer0Address);
        console.log("CRV Reward calculated : ", formatEther(rewards0[0]));
        console.log("CVX Reward calculated : ", formatEther(rewards0[1]));
        await convexVault.connect(signer0).getVaultRewards();

        const userInfoAfterWithdraw = await convexVault.userInfos(signer0Address);
        await expect(convexVault.connect(signer0).withdraw(userInfoAfterWithdraw.amount.toString(), daiToken.address, false)).to.be.emit(convexVault, "Withdraw").withArgs(signer0Address, userInfoAfterWithdraw.amount);
        // Check if rewards were claimed properly
        // Write assertions based on the specific logic of the `claim` function
    }).timeout(300000);

    it('Should deposit 1 ETH and process deposit', async () => {
        // Should owner able to add ETH as underyling asset
        await convexVault.addUnderlyingAsset(ethers.constants.AddressZero);

        const amount = ethers.utils.parseUnits("1", 18);

        const ethBalanceBeforeDeposit = await ethers.provider.getBalance(signer1.getAddress());
        const lpBalanceBeforeDeposit = await convexVault.totalSupply();

        // Should emit Deposit event with correct args
        // Note: Even use msg.value, use same amount in amount parameter
        expect(await convexVault.connect(signer1).deposit(ethers.constants.AddressZero, amount, { value: amount })).to.be.emit(convexVault, "Deposit").withArgs(signer1.getAddress(), ethers.constants.AddressZero, amount);

        const ethBalanceAfterDeposit = await ethers.provider.getBalance(signer1.getAddress());
        const lpBalanceAfterDeposit = await convexVault.totalSupply();

        // Should ETH balance decrease after deposit (consider gas fee)
        expect(ethBalanceAfterDeposit).to.be.lessThan(ethBalanceBeforeDeposit.sub(amount));

        // Should LP balance increased after deposit
        expect(lpBalanceAfterDeposit).to.be.greaterThan(lpBalanceBeforeDeposit);

        console.log("LP added: ", lpBalanceAfterDeposit.sub(lpBalanceBeforeDeposit));
    }).timeout(300000);

    it('Deposit 100 DAI and withdraw rewards using WETH', async () => {
        const amount = ethers.utils.parseUnits("1", 18);

        const daiBalanceBeforeDeposit = await daiToken.balanceOf(signer0.getAddress());
        const lpBalanceBeforeDeposit = await convexVault.totalSupply();

        await daiToken.connect(signer0).approve(convexVault.address, amount);

        expect(await convexVault.connect(signer0).deposit(daiToken.address, amount)).to.be.emit(convexVault, "Deposit").withArgs(signer0.getAddress(), daiToken.address, amount);

        const daiBalanceAfterDeposit = await daiToken.balanceOf(signer0.getAddress());
        const lpBalanceAfterDeposit = await convexVault.totalSupply();

        expect(daiBalanceAfterDeposit).to.be.eq(daiBalanceBeforeDeposit.sub(amount));
        expect(lpBalanceAfterDeposit).to.be.greaterThan(lpBalanceBeforeDeposit);

        const lpAmountForSigner0 = lpBalanceAfterDeposit.sub(lpBalanceBeforeDeposit);

        await time.increase(18000);

        expect(await convexVault.connect(signer0).withdraw(lpAmountForSigner0, wethToken.address, true)).to.be.emit(convexVault, "Withdraw").withArgs(signer0.getAddress(), lpAmountForSigner0);
    });

    it('Deposit 100 DAI and withdraw rewards using ETH', async () => {
        const amount = ethers.utils.parseUnits("1", 18);

        const daiBalanceBeforeDeposit = await daiToken.balanceOf(signer0.getAddress());
        const lpBalanceBeforeDeposit = await convexVault.totalSupply();

        await daiToken.connect(signer0).approve(convexVault.address, amount);

        expect(await convexVault.connect(signer0).deposit(daiToken.address, amount)).to.be.emit(convexVault, "Deposit").withArgs(signer0.getAddress(), daiToken.address, amount);

        const daiBalanceAfterDeposit = await daiToken.balanceOf(signer0.getAddress());
        const lpBalanceAfterDeposit = await convexVault.totalSupply();

        expect(daiBalanceAfterDeposit).to.be.eq(daiBalanceBeforeDeposit.sub(amount));
        expect(lpBalanceAfterDeposit).to.be.greaterThan(lpBalanceBeforeDeposit);

        const lpAmountForSigner0 = lpBalanceAfterDeposit.sub(lpBalanceBeforeDeposit);

        await time.increase(18000);

        expect(await convexVault.connect(signer0).withdraw(lpAmountForSigner0, ethers.constants.AddressZero, true)).to.be.emit(convexVault, "Withdraw").withArgs(signer0.getAddress(), lpAmountForSigner0);
    });
});
