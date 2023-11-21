import { ethers, network } from "hardhat";
import { Signer } from "ethers";
import { Contract } from "ethers";
import { expect } from "chai";
import { formatEther, parseEther } from "ethers/lib/utils";
import { mine, time } from "@nomicfoundation/hardhat-network-helpers";

describe("ConvexVault Test", function () {
  let convexVault: Contract;
  let lpToken: Contract;
  let signer0: Signer, signer1: Signer;
  let cvxToken: Contract;
  let crvToken: Contract;
  let Booster: Contract;

  beforeEach(async function () {
    const lpTokenAddress = "0xC25a3A3b969415c80451098fa907EC722572917F";
    const crvTokenAddress = "0xD533a949740bb3306d119CC777fa900bA034cd52";
    const cvxTokenAddress = "0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B";

    // Impersonating accounts
    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: ["0x9E51BE7071F086d3A1fD5Dc0016177473619b237"],
    });
    signer0 = await ethers.getSigner("0x9E51BE7071F086d3A1fD5Dc0016177473619b237");

    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: ["0x76182bA866Fc44bffC2A4096B332aC7A799eE3Dc"],
    });
    signer1 = await ethers.getSigner("0x76182bA866Fc44bffC2A4096B332aC7A799eE3Dc");

    // Deploying the contracts
    const Vault = await ethers.getContractFactory("ConvexVault");
    const convexPid = 4;
    convexVault = await Vault.deploy();

    await convexVault.deployed();

    console.log(`ConvexVault deployed to ${convexVault.address}`);

    // Adding pools using administrative function
    await convexVault.addPool(100, lpTokenAddress, convexPid);

    console.log("LP Token Address: ", lpTokenAddress);
    lpToken = await ethers.getContractAt("MockERC20", lpTokenAddress);
    crvToken = await ethers.getContractAt("MockERC20", crvTokenAddress);
    cvxToken = await ethers.getContractAt("MockERC20", cvxTokenAddress);

    Booster = await ethers.getContractAt("IBooster", "0xF403C135812408BFbE8713b5A23a04b3D48AAE31");
    await Booster.connect(signer1).earmarkRewards(convexPid);
  });

  it('Should calculate rewards correctly without vault claim', async () => {
    const pid = 0;
    const amount = parseEther("10");
    const signerAddress = await signer0.getAddress();

    // Approve tokens
    await lpToken.connect(signer0).approve(convexVault.address, amount);
    console.log("Approved LP tokens for staking");
    // Deposit tokens && Stake
    await convexVault.connect(signer0).deposit(pid, amount);
    console.log("Deposited into convexVault and stake in the BaseRewardPool: ", formatEther(amount));

    // Get calculated rewards
    const rewards = await convexVault.calculateRewardsEarned(signerAddress, pid);

    await time.increase(18000);
    await mine();
    // Get updated rewards
    const updatedRewards = await convexVault.calculateRewardsEarned(signerAddress, pid);
    expect(updatedRewards[0]).to.be.not.equal(rewards[0]);
    expect(updatedRewards[1]).to.be.not.equal(rewards[1]);
    console.log("CRV Token Reward: ", formatEther(updatedRewards[0]));
    console.log("CVX Token Reward: ", formatEther(updatedRewards[1]));
    console.log("Confirmed rewards were genereated without getVaultRewards");
  }).timeout(300000);

  it('Should add a new pool', async function () {
    const allocPoint = 100;
    const lpToken = "0x845838DF265Dcd2c412A1Dc9e959c7d08537f8a2";
    await convexVault.addPool(allocPoint, lpToken, 0);

    const poolLength = await convexVault.poolLength();
    expect(poolLength).to.equal(2);

    const poolInfo = await convexVault.poolInfo(1);
    expect(poolInfo.lpToken).to.equal(lpToken);
    expect(poolInfo.allocPoint).to.equal(allocPoint);
  });

  it('Should revert on wrong LP token address', async function () {
    const allocPoint = 100;
    const lpToken = "0x845838DF265Dcd2c412A1Dc9e959c7d08537f8a2";
    await expect(convexVault.addPool(allocPoint, lpToken, 1)).to.be.revertedWith("Wrong Pid for Convex");
  });
});
