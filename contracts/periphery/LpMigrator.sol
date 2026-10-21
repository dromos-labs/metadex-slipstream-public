// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import {ERC721Holder} from '@openzeppelin/contracts/token/ERC721/ERC721Holder.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import {ICLPool} from '../core/interfaces/ICLPool.sol';
import {ILpMigrator} from './interfaces/ILpMigrator.sol';
import {INonfungiblePositionManager} from './interfaces/INonfungiblePositionManager.sol';

import {PoolAddress} from './libraries/PoolAddress.sol';
import {TransferHelper} from './libraries/TransferHelper.sol';

contract LpMigrator is ILpMigrator, ERC721Holder, ReentrancyGuard {
  using SafeERC20 for IERC20;

  receive() external payable {}

  /// @inheritdoc ILpMigrator
  function migrateSlipstreamToSlipstream(
    FromParams memory fromParams,
    ToParams memory toParams
  ) external override nonReentrant returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
    INonfungiblePositionManager fromNFT = INonfungiblePositionManager(fromParams.nft);

    // collect all tokens from existing positions
    address token0;
    address token1;
    int24 tickSpacing;

    (,, token0, token1, tickSpacing,,, liquidity,,,,) = fromNFT.positions(fromParams.tokenId);

    fromNFT.safeTransferFrom(msg.sender, address(this), fromParams.tokenId);

    fromNFT.decreaseLiquidity(
      INonfungiblePositionManager.DecreaseLiquidityParams({
        tokenId: fromParams.tokenId,
        liquidity: liquidity,
        amount0Min: fromParams.amount0Min,
        amount1Min: fromParams.amount1Min,
        deadline: block.timestamp
      })
    );

    (uint256 amount0Total, uint256 amount1Total) = fromNFT.collect(
      INonfungiblePositionManager.CollectParams({
        tokenId: fromParams.tokenId,
        recipient: address(this),
        amount0Max: type(uint128).max,
        amount1Max: type(uint128).max
      })
    );

    fromNFT.burn(fromParams.tokenId);

    uint160 sqrtPriceX96;
    if (toParams.pool == address(0)) {
      sqrtPriceX96 = getPrice({from: fromNFT, token0: token0, token1: token1, tickSpacing: tickSpacing});
    }

    // fetch additional funds from user
    if (fromParams.amount0Extra > 0) {
      IERC20(token0).safeTransferFrom(msg.sender, address(this), fromParams.amount0Extra);
      amount0Total += fromParams.amount0Extra;
    }
    if (fromParams.amount1Extra > 0) {
      IERC20(token1).safeTransferFrom(msg.sender, address(this), fromParams.amount1Extra);
      amount1Total += fromParams.amount1Extra;
    }

    // limit each token's spend to the caller's cap and available migration funds
    if (toParams.amount0Desired > amount0Total) toParams.amount0Desired = amount0Total;
    if (toParams.amount1Desired > amount1Total) toParams.amount1Desired = amount1Total;

    // approve token transfer to nft
    IERC20(token0).safeApprove(toParams.nft, toParams.amount0Desired);
    IERC20(token1).safeApprove(toParams.nft, toParams.amount1Desired);

    // create new position
    (tokenId, liquidity, amount0, amount1) = INonfungiblePositionManager(toParams.nft)
      .mint(
        INonfungiblePositionManager.MintParams({
          token0: token0,
          token1: token1,
          tickSpacing: toParams.tickSpacing,
          tickLower: toParams.tickLower,
          tickUpper: toParams.tickUpper,
          amount0Desired: toParams.amount0Desired,
          amount1Desired: toParams.amount1Desired,
          amount0Min: toParams.amount0Min,
          amount1Min: toParams.amount1Min,
          recipient: toParams.recipient,
          deadline: toParams.deadline,
          sqrtPriceX96: sqrtPriceX96
        })
      );

    // clear token allowances
    IERC20(token0).safeApprove(toParams.nft, 0);
    IERC20(token1).safeApprove(toParams.nft, 0);

    // refund remaining funds to user
    uint256 residual0 = IERC20(token0).balanceOf(address(this));
    uint256 residual1 = IERC20(token1).balanceOf(address(this));

    if (residual0 > 0) {
      IERC20(token0).safeTransfer(msg.sender, residual0);
    }
    if (residual1 > 0) {
      IERC20(token1).safeTransfer(msg.sender, residual1);
    }

    // refund remaining eth to user
    if (address(this).balance > 0) TransferHelper.safeTransferETH(msg.sender, address(this).balance);

    emit MigratedSlipstreamToSliptream(msg.sender, fromParams.tokenId, tokenId);
  }

  /// @dev Fetches current price of existing pool
  function getPrice(
    INonfungiblePositionManager from,
    address token0,
    address token1,
    int24 tickSpacing
  ) internal view returns (uint160 sqrtPriceX96) {
    ICLPool pool = ICLPool(
      PoolAddress.computeAddress({
        factory: from.factory(), key: PoolAddress.PoolKey({token0: token0, token1: token1, tickSpacing: tickSpacing})
      })
    );

    (sqrtPriceX96,,,,,) = pool.slot0();
  }
}
