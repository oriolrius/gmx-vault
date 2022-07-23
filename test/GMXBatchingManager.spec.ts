import { FakeContract } from '@defi-wonderland/smock';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { parseTokenAmount, slippageToSqrtPriceLimit } from '@ragetrade/sdk';
import { expect } from 'chai';
import { BigNumber } from 'ethers';
import hre, { ethers } from 'hardhat';
import { ERC20, GMXBatchingManager, GmxVaultMock, GMXYieldStrategy } from '../typechain-types';
import addresses from './fixtures/addresses';
import { gmxBatchingManagerFixture } from './fixtures/gmx-batching-manager';
import { unlockWhales } from './utils/curve-helper';
import { increaseBlockTimestamp } from './utils/vault-helpers';

describe('GMX Batching Manager', () => {
  let admin: SignerWithAddress;
  let vault: GmxVaultMock;
  let keeper: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;
  let usdc: ERC20;
  let fsGlp: ERC20;
  let sGlp: ERC20;
  let gmxBatchingManager: GMXBatchingManager;
  before(async () => {
    await gmxBatchingManagerFixture();
  });
  beforeEach(async () => {
    ({ admin, vault, user1,user2,keeper, usdc,fsGlp,sGlp, gmxBatchingManager } = await gmxBatchingManagerFixture());
  });
  describe("Start State", () => {
    it("initialized state", async() =>{
        expect(await gmxBatchingManager.currentRound()).to.eq(1);
        expect(await gmxBatchingManager.keeper()).to.eq(keeper.address);
        expect(await gmxBatchingManager.gmxVault()).to.eq(vault.address);
    })
  })
  describe("deposit", () => {
    it("Single Deposit", async() => {
        const depositAmount = parseTokenAmount(100n,6);

        await expect(() => gmxBatchingManager.connect(user1).depositToken(usdc.address,depositAmount,user1.address))
        .to.changeTokenBalance(usdc,user1,depositAmount.mul(-1n));

        const user1Deposit = await gmxBatchingManager.userDeposits(user1.address);
        // console.log(user1Deposit);
        expect(user1Deposit.round).to.eq(1);
        expect(user1Deposit.glpBalance).to.eq(await fsGlp.balanceOf(gmxBatchingManager.address));
        expect(user1Deposit.unclaimedShares).to.eq(0);

        expect(await gmxBatchingManager.roundGlpBalance()).to.eq(user1Deposit.glpBalance);
        expect(await fsGlp.balanceOf(gmxBatchingManager.address)).to.eq(user1Deposit.glpBalance);

    });
  })

  describe("Execute Batch Deposit", () => {
    it("Single User Batch Deposit", async() => {

        const depositAmount = parseTokenAmount(100n,6);

        await gmxBatchingManager.connect(user1).depositToken(usdc.address,depositAmount,user1.address);

        await increaseBlockTimestamp(15*60); //15 mins

        const roundGlpBalance = await gmxBatchingManager.roundGlpBalance();
        //Check sGlp transfer and vault share transfer
        await expect(()=>gmxBatchingManager.connect(keeper).executeBatchDeposit())
        .to.changeTokenBalances(fsGlp,[gmxBatchingManager,vault],[roundGlpBalance.mul(-1),roundGlpBalance])

        expect(await vault.balanceOf(gmxBatchingManager.address)).to.eq(roundGlpBalance);

        const user1Deposit = await gmxBatchingManager.userDeposits(user1.address);
        const round1Deposit = await gmxBatchingManager.roundDeposits(1);

        expect(user1Deposit.round).to.eq(1);
        expect(user1Deposit.unclaimedShares).to.eq(0);
        expect(await gmxBatchingManager.currentRound()).to.eq(2);
        expect(await gmxBatchingManager.roundGlpBalance()).to.eq(0);

        expect(round1Deposit.totalGlp).to.eq(round1Deposit.totalGlp);
        expect(round1Deposit.totalShares).to.eq(round1Deposit.totalShares);

    })
  })

  describe("Claim", () => {
    it("Single User Claim", async() => {
        const depositAmount = parseTokenAmount(100n,6);

        await gmxBatchingManager.connect(user1).depositToken(usdc.address,depositAmount,user1.address);

        await increaseBlockTimestamp(15*60); //15 mins

        await gmxBatchingManager.connect(keeper).executeBatchDeposit();

        const roundDeposit = await gmxBatchingManager.roundDeposits(1);

        await expect(() =>gmxBatchingManager.connect(user1).claim(user1.address,roundDeposit.totalShares))
        .to.changeTokenBalances(vault,[gmxBatchingManager,user1],[roundDeposit.totalShares.mul(-1),roundDeposit.totalShares]);
        
        const user1Deposit = await gmxBatchingManager.userDeposits(user1.address);

        expect(user1Deposit.round).to.eq(1);
        expect(user1Deposit.glpBalance).to.eq(0);
        expect(user1Deposit.unclaimedShares).to.eq(0);
    })
  })
});
