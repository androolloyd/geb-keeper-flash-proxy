pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-weth/weth9.sol";
import "ds-token/token.sol";

import {GebDeployTestBase} from "geb-deploy/test/GebDeploy.t.base.sol";
import {FixedDiscountCollateralAuctionHouse} from "geb/CollateralAuctionHouse.sol";
import {CollateralJoin3, CollateralJoin4} from "geb-deploy/AdvancedTokenAdapters.sol";
import {DSValue} from "ds-value/value.sol";
import {GebSafeManager} from "geb-safe-manager/GebSafeManager.sol";
import {GetSafes} from "geb-safe-manager/GetSafes.sol";
import {GebProxyIncentivesActions} from "geb-proxy-actions/GebProxyActions.sol";

import "./uni/UniswapV2Factory.sol";
import "./uni/UniswapV2Pair.sol";
import "./uni/UniswapV2Router02.sol";

import "./GebMultiCollateralKeeperFlashProxy.sol";

contract GebMCKeeperFlashProxyTest is GebDeployTestBase, GebProxyIncentivesActions {
    GebSafeManager manager;
    GebMultiCollateralKeeperFlashProxy keeperProxy;
    
    UniswapV2Factory uniswapFactory;
    UniswapV2Router02 uniswapRouter;
    UniswapV2Pair raiETHPair;
    uint256 initETHRAIPairLiquidity = 5 ether;               // 1250 USD
    uint256 initRAIETHPairLiquidity = 294.672324375E18;      // 1 RAI = 4.242 USD

    bytes32 collateralAuctionType = bytes32("FIXED_DISCOUNT");

    function setUp() override public {
        super.setUp();
        deployIndexWithCreatorPermissions(collateralAuctionType);
        safeEngine.modifyParameters("ETH", "debtCeiling", uint(0) - 1); // unlimited debt ceiling, enough liquidity is needed on Uniswap.
        safeEngine.modifyParameters("globalDebtCeiling", uint(0) - 1); // unlimited globalDebtCeiling

        manager = new GebSafeManager(address(safeEngine));

        // Setup Uniswap
        uniswapFactory = new UniswapV2Factory(address(this));
        raiETHPair = UniswapV2Pair(uniswapFactory.createPair(address(weth), address(coin)));
        uniswapRouter = new UniswapV2Router02(address(uniswapFactory), address(weth));

        // Add pair liquidity
        weth.approve(address(uniswapRouter), uint(-1));
        weth.deposit{value: initETHRAIPairLiquidity}();
        coin.approve(address(uniswapRouter), uint(-1));
        uint safe = this.openSAFE(address(manager), "ETH", address(this));
        _lockETH(address(manager), address(ethJoin), safe, 2000 ether);
        _generateDebt(address(manager), address(taxCollector), address(coinJoin), safe, 100000 ether, address(this));
        uniswapRouter.addLiquidity(address(weth), address(coin), initETHRAIPairLiquidity, 100000 ether, 1000 ether, initRAIETHPairLiquidity, address(this), now);

        // zeroing balances
        coin.transfer(address(0), coin.balanceOf(address(this)));
        raiETHPair.transfer(address(0), raiETHPair.balanceOf(address(this)));

        // keeper Proxy
        keeperProxy = new GebMultiCollateralKeeperFlashProxy(
            address(weth),
            address(coin),
            address(uniswapFactory),
            address(coinJoin),
            address(liquidationEngine)
        );
    }

    uint[] safes;
    function _collateralAuctionETH(uint numberOfAuctions) internal returns (uint lastBidId) {
        this.modifyParameters(address(liquidationEngine), "ETH", "liquidationQuantity", rad(1000 ether));
        this.modifyParameters(address(liquidationEngine), "ETH", "liquidationPenalty", WAD);

        for (uint i = 0; i < numberOfAuctions; i++) {
            uint safe = manager.openSAFE("ETH", address(this));
            safes.push(safe);

            _lockETH(address(manager), address(ethJoin), safe, 0.1 ether);

            _generateDebt(address(manager), address(taxCollector), address(coinJoin), safe, 20 ether, address(this)); // Maximun COIN generated            
        }

        // Liquidate
        orclETH.updateResult(uint(300 * 10 ** 18 - 1)); // Force liquidation
        oracleRelayer.updateCollateralPrice("ETH");
        for (uint i = 0; i < safes.length; i++) {
            lastBidId = liquidationEngine.liquidateSAFE("ETH", manager.safes(safes[i]));
        }
    }

    function _generateUnsafeSafes(uint numberOfSafes) internal returns (uint lastSafeId) {
        this.modifyParameters(address(liquidationEngine), "ETH", "liquidationQuantity", rad(1000 ether));
        this.modifyParameters(address(liquidationEngine), "ETH", "liquidationPenalty", WAD);

        for (uint i = 0; i < numberOfSafes; i++) {
            lastSafeId = manager.openSAFE("ETH", address(this));
            safes.push(lastSafeId);

            _lockETH(address(manager), address(ethJoin), lastSafeId, 0.1 ether);

            _generateDebt(address(manager), address(taxCollector), address(coinJoin), lastSafeId, 20 ether, address(this)); // Maximun COIN generated            
        }

        // Liquidate
        orclETH.updateResult(uint(300 * 10 ** 18 - 1)); // Force liquidation
        oracleRelayer.updateCollateralPrice("ETH");
    }

    function testSettleETHAuction() public {
        uint auction = _collateralAuctionETH(1);
        uint previousBalance = address(this).balance;
        
        keeperProxy.settleAuction(CollateralJoinLike(address(ethJoin)), auction);
        emit log_named_uint("Profit", address(this).balance - previousBalance);
        assertTrue(previousBalance < address(this).balance); // profit!

        (,,, uint amountToRaise,,,) = ethFixedDiscountCollateralAuctionHouse.bids(auction);
        assertEq(amountToRaise, 0);
    }

    function testFailSettleAuctionTwice() public {
        uint auction = _collateralAuctionETH(1);
        keeperProxy.settleAuction(CollateralJoinLike(address(ethJoin)), auction);
        keeperProxy.settleAuction(CollateralJoinLike(address(ethJoin)), auction);
    }

    function testLiquidateAndSettleETHSAFE() public {
        uint safe = _generateUnsafeSafes(1);
        uint previousBalance = address(this).balance;
        
        uint auction = keeperProxy.liquidateAndSettleSAFE(CollateralJoinLike(address(ethJoin)), manager.safes(safe));
        emit log_named_uint("Profit", address(this).balance - previousBalance);
        assertTrue(previousBalance < address(this).balance); // profit!

        (,,, uint amountToRaise,,,) = ethFixedDiscountCollateralAuctionHouse.bids(auction);
        assertEq(amountToRaise, 0);
    }
}