// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISovereignALM, ALMLiquidityQuoteInput, ALMLiquidityQuote} from "valantis-core/ALM/interfaces/ISovereignALM.sol";
import {ISovereignPool} from "valantis-core/pools/interfaces/ISovereignPool.sol";

import {Checkpoint} from "./structs/BagelStructs.sol";

contract Bagel is ERC20, ISovereignALM {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    error Bagel_deadlineExpired();
    error Bagel_onlyPool();
    error Bagel_deposit__insufficientTokenDeposited();
    error Bagel_deposit_invalidRecipient();
    error Bagel_deposit__zeroShares();
    error Bagel_withdraw__bothAmountsZero();
    error Bagel_withdraw__insufficientToken0Withdrawn();
    error Bagel_withdraw__insufficientToken1Withdrawn();

    Checkpoint private _lastCheckpoint;

    ISovereignPool public immutable pool;
    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint256 internal constant MINIMUM_LIQUIDITY = 1e3;

    constructor(address _pool) ERC20("Bagel LP", "BLP") {
        pool = ISovereignPool(_pool);
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());
    }

    modifier onlyPool() {
        if (address(pool) != msg.sender) {
            revert Bagel_onlyPool();
        }
        _;
    }

    function getLastCheckpoint()
        external
        view
        returns (uint112, uint112, uint32)
    {
        Checkpoint memory lastCheckpointCache = _lastCheckpoint;
        return (
            lastCheckpointCache.lastReserve0,
            lastCheckpointCache.lastReserve1,
            lastCheckpointCache.lastBlockUpdate
        );
    }

    function deposit(
        uint256 _amount0,
        uint256 _amount1,
        uint256 _minShares,
        uint256 _deadline,
        address _recipient,
        bytes memory _verificationContext
    ) external returns (uint256 shares) {
        _checkDeadline(_deadline);

        if (_recipient == address(0)) revert Bagel_deposit_invalidRecipient();

        uint256 totalSupplyCache = totalSupply();

        if (totalSupplyCache == 0) {
            _mint(address(1), MINIMUM_LIQUIDITY);

            shares = Math.sqrt(_amount0 * _amount1) - MINIMUM_LIQUIDITY;
        } else {
            (uint256 reserve0, uint256 reserve1) = _getReserves();

            // Normal deposits are made using onDepositLiquidityCallback
            uint256 shares0 = Math.mulDiv(_amount0, totalSupplyCache, reserve0);
            uint256 shares1 = Math.mulDiv(_amount1, totalSupplyCache, reserve1);

            if (shares0 < shares1) {
                _amount1 = Math.mulDiv(
                    shares0,
                    totalSupplyCache,
                    reserve1,
                    Math.Rounding.Ceil
                );
                shares = shares0;
            } else {
                _amount0 = Math.mulDiv(
                    shares1,
                    totalSupplyCache,
                    reserve0,
                    Math.Rounding.Ceil
                );
                shares = shares1;
            }
        }

        if (shares < _minShares)
            revert Bagel_deposit__insufficientTokenDeposited();

        if (shares == 0) revert Bagel_deposit__zeroShares();

        _mint(_recipient, shares);

        pool.depositLiquidity(
            _amount0,
            _amount1,
            msg.sender,
            _verificationContext,
            abi.encode(msg.sender)
        );
    }

    function withdraw(
        uint256 _shares,
        uint256 _amount0Min,
        uint256 _amount1Min,
        uint256 _deadline,
        address _recipient,
        bytes memory _verificationContext
    ) external returns (uint256 amount0, uint256 amount1) {
        _checkDeadline(_deadline);

        (uint256 reserve0, uint256 reserve1) = _getReserves();

        uint256 totalSupplyCache = totalSupply();
        amount0 = Math.mulDiv(reserve0, _shares, totalSupplyCache);
        amount1 = Math.mulDiv(reserve1, _shares, totalSupplyCache);

        if (amount0 == 0 && amount1 == 0)
            revert Bagel_withdraw__bothAmountsZero();

        if (amount0 < _amount0Min)
            revert Bagel_withdraw__insufficientToken0Withdrawn();
        if (amount1 < _amount1Min)
            revert Bagel_withdraw__insufficientToken1Withdrawn();

        _burn(msg.sender, _shares);

        pool.withdrawLiquidity(
            amount0,
            amount1,
            msg.sender,
            _recipient,
            _verificationContext
        );
    }

    function getLiquidityQuote(
        ALMLiquidityQuoteInput memory _almLiquidityQuoteInput,
        bytes calldata /*_externalContext*/,
        bytes calldata /*_verifierData*/
    ) external override onlyPool returns (ALMLiquidityQuote memory quote) {
        (uint256 reserve0, uint256 reserve1) = _getReserves();

        Checkpoint memory lastCheckpointCache = _lastCheckpoint;
        uint32 blockNumber = block.number.toUint32();
        if (lastCheckpointCache.lastBlockUpdate != blockNumber) {
            lastCheckpointCache.lastBlockUpdate = blockNumber;
            lastCheckpointCache.lastReserve0 = reserve0.toUint112();
            lastCheckpointCache.lastReserve1 = reserve1.toUint112();
            // Update last checkpoint's state
            _lastCheckpoint = lastCheckpointCache;
        }

        uint256 reserveIn;
        uint256 reserveOut;
        if (_almLiquidityQuoteInput.isZeroToOne) {
            if (
                reserve1 * lastCheckpointCache.lastReserve0 >
                lastCheckpointCache.lastReserve1 * reserve0
            ) {
                // new p > p initial for zero to one swap
                // meaning first part of sandwich transaction happened
                // so take reserves such that current p = p initial
                reserve1 = Math.mulDiv(
                    lastCheckpointCache.lastReserve1,
                    reserve0,
                    lastCheckpointCache.lastReserve0
                );
            }

            reserveIn = reserve0;
            reserveOut = reserve1;
        } else {
            if (
                reserve1 * lastCheckpointCache.lastReserve0 <
                reserve0 * lastCheckpointCache.lastReserve1
            ) {
                // new p < p initial for one to zero swap
                // meaning first part of sandwich transaction happened
                // so take reserves such that current p = p initial
                reserve0 = Math.mulDiv(
                    lastCheckpointCache.lastReserve0,
                    reserve1,
                    lastCheckpointCache.lastReserve1
                );
            }

            reserveIn = reserve1;
            reserveOut = reserve0;
        }

        quote.amountInFilled = _almLiquidityQuoteInput.amountInMinusFee;
        quote.amountOut = Math.mulDiv(
            reserveOut,
            _almLiquidityQuoteInput.amountInMinusFee,
            reserveIn + _almLiquidityQuoteInput.amountInMinusFee
        );
    }

    function onDepositLiquidityCallback(
        uint256 _amount0,
        uint256 _amount1,
        bytes memory _data
    ) external override onlyPool {
        address user = abi.decode(_data, (address));

        if (_amount0 > 0) {
            token0.safeTransferFrom(user, msg.sender, _amount0);
        }

        if (_amount1 > 0) {
            token1.safeTransferFrom(user, msg.sender, _amount1);
        }
    }

    function onSwapCallback(
        bool /*_isZeroToOne*/,
        uint256 /*_amountIn*/,
        uint256 /*_amountOut*/
    ) external override {}

    function _getReserves() private view returns (uint256, uint256) {
        return pool.getReserves();
    }

    function _checkDeadline(uint256 _deadline) private view {
        if (block.timestamp > _deadline) {
            revert Bagel_deadlineExpired();
        }
    }
}
