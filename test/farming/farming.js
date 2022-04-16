const { expect } = require("chai");
const { ethers } = require("hardhat");
const { BigNumber } = require('bignumber.js');

describe("Farming", function () {
    let [accountA, accountB, accountC, feeRecipient] = []
    let farming;
    let stakingToken;
    let rewardToken;
    const defaultFeeRate = 15
    const defaultFeeDecimal = 1
    const defaultRewardPerSecond = ethers.utils.parseEther("0.04629629629")
    const oneDay = 86400;
    beforeEach(async () => {
        [accountA, accountB, accountC, feeRecipient] = await ethers.getSigners();
        const StakingToken = await ethers.getContractFactory("StakingToken");
        stakingToken = await StakingToken.deploy()
        await stakingToken.deployed();
        await stakingToken.transfer(accountB.address, ethers.utils.parseEther("1000000"))

        const RewardToken = await ethers.getContractFactory("RewardToken");
        rewardToken = await RewardToken.deploy()
        await rewardToken.deployed();

        const Farming = await ethers.getContractFactory("Farming");
        farming = await Farming.deploy(feeRecipient.address, defaultFeeDecimal, defaultFeeRate);
        await farming.deployed();

        await rewardToken.transfer(farming.address, ethers.utils.parseEther("1000000"))

        await stakingToken.connect(accountA).approve(farming.address, ethers.utils.parseEther("1000000"))
        await stakingToken.connect(accountB).approve(farming.address, ethers.utils.parseEther("1000000"))
        
        const blockNum = await ethers.provider.getBlockNumber();
        const block = await ethers.provider.getBlock(blockNum);
        const timestamp = await block.timestamp;
        await farming.setWhitelisters([accountA.address], false);
        await farming.addPool(stakingToken.address, rewardToken.address, defaultRewardPerSecond, timestamp, timestamp + oneDay)
    })
    describe("common", function () {
        it("feeDecimal should return correct value", async function () {
            expect(await farming.feeDecimal()).to.be.equal(defaultFeeDecimal)
        });
        it("feeRate should return correct value", async function () {
            expect(await farming.feeRate()).to.be.equal(defaultFeeRate)
        });
        it("feeRecipient should return correct value", async function () {
            expect(await farming.feeRecipient()).to.be.equal(feeRecipient.address)
        });
    })

    describe("pool", function () {
        it("poolInfo should return correct value", async function () {
            const pool = await farming.getPoolInfo(0);
            expect(pool.stakingToken).to.be.equal(stakingToken.address)
            expect(pool.rewardToken).to.be.equal(rewardToken.address)
            expect(pool.totalAmount).to.be.equal(0)
            expect(pool.rewardPerSecond).to.be.equal(defaultRewardPerSecond)
            expect(pool.isPaused).to.be.equal(false)
        });

        it("addPool should revert if not in whitelist", async function () {
            const timestamp = 1650002158;
            await expect(farming.connect(accountB).addPool(stakingToken.address, rewardToken.address, defaultRewardPerSecond, timestamp, timestamp + oneDay))
            .to.be.revertedWith("Not in the whitelist")
        });

        it("updateRewardPerSecond should revert if not in whitelist", async function () {
            await expect(farming.connect(accountB).updateRewardPerSecond(0, defaultRewardPerSecond))
            .to.be.revertedWith("Not in the whitelist")
        });

        it("addPool should be successfull", async function () {
            const timestamp = 1650002158;
            await farming.connect(accountA).addPool(rewardToken.address, stakingToken.address, defaultRewardPerSecond, timestamp, timestamp + oneDay);
            const pool = await farming.getPoolInfo(1);
            expect(pool.stakingToken).to.be.equal(rewardToken.address)
            expect(pool.rewardToken).to.be.equal(stakingToken.address)
            expect(pool.totalAmount).to.be.equal(0)
            expect(pool.rewardPerSecond).to.be.equal(defaultRewardPerSecond)
            expect(pool.isPaused).to.be.equal(false)
        });

        it("updateRewardPerSecond should be successfull", async function () {
            await farming.updateRewardPerSecond(0, defaultRewardPerSecond);
            const pool = await farming.getPoolInfo(0);
            expect(pool.rewardPerSecond).to.be.equal(defaultRewardPerSecond)
        });
    })
    describe("test case", function () {
        it("Case 1", async function () {
            await farming.connect(accountA).deposit(0, ethers.utils.parseEther("1000"));
            await network.provider.send("evm_increaseTime", [120]);
            await network.provider.send("evm_mine");
            let user = await farming.getUserInfo(0);
            // console.log('accountA', user)

            let pool = await farming.getPoolInfo(0);
            console.log(pool.totalAmount)
            let expectValue = user[0].mul(defaultRewardPerSecond).div(pool.totalAmount).mul(120).add(user[3]);
            console.log('Expect 1: accountA', expectValue.toString())
            expect(user[0]).to.be.equal(ethers.utils.parseEther("1000"));
            expect(user[1]).to.be.equal(expectValue);

            await network.provider.send("evm_increaseTime", [180]);
            await ethers.provider.send("evm_mine", []);
            await farming.connect(accountB).deposit(0, ethers.utils.parseEther("3500"));

            await network.provider.send("evm_increaseTime", [30]);
            await ethers.provider.send("evm_mine", []);

            user = await farming.connect(accountA).getUserInfo(0);
            pool = await farming.getPoolInfo(0);
            expectValue = user[0].mul(defaultRewardPerSecond).div(pool.totalAmount).mul(30).add(user[3]);
            console.log('Expect 2: accountA', expectValue.toString())
            expect(user[0]).to.be.equal(ethers.utils.parseEther("1000"));
            expect(user[1]).to.be.equal(expectValue);

            user = await farming.connect(accountB).getUserInfo(0);
            expect(user[0]).to.be.equal(ethers.utils.parseEther("3500"));
            pool = await farming.getPoolInfo(0);
            expectValue = user[0].mul(defaultRewardPerSecond).div(pool.totalAmount).mul(30).add(user[3]);
            console.log('Expect 3: accountB', expectValue.toString())
            expect(user[1]).to.be.equal(expectValue);

            await network.provider.send("evm_increaseTime", [180]);
            await ethers.provider.send("evm_mine", []);

            await farming.connect(accountA).deposit(0, ethers.utils.parseEther("1300"));

            await network.provider.send("evm_increaseTime", [30]);
            await ethers.provider.send("evm_mine", []);

            user = await farming.connect(accountA).getUserInfo(0);
            pool = await farming.getPoolInfo(0);
            expectValue = user[0].mul(defaultRewardPerSecond).div(pool.totalAmount).mul(30).add(user[3]);
            console.log('Expect 4: accountA', expectValue.toString())
            expect(user[0]).to.be.equal(ethers.utils.parseEther("2300"));
            expect(user[1]).to.be.equal(expectValue);

            user = await farming.connect(accountB).getUserInfo(0);
            pool = await farming.getPoolInfo(0);
            expectValue = user[0].mul(defaultRewardPerSecond).div(pool.totalAmount).mul(30).add(user[3]);
            console.log('Expect 5: accountB', expectValue.toString())
            expect(user[1]).to.be.equal(expectValue);

            await network.provider.send("evm_increaseTime", [180]);
            await ethers.provider.send("evm_mine", []);

            let oldBalance = await rewardToken.balanceOf(accountA.address);
            let tx = await farming.connect(accountA).harvest(0);
            await expect(tx).to.be.emit(farming, "Harvest")
            let newBalance = await rewardToken.balanceOf(accountA.address);
            expect(newBalance.sub(oldBalance)).to.be.equal(ethers.BigNumber.from('19679994587219930510'));

            await network.provider.send("evm_increaseTime", [180]);
            await ethers.provider.send("evm_mine", []);

            oldBalance = await stakingToken.balanceOf(accountA.address);
            tx = await farming.connect(accountA).withdraw(0, ethers.utils.parseEther("2300"));
            await expect(tx).to.be.emit(farming, "Withdraw")
                .withArgs(accountA.address, 0, ethers.utils.parseEther("2300"));
            newBalance = await stakingToken.balanceOf(accountA.address);
            expect(newBalance.sub(oldBalance)).to.be.equal(ethers.utils.parseEther("2300"));
        });
    })
});
