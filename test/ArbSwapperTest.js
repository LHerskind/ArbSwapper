const IWETH = artifacts.require("IWETH");
const IERC20 = artifacts.require("IERC20");
const IUniswapV2Pair = artifacts.require("IUniswapV2Pair");
const Router02 = artifacts.require("Router02");
const CurveArb = artifacts.require("CurveArb");

var BN = web3.utils.BN;



contract("Swapper", accounts => {

	async function swapTest(_borrow, _payBack, _tri, borrow){
		let owner = accounts[0];
		let user = accounts[1];
		let weth_token = await IERC20.at("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
		let weth = await IWETH.at("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
		let router = await Router02.at("0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D");

		let DAI = await IERC20.at("0x6B175474E89094C44Da98b954EedeAC495271d0F");
		let USDC = await IERC20.at("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");
		let USDT = await IERC20.at("0xdAC17F958D2ee523a2206206994597C13D831ec7");
		let sUSD = await IERC20.at("0x57Ab1ec28D129707052df4dF418D58a2D46d5f51")

		let tokens = [DAI, USDC, USDT, sUSD];
		let tokenNames = ["DAI", "USDC", "USDT", "sUSD"];
		let decimals = [1e18, 1e6, 1e6, 1e18]; // Måske skal vi vitterligt have sat en masse 0'er på.
		let zeros = ["000000000000000000", "000000", "000000", "000000000000000000"];

		let swapper = await CurveArb.new();

		// Deposit 1 ether to WETH.
		let amount = web3.utils.toWei("1", "ether");
		await weth.deposit.sendTransaction({"value": amount, from: user});	

		// Approve the pair to transfer money
		await weth_token.approve(router.address, amount, {from: user});

		// Swap WETH to _payBack token
		let block_number = await web3.eth.getBlockNumber();
		let timestamp = await web3.eth.getBlock(block_number);
		timestamp = timestamp["timestamp"] + 6000;
		let path = [weth_token.address, tokens[_payBack].address];
		await router.swapExactTokensForTokens(amount, "0", path, user, timestamp, {from: user})

		// Transfer _payBack token to swapper
		let token_balance = await tokens[_payBack].balanceOf(user);
		await tokens[_payBack].transfer(swapper.address, token_balance, {from: user});

		// Pre-swap balances
		let pre_owner = await tokens[_payBack].balanceOf(owner);
		let pre_payBack = await swapper.getBalanceOf(tokens[_payBack].address);

		assert.equal(pre_payBack.valueOf() > 0, true, "Contract is empty");

		// We want to borrow just a single coin
		let val = borrow + zeros[_borrow]; 
		//let val = new BN((borrow *  decimals[_borrow]));
		let borrow_amount = web3.utils.numberToHex(val);
		let res = await swapper.flashSwap(_tri, _borrow, _payBack, val, owner, {from: user});

		let post_owner = await tokens[_payBack].balanceOf(owner);
		let post_payBack = await swapper.getBalanceOf(tokens[_payBack].address);

		assert.equal(post_owner.valueOf() - pre_owner.valueOf() > 0, true, "Did not earn funds");
		assert.equal(post_payBack.valueOf(), 0, "Contract is not emptied");
	}

	// Direct

	it("Borrow 1000 USDC, pay back DAI. Route: DAI -> USDC", async () => {
		await swapTest(1,0,false, 1000);
	});

	it("Borrow 1000 USDT, pay back DAI. Route: DAI -> USDT", async () => {
		await swapTest(2,0,false, 1000);
	});

	it("Borrow 1000 DAI, pay back USDC. Route: USDC -> DAI", async () => {
		await swapTest(0,1,false, 1000);
	});

	it("Borrow 1000 USDT, pay back USDC. Route: USDC -> USDT", async () => {
		await swapTest(2,1,false, 1000);
	});

	it("Borrow 1000 DAI, pay back USDT. Route: USDT -> DAI", async () => {
		await swapTest(0,2,false, 1000);
	});

	it("Borrow 1000 USDC, pay back USDT. Route: USDT -> USDC", async () => {
		await swapTest(1,2,false, 1000);
	});

	// Triangular

	it("Borrow 1000 USDC, pay back DAI. Route: DAI -> WETH -> USDC", async () => {
		await swapTest(1,0,true, 1000);
	});

	it("Borrow 1000 USDT, pay back DAI. Route: DAI -> WETH -> USDT", async () => {
		await swapTest(2,0,true, 1000);
	});

	it("Borrow 1000 sUSD, pay back DAI. Route: DAI -> WETH -> sUSD", async () => {
		await swapTest(3,0,true, 1000);
	});

	it("Borrow 1000 DAI, pay back USDC. Route: USDC -> WETH -> DAI", async () => {
		await swapTest(0,1,true, 1000);
	});

	it("Borrow 1000 USDT, pay back USDC. Route: USDC -> WETH -> USDT", async () => {
		await swapTest(2,1,true, 1000);
	});

	it("Borrow 1000 sUSD, pay back USDC. Route: USDC -> WETH -> sUSD", async () => {
		await swapTest(3,1,true, 1000);
	});

	it("Borrow 1000 DAI, pay back USDT. Route: USDT -> WETH -> DAI", async () => {
		await swapTest(0,2,true, 1000);
	});

	it("Borrow 1000 USDC, pay back USDT. Route: USDT -> WETH -> USDC", async () => {
		await swapTest(1,2,true, 1000);
	});

	it("Borrow 1000 sUSD, pay back USDT. Route: USDT -> WETH -> sUSD", async () => {
		await swapTest(3,2,true, 1000);
	});

	it("Borrow 1000 DAI, pay back sUSD. Route: sUSD -> WETH -> DAI", async () => {
		await swapTest(0,3,true, 1000);
	});

	it("Borrow 1000 USDC, pay back sUSD. Route: sUSD -> WETH -> USDC", async () => {
		await swapTest(1,3,true, 1000);
	});

	it("Borrow 1000 USDT, pay back sUSD. Route: sUSD -> WETH -> USDT", async () => {
		await swapTest(2,3,true, 1000);
	});

});