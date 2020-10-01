# ArbSwapper - Arbitrage with Flash Loans
**Disclaimer**: This uniswap part of this code is based on https://github.com/flashswap/uniswap-flash-trade.

---

The goal of this project is to utilise the concept flashswaps to execute arbitrage opportunities.

A flashswap is a special case of flashloan, where you borrow in one token and pay back in another, all within the same transaction. An example would be to borrow DAI and pay back in ETH at the end of the transaction. If the loan is not paid back, the entire transaction is reverted. In short, we either execute an arbitrage opportunity or we only lose the fee we paid.

For the ArbSwapper, we are using Uniswap flashswaps and swaps on Curve to perform arbitrage in a few simple steps. Note that we are here making it a bit simplified to get a first graps on the method: 

1. Borrow coin A from Uniswap
2. Swap A $$\Rightarrow$$ B on Curve
3. Pay back loan with B 
4. Profit???

In practice, we cannot always do a Flashswap between A and B directly on Uniswap. Sometimes we need to perform a triangular swap, which simply means that we will perform a flashwap for B and WETH and then swap WETH to A, such that we can perform step 2. WETH is simply wrapped ether, and most pairs on Uniswap have higher liquidity on this pair than directly between two tokens.

An example of a execution flow can be seen below. 



```sequence
owner->contract: Create
user->contract: Perform arb DAI, USDC, 1K
contract->uniswap: FlashSwap, USDC -> DAI
uniswap->contract: Ok, here is 1K DAI
contract->curve: Swap 1K DAI for USDC
curve->contract: >1k USDC
contract->uniswap: Pay back loan with USDC
contract->owner: Profit
```



Hence we are using Uniswap and Curve, we will only have pairs that are on both. We are using the sUSD pool on curve, meaning that we will support DAI, USDC, USDT and sUSD. 

To minimize the possiblity of human error, the arbitrage is executed using the function:

```
flashSwap(bool _tri, int128 _borrow, int128 _pay, uint256 _borrowAmount, address payable _profiteer)
```

In this function, `_tri` simply tells the swapper if it is a triangular trade, i.e., `_pay` $$\Rightarrow$$ WETH $$\Rightarrow$$ `_borrow`, or just going directly `_pay` $$\Rightarrow$$ `_borrow`. 

Both `_borrow` and `_pay` will be indexes in the sUSD pool on curve, meaning that 0 is DAI, 1 USDC, 2 USDT and 3 sUSD.  The `_borrowAmount` is then to be specified following the number of decimals for the `_borrow` token. 

The `_profiteer` is the one who should receive the profit. 

* **DAI**: index 0 in curve, 18 decimals at `0x6B175474E89094C44Da98b954EedeAC495271d0F`
* **USDC**: index 1 in curve, 6 decimals at `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`
* **USDT**: index 2 in curve, 6 decimals at `0xdAC17F958D2ee523a2206206994597C13D831ec7`
* **sUSD**: index 3 in curve, 18 decimals at `0x57Ab1ec28D129707052df4dF418D58a2D46d5f51`

Hence it is very important that we get the transaction executed quickly to use the opportunity, we support giving a deadline (last block) in which the transaction is valid. The function is quite similar, with a small difference:

```
flashSwapDeadline(bool _tri, int128 _borrow, int128 _pay, uint256 _borrowAmount, address payable _profiteer, uint256 _deadline) 
```

where `_deadline` simply is the last block where the trade should be executed. This is useful to minimize the gas spend if the transaction is included in a block too late to assume that we can actually use the opportunity. In larger trades, we suggest that this is `current+1`, simply stating that the transactions shall revert if not included in the next block.

The actual arbitrage part of the contract is ver small, and simply performs an approval and trade on curve between the `_borrow` and `_pay` tokens. A snippet is seen here, but the rest is visible in `CurveArb.sol`.

```
// Performing arbitrage using curve
function execute(address _tokenBorrow, uint _amount, address _tokenPay, uint _amountToRepay, bytes memory _userData) internal override {
    (int128 _i, int128 _j) = abi.decode(_userData, (int128, int128));

    // Step 1. Approve _tokenBorrow for amount to Curve.
    tokenApprove(_tokenBorrow, 0xA5407eAE9Ba41422680e2e00537571bcC53efBfD, _amount);

    // Step 2. Exchange at curve with no lower limit on return. If return < _amountToRepay the trade will fail anyway
    curveFiTrader.exchange_underlying(_i, _j, _amount, 0);
}
```

## For builders

For anyone interested in building their own Swapper with other exchanges or AMMs than curve and uniswap, please note that the tokenTransfer function is used to ensure that USDT can be transferred hence it is not following the current ERC20 specification, meaning that the function signature is different. Be aware of this when you build. 

Otherwise, simply build something that looks a bit like `CurveArb` but with your own `execute`.

## Testing

To test the contract without requiring an arbitrage opportunity we will transfer some of the payback token to the contract, such that it can pay back the loan, even when the trade is losing money. Further, we extra the funds to another account that the caller.

We test the following cases:

* Direct swaps

  * DAI $$\Rightarrow$$ USDC
  * DAI $$\Rightarrow$$ USDT
  * USDC $$\Rightarrow$$ DAI
  * USDC $$\Rightarrow$$ USDT
  * USDT $$\Rightarrow$$ DAI
  * USDT $$\Rightarrow$$ USDC

* Triangular swaps

  * DAI $$\Rightarrow$$ WETH $$\Rightarrow$$ USDC
  * DAI $$\Rightarrow$$ WETH $$\Rightarrow$$ USDT
  * DAI $$\Rightarrow$$ WETH $$\Rightarrow$$ sUSD
  * USDC $$\Rightarrow$$ WETH $$\Rightarrow$$ DAI
  * USDC $$\Rightarrow$$ WETH $$\Rightarrow$$ USDT
  * USDC $$\Rightarrow$$ WETH $$\Rightarrow$$ sUSD
  * USDT $$\Rightarrow$$ WETH $$\Rightarrow$$ DAI
  * USDT $$\Rightarrow$$ WETH $$\Rightarrow$$ USDC
  * USDT $$\Rightarrow$$ WETH $$\Rightarrow$$ sUSD
  * sUSD $$\Rightarrow$$ WETH $$\Rightarrow$$ DAI
  * sUSD $$\Rightarrow$$ WETH $$\Rightarrow$$ USDC
  * sUSD $$\Rightarrow$$ WETH $$\Rightarrow$$ USDT


# Be aware of the mempool monsters

While this contract is capable of performing arbitrage trades, the transaction needs to be first to take advantage of the trade. This is a huge issue, hence the mempool is full of predators just waiting for easy pray (thats your transaction). 

There is a number of articles that is way better at talking about this than I, some of them are here:

https://medium.com/@danrobinson/ethereum-is-a-dark-forest-ecc5f0505dff

https://samczsun.com/escaping-the-dark-forest/

To use the arbitrage contract, I build a bot that looked for opportunities and executed them in the next block, however, I was consistently frontrun by https://etherscan.io/address/0xe33c8e3a0d14a81f0dd7e174830089e82f65fc85 - and it seems like I was not the only one. If you wish to do arbitrage on Ethereum with uniswap and curve you are playing against the pros.