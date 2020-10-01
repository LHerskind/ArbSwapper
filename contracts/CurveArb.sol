pragma solidity 0.7.1;

// This code is partially based on https://github.com/flashswap/uniswap-flash-trade.


// This is only used for testing
interface Router02 {
  function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
}


////////////////
// Interfaces //
////////////////
interface IUniswapV2Factory {
  function getPair(address tokenA, address tokenB) external view returns (address pair);
}


interface CurveFi {
  function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
}


interface IUniswapV2Pair {
  function token0() external view returns (address);
  function token1() external view returns (address);
  function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
}


interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}


interface USDTERC20{
    function transfer(address recipient, uint256 amount) external;
    function approve(address spender, uint256 amount) external;
}


interface IWETH {
    function withdraw(uint) external;
    function deposit() external payable;
}


abstract contract UniswapFlashSwapper {

    enum SwapType {Direct, Triangular}

    IUniswapV2Factory constant uniswapV2Factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant ETH = address(0);

    address permissionedPairAddress = address(1);

    receive() external payable {}
    fallback() external {}

    //
    function startSwap(bool _tri, address _tokenBorrow, uint256 _amount, address _tokenPay, bytes memory _userData) internal {        
        if (_tri){
            traingularFlashSwap(_tokenBorrow, _amount, _tokenPay, _userData);
            return;            
        } else {
            simpleFlashSwap(_tokenBorrow, _amount, _tokenPay, _userData);
            return;
        }
    }    

     // @notice Function is called by the Uniswap V2 pair's `swap` function 
    function uniswapV2Call(address _sender, uint _amount0, uint _amount1, bytes calldata _data) external {
        require(_sender == address(this), "only this contract may initiate");
        require(msg.sender == permissionedPairAddress, "only permissioned UniswapV2 pair can call");

        (   SwapType _swapType,
            address _tokenBorrow,
            uint _amount,
            address _tokenPay,
            bytes memory _triangleData,
            bytes memory _userData
        ) = abi.decode(_data, (SwapType, address, uint, address, bytes, bytes));

        if (_swapType == SwapType.Direct) {
            simpleFlashSwapExecute(_tokenBorrow, _amount, _tokenPay, msg.sender, _userData);
            return;
        } else {
            traingularFlashSwapExecute(_tokenBorrow, _amount, _tokenPay, _triangleData, _userData);
            return;
        }
    }
    
    function simpleFlashSwap(
        address _tokenBorrow,
        uint _amount,
        address _tokenPay,
        bytes memory _userData
    ) private {
        permissionedPairAddress = uniswapV2Factory.getPair(_tokenBorrow, _tokenPay);
        address pairAddress = permissionedPairAddress; // gas efficiency
        require(pairAddress != address(0), "Requested pair is not available.");
        address token0 = IUniswapV2Pair(pairAddress).token0();
        address token1 = IUniswapV2Pair(pairAddress).token1();
        uint amount0Out = _tokenBorrow == token0 ? _amount : 0;
        uint amount1Out = _tokenBorrow == token1 ? _amount : 0;
        bytes memory data = abi.encode(
            SwapType.Direct,
            _tokenBorrow,
            _amount,
            _tokenPay,
            bytes(""),
            _userData
        );
        IUniswapV2Pair(pairAddress).swap(amount0Out, amount1Out, address(this), data);
    }

    // @notice This is the code that is executed after `simpleFlashSwap` initiated the flash-borrow
    // @dev When this code executes, this contract will hold the flash-borrowed _amount of _tokenBorrow
    function simpleFlashSwapExecute(
        address _tokenBorrow,
        uint _amount,
        address _tokenPay,
        address _pairAddress,
        bytes memory _userData
    ) private {
        address pairAddress = permissionedPairAddress;
        uint pairBalanceTokenBorrow = IERC20(_tokenBorrow).balanceOf(pairAddress);
        uint pairBalanceTokenPay = IERC20(_tokenPay).balanceOf(pairAddress);
        uint amountToRepay = ((1000 * pairBalanceTokenPay * _amount) / (997 * pairBalanceTokenBorrow)) + 1;

        // do whatever the user wants
        execute(_tokenBorrow, _amount, _tokenPay, amountToRepay, _userData);

        tokenTransfer(_tokenPay, _pairAddress, amountToRepay);
    }

    function traingularFlashSwap(address _tokenBorrow, uint _amount, address _tokenPay, bytes memory _userData) private {
        address borrowPairAddress = uniswapV2Factory.getPair(_tokenBorrow, WETH); // is it cheaper to compute this locally?
        require(borrowPairAddress != address(0), "Requested borrow token is not available.");

        permissionedPairAddress = uniswapV2Factory.getPair(_tokenPay, WETH); // is it cheaper to compute this locally?
        address payPairAddress = permissionedPairAddress; // gas efficiency
        require(payPairAddress != address(0), "Requested pay token is not available.");

        // STEP 1: Compute how much WETH will be needed to get _amount of _tokenBorrow out of the _tokenBorrow/WETH pool
        uint pairBalanceTokenBorrowBefore = IERC20(_tokenBorrow).balanceOf(borrowPairAddress);

        require(pairBalanceTokenBorrowBefore >= _amount, "_amount is too big");
        uint pairBalanceTokenBorrowAfter = pairBalanceTokenBorrowBefore - _amount;
        uint pairBalanceWeth = IERC20(WETH).balanceOf(borrowPairAddress);
        uint amountOfWeth = ((1000 * pairBalanceWeth * _amount) / (997 * pairBalanceTokenBorrowAfter)) + 1;

        // using a helper function here to avoid "stack too deep" :(
        traingularFlashSwapHelper(_tokenBorrow, _amount, _tokenPay, borrowPairAddress, payPairAddress, amountOfWeth, _userData);
    }

    // @notice Helper function for `traingularFlashSwap` to avoid `stack too deep` errors
    function traingularFlashSwapHelper(
        address _tokenBorrow,
        uint _amount,
        address _tokenPay,
        address _borrowPairAddress,
        address _payPairAddress,
        uint _amountOfWeth,
        bytes memory _userData
    ) private returns (uint) {
        // Step 2: Flash-borrow _amountOfWeth WETH from the _tokenPay/WETH pool
        address token0 = IUniswapV2Pair(_payPairAddress).token0();
        address token1 = IUniswapV2Pair(_payPairAddress).token1();
        uint amount0Out = WETH == token0 ? _amountOfWeth : 0;
        uint amount1Out = WETH == token1 ? _amountOfWeth : 0;
        bytes memory triangleData = abi.encode(_borrowPairAddress, _amountOfWeth);
        bytes memory data = abi.encode(SwapType.Triangular, _tokenBorrow, _amount, _tokenPay, triangleData, _userData);
        // initiate the flash swap from UniswapV2
        IUniswapV2Pair(_payPairAddress).swap(amount0Out, amount1Out, address(this), data); // Swap from _payToken -> Weth
    }

    // @notice This is the code that is executed after `traingularFlashSwap` initiated the flash-borrow
    // @dev When this code executes, this contract will hold the amount of WETH we need in order to get _amount
    //     _tokenBorrow from the _tokenBorrow/WETH pair.
    function traingularFlashSwapExecute(
        address _tokenBorrow,
        uint _amount,
        address _tokenPay,
        bytes memory _triangleData,
        bytes memory _userData
    ) private {
        // decode _triangleData
        (address _borrowPairAddress, uint _amountOfWeth) = abi.decode(_triangleData, (address, uint));

        // Step 3: Using a normal swap, trade that WETH for _tokenBorrow
        address token0 = IUniswapV2Pair(_borrowPairAddress).token0();
        address token1 = IUniswapV2Pair(_borrowPairAddress).token1();
        uint amount0Out = _tokenBorrow == token0 ? _amount : 0;
        uint amount1Out = _tokenBorrow == token1 ? _amount : 0;
        IERC20(WETH).transfer(_borrowPairAddress, _amountOfWeth); // send our flash-borrowed WETH to the pair
        IUniswapV2Pair(_borrowPairAddress).swap(amount0Out, amount1Out, address(this), bytes("")); // Swap from WETH -> _borrow

        // compute the amount of _tokenPay that needs to be repaid
        address payPairAddress = permissionedPairAddress; // gas efficiency
        uint pairBalanceWETH = IERC20(WETH).balanceOf(payPairAddress);
        uint pairBalanceTokenPay = IERC20(_tokenPay).balanceOf(payPairAddress);
        uint amountToRepay = ((1000 * pairBalanceTokenPay * _amountOfWeth) / (997 * pairBalanceWETH)) + 1;

        // Step 4: Do whatever the user wants (arb, liqudiation, etc)
        execute(_tokenBorrow, _amount, _tokenPay, amountToRepay, _userData);

        // Step 5: Pay back the flash-borrow to the _tokenPay/WETH pool
        tokenTransfer(_tokenPay, payPairAddress, amountToRepay);
    }

    // @notice: Arbritrage operation to be implemented in inheriting 
    function execute(address _tokenBorrow, uint _amount, address _tokenPay, uint _amountToRepay, bytes memory _userData) virtual internal;

    // @notice Wrapper for approving tokens to support USDT which do not follow the ERC20 signature
    function tokenApprove(address _tokenAddress, address _to, uint256 _amount) internal {
        if (_tokenAddress == USDT){
            USDTERC20(_tokenAddress).approve(_to, _amount);
        } else {
            IERC20(_tokenAddress).approve(_to, _amount);
        }
    }

    // @notice Wrapper for transferring tokens to support USDT which do not follow the ERC20 signature
    function tokenTransfer(address _tokenAddress, address _to, uint256 _amount) internal {
        if (_tokenAddress == USDT){
            USDTERC20(_tokenAddress).transfer(_to, _amount);
        } else {
            IERC20(_tokenAddress).transfer(_to, _amount);
        }
    } 
}


contract CurveArb is UniswapFlashSwapper {

    CurveFi constant curveFiTrader = CurveFi(0xA5407eAE9Ba41422680e2e00537571bcC53efBfD);
    address[] curveCoins = [0x6B175474E89094C44Da98b954EedeAC495271d0F, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0xdAC17F958D2ee523a2206206994597C13D831ec7, 0x57Ab1ec28D129707052df4dF418D58a2D46d5f51];

    constructor() {
    }

    // Initiate the flashswap with the restriction that it must be executed before the deadline.
    function flashSwapDeadline(bool _tri, int128 _borrow, int128 _pay, uint256 _borrowAmount, address payable _profiteer, uint256 _deadline) external {        
        require(block.number <= _deadline, "Deadline exceeded");
        address tokenPay = curveCoins[uint(_pay)];
        address tokenBorrow = curveCoins[uint(_borrow)];
        bytes memory _userData = abi.encode(_borrow, _pay); // We swap _borrow -> _pay on curve.
        // Start the flash swap. Will aquire _amount of _tokenBorrow, and run execute defined below, before paying back loan 
        startSwap(_tri, tokenBorrow, _borrowAmount, tokenPay, _userData);
        // When the flash-loan is executed. We extract the profit.
        extractFunds(tokenPay, _profiteer);
    }

    // Plain flashswap
    function flashSwap(bool _tri, int128 _borrow, int128 _pay, uint256 _borrowAmount, address payable _profiteer) external {        
        address tokenPay = curveCoins[uint(_pay)];
        address tokenBorrow = curveCoins[uint(_borrow)];
        bytes memory _userData = abi.encode(_borrow, _pay); // We swap _borrow -> _pay on curve.
        // Start the flash swap. Will aquire _amount of _tokenBorrow, and run execute defined below, before paying back loan 
        startSwap(_tri, tokenBorrow, _borrowAmount, tokenPay, _userData);
        // When the flash-loan is executed. We extract the profit.
        extractFunds(tokenPay, _profiteer);
    }
    
    // Extracts the funds from the smart contract
    function extractFunds(address _token, address payable _to) public{
        uint balance = getBalanceOf(_token);        
        if (_token == address(0)){
            _to.transfer(balance);
        } else {
            tokenTransfer(_token, _to, balance);
        }
    }

    function getBalanceOf(address _input) public view returns (uint) {
        if (_input == address(0)) {
            return address(this).balance;
        }
        return IERC20(_input).balanceOf(address(this));
    }

    // Performing arbitrage using curve
    function execute(address _tokenBorrow, uint _amount, address _tokenPay, uint _amountToRepay, bytes memory _userData) internal override {
        (int128 _i, int128 _j) = abi.decode(_userData, (int128, int128));

        // Step 1. Approve _tokenBorrow for amount to Curve.
        tokenApprove(_tokenBorrow, 0xA5407eAE9Ba41422680e2e00537571bcC53efBfD, _amount);

        // Step 2. Exchange at curve with no lower limit on return. If return < _amountToRepay the trade will fail anyway
        curveFiTrader.exchange_underlying(_i, _j, _amount, 0);
    }
    
}
