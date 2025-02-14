const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");
const {address} = require("hardhat/internal/core/config/config-validation");

describe("OIK", function () {
  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployOIKFixture() {
    const MAX_SUPPLY = 1_000_000_000;
    const NAME = "OIK";
    const SYMBOL = "OIK";
    const DECIMALS = 6;

    // Contracts are deployed using the first signer/account by default
    const [owner, otherAccount] = await ethers.getSigners();

    const Oik = await ethers.getContractFactory("OIK");
    const oik = await Oik.deploy(NAME,SYMBOL, MAX_SUPPLY,DECIMALS);

    return { oik, NAME, SYMBOL, MAX_SUPPLY, DECIMALS, owner, otherAccount };
  }

  describe("Deployment", function () {
    it("Should set the right name", async function () {
      const { oik, NAME } = await loadFixture(deployOIKFixture);

      expect(await oik.name()).to.equal(NAME);
    });

    it("Should set the right symbol", async function () {
      const { oik, SYMBOL } = await loadFixture(deployOIKFixture);

      expect(await oik.symbol()).to.equal(SYMBOL);
    });

    it("Should set the right owner", async function () {
      const { oik, owner } = await loadFixture(deployOIKFixture);

      expect(await oik.owner()).to.equal(owner);
    });

    it("Should set the right decimals", async function () {
      const { oik, DECIMALS } = await loadFixture(deployOIKFixture);

      expect(await oik.decimals()).to.equal(DECIMALS);
    });

    it("Should set the right max_supply", async function () {
      const { oik, MAX_SUPPLY  } = await loadFixture(deployOIKFixture);

      expect(await oik.MAX_SUPPLY()).to.equal(MAX_SUPPLY);
    });
  });

  describe("Operations", function () {
    describe("Auth-Mint", function () {
      it("Should revert with the right error if mint too much", async function () {
        const { oik,MAX_SUPPLY } = await loadFixture(deployOIKFixture);
        const accounts = await ethers.getSigners();
        const receiver = accounts[1];
        await expect(oik.mint(receiver,MAX_SUPPLY+1)).to.be.revertedWith(
          "EXCEED_MAX_SUPPLY"
        );
      });
    });

    describe("No-AuthMint", function () {
      it("Should revert with the right error if the others mint", async function () {
        const { oik,MAX_SUPPLY } = await loadFixture(deployOIKFixture);
        const accounts = await ethers.getSigners();
        const receiver = accounts[1];
        await expect(oik.connect(accounts[1]).mint(receiver,MAX_SUPPLY)).to.be.revertedWith(
            "Ownable: caller is not the owner"
        );
      });
    });

    describe("Burn", function () {
      it("Should burn some tokens", async function () {
        const { oik,MAX_SUPPLY  } = await loadFixture(deployOIKFixture);
        const accounts = await ethers.getSigners();
        const receiver = accounts[1];
        await oik.mint(receiver,MAX_SUPPLY);
        expect(await oik.balanceOf(receiver)).to.equal(MAX_SUPPLY);
        const BURN_AMOUNT = 20;
        await oik.connect(accounts[1]).burn(BURN_AMOUNT);
        expect(await oik.balanceOf(receiver)).to.equal(MAX_SUPPLY-BURN_AMOUNT);
      });
    });

    describe("Burn", function () {
      it("Should revert with the right error if burn the others' tokens", async function () {
        const { oik,MAX_SUPPLY } = await loadFixture(deployOIKFixture);
        const accounts = await ethers.getSigners();
        const receiver = accounts[1];
        const BURN_AMOUNT = 20;
        await oik.mint(receiver,MAX_SUPPLY);
        expect(await oik.balanceOf(receiver)).to.equal(MAX_SUPPLY);
        await expect(oik.connect(accounts[0]).burn(BURN_AMOUNT)).to.be.revertedWith(
            "ERC20: burn amount exceeds balance"
        );
      });
    });

    describe("Mint-after-Burn", function () {
      it("Should mint the same token with burnt amount", async function () {
        const { oik,MAX_SUPPLY  } = await loadFixture(deployOIKFixture);
        const accounts = await ethers.getSigners();
        const receiver = accounts[1];
        await oik.mint(receiver,MAX_SUPPLY);
        expect(await oik.balanceOf(receiver)).to.equal(MAX_SUPPLY);
        const BURN_AMOUNT = 20;
        await oik.connect(accounts[1]).burn(BURN_AMOUNT);
        expect(await oik.balanceOf(receiver)).to.equal(MAX_SUPPLY-BURN_AMOUNT);
        await oik.mint(receiver,BURN_AMOUNT);
        expect(await oik.balanceOf(receiver)).to.equal(MAX_SUPPLY);
      });
    });

    describe("Mint-after-Burn", function () {
      it("Should revert with the right error if mint too much", async function () {
        const { oik,MAX_SUPPLY  } = await loadFixture(deployOIKFixture);
        const accounts = await ethers.getSigners();
        const receiver = accounts[1];
        await oik.mint(receiver,MAX_SUPPLY);
        expect(await oik.balanceOf(receiver)).to.equal(MAX_SUPPLY);
        const BURN_AMOUNT = 20;
        await oik.connect(accounts[1]).burn(BURN_AMOUNT);
        expect(await oik.balanceOf(receiver)).to.equal(MAX_SUPPLY-BURN_AMOUNT);
        await expect(oik.mint(accounts[1],BURN_AMOUNT+1)).to.be.revertedWith(
            "EXCEED_MAX_SUPPLY"
        );
      });
    });

  });
});
