// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MetaNodeToken} from "./MetaNode.sol";
import {TestERC20} from "./TestERC20.sol";
import {MetaNodeStake} from "./MetaNodeStake.sol";

contract MetaNodeStakeTest is Test {
    uint256 START_BLOCK = 100;
    uint256 END_BLOCK = 100000;

    // 事件
    MetaNodeStake private metaNodeStake;
    MetaNodeToken private metaNodeToken;
    TestERC20 private testErc20;

    address private admin = address(0xA11CE);
    address private tokenOwner = address(0xB0B);
    address private user1 = address(0xBEEF);

    event SetMetaNode(IERC20 indexed MetaNode);

    event PauseWithdraw();

    event UnpauseWithdraw();

    event PauseClaim();

    event UnpauseClaim();

    event SetStartBlock(uint256 indexed startBlock);

    event SetEndBlock(uint256 indexed endBlock);

    event SetMetaNodePerBlock(uint256 indexed MetaNodePerBlock);

    event AddPool(
        address indexed stTokenAddress,
        uint256 indexed poolWeight,
        uint256 indexed lastRewardBlock,
        uint256 minDepositAmount,
        uint256 unstakeLockedBlocks
    );

    event UpdatePoolInfo(
        uint256 indexed poolId,
        uint256 indexed minDepositAmount,
        uint256 indexed unstakeLockedBlocks
    );

    event SetPoolWeight(
        uint256 indexed poolId,
        uint256 indexed poolWeight,
        uint256 totalPoolWeight
    );

    event UpdatePool(
        uint256 indexed poolId,
        uint256 indexed lastRewardBlock,
        uint256 totalMetaNode
    );

    event Deposit(address indexed user, uint256 indexed poolId, uint256 amount);

    event RequestUnstake(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount
    );

    event Withdraw(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount,
        uint256 indexed blockNumber
    );

    event Claim(
        address indexed user,
        uint256 indexed poolId,
        uint256 MetaNodeReward
    );

    function setUp() public {
        vm.prank(tokenOwner);
        // 部署ERC20代币合约，铸造100万枚给合约部署者
        testErc20 = new TestERC20("TestERC20Token", "TET", 1000000);

        // 切换到 admin 部署UUPS代理 metaNodeStake
        vm.startPrank(admin);
        // 部署奖励代币合约
        metaNodeToken = new MetaNodeToken();
        MetaNodeStake impl = new MetaNodeStake();

        bytes memory initData = abi.encodeCall(
            MetaNodeStake.initialize,
            (IERC20(metaNodeToken), START_BLOCK, END_BLOCK, 1 ether)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        metaNodeStake = MetaNodeStake(address(proxy));
        vm.stopPrank();

        // user1 账户初始化100枚ETH、100枚token
        deal(user1, 100 ether);
        vm.prank(tokenOwner);
        testErc20.transfer(user1, 100);
    }

    // 验证管理员调用全局暂停提现开关
    function test_setPauseWithdraw() public {
        vm.startPrank(admin);
        // 事件断言 触发PauseWithdraw事件
        vm.expectEmit(false, false, false, false);
        emit PauseWithdraw();
        // 调用暂停提现开关
        metaNodeStake.pauseWithdraw();
        // 验证是否开启暂停提现开关
        assertEq(metaNodeStake.withdrawPaused(), true);

        // 关闭
        vm.expectEmit(false, false, false, false);
        emit UnpauseWithdraw();
        metaNodeStake.unpauseWithdraw();
        assertEq(metaNodeStake.withdrawPaused(), false);
        vm.stopPrank();
    }

    // 验证管理员修改挖矿开始/结束区块
    function test_startAndEndBlock() public {
        // 切换到管理员账户
        vm.startPrank(admin);

        // 验证事件SetStartBlock(_startBlock)触发
        vm.expectEmit(false, false, false, false);
        emit SetStartBlock(100);
        // 调用MetaNodeStake的setStartBlock方法，修改startBlock为100
        metaNodeStake.setStartBlock(100);
        // 验证挖矿开始区块变为了100
        assertEq(metaNodeStake.startBlock(), 100);

        // 验证事件SetEndBlock(_endBlock)触发
        vm.expectEmit(true, false, false, false);
        emit SetEndBlock(200);
        // 调用MetaNodeStake的setEndBlock方法，修改endBlock为200
        metaNodeStake.setEndBlock(200);
        // 验证挖矿结束区块变为了100
        assertEq(metaNodeStake.endBlock(), 200);
        vm.stopPrank();
    }

    // 验证 暂停/开启 领取奖励功能（仅管理员）
    function test_pauseClaimAndUnpauseClaim() public {
        vm.startPrank(admin);

        // 事件断言：PauseClaim
        vm.expectEmit(false, false, false, false);
        emit PauseClaim();
        // 领取奖励功能暂停
        metaNodeStake.pauseClaim();
        assertEq(metaNodeStake.claimPaused(), true);

        // 领取奖励功能开启
        vm.expectEmit(false, false, false, false);
        emit UnpauseClaim();
        metaNodeStake.unpauseClaim();
        assertEq(metaNodeStake.claimPaused(), false);
    }

    // 验证修改每区块发放的MetaNode奖励数
    function test_setMetaNodePerBlock() public {
        vm.startPrank(admin);
        // 事件断言：触发SetMetaNodePerBlock，参数为1
        vm.expectEmit(false, false, false, false);
        emit SetMetaNodePerBlock(1);
        // admin调用setMetaNodePerBlock方法，参数为1
        metaNodeStake.setMetaNodePerBlock(1);
        // 验证
        assertEq(metaNodeStake.MetaNodePerBlock(), 1);
    }

    // 测试添加池子功能
    function test_addPool() public {
        vm.startPrank(admin);

        // 验证0号池不是0x0会触发revert："invalid staking token address"
        vm.expectRevert("invalid staking token address");
        metaNodeStake.addPool(address(testErc20), 1, 10, 2, false);

        // 验证解质押锁定区块数<=0时会触发revert："invalid staking token address"
        vm.expectRevert("invalid withdraw locked blocks");
        metaNodeStake.addPool(address(0x0), 1, 10, 0, false);

        // 验证当前区块高度大于endBlock时触发revert："Already ended"
        metaNodeStake.setEndBlock(200);
        vm.roll(201);
        vm.expectRevert("Already ended");
        metaNodeStake.addPool(address(0x0), 1, 10, 2, false);

        // 验证添加新质押池到数组 并触发AddPool事件
        vm.roll(100);
        vm.expectEmit(false, false, false, false);
        emit AddPool(address(0x0), 1, 100, 10, 2);
        metaNodeStake.addPool(address(0x0), 1, 10, 2, false);
        assertEq(metaNodeStake.poolLength(), 1);

        // 验证第二个池子为0地址触发revert："invalid staking token address"
        vm.expectRevert("invalid staking token address");
        metaNodeStake.addPool(address(0x0), 1, 10, 2, false);
    }

    // 验证修改池子参数（最小质押量、锁定区块）
    function test_updatePool() public {
        vm.startPrank(admin);
        // 先添加ETH池
        metaNodeStake.addPool(address(0), 1, 10, 2, false);

        // 事件断言
        vm.expectEmit(true, true, true, false);
        emit UpdatePoolInfo(0, 20, 50);
        // 修改池子参数
        metaNodeStake.updatePool(0, 20, 50);

        // 读取池子数据校验
        (
            ,
            ,
            ,
            ,
            ,
            uint256 minDeposit,
            uint256 lockBlocks
        ) = metaNodeStake.pool(0);
        assertEq(minDeposit, 20);
        assertEq(lockBlocks, 50);
        vm.stopPrank();
    }

    // 验证修改池子权重
    function test_setPoolWeight() public {
        vm.startPrank(admin);
        // 添加池子
        metaNodeStake.addPool(address(0), 100, 10, 2, false);
        metaNodeStake.addPool(address(testErc20), 200, 10, 2, false);

        // 事件断言
        vm.expectEmit(true, true, false, false);
        emit SetPoolWeight(0, 150, 350);
        // 修改权重
        metaNodeStake.setPoolWeight(0, 150, true);

        assertEq(metaNodeStake.totalPoolWeight(), 350);
        vm.stopPrank();
    }

    // 测试非管理员无法调用管理员功能（权限校验）
    function test_fail_NonAdminCall() public {
        // 普通用户尝试暂停提现，预期失败
        vm.prank(user1);
        vm.expectRevert();
        metaNodeStake.pauseWithdraw();

        // 普通用户尝试添加池子，预期失败
        vm.prank(user1);
        vm.expectRevert();
        metaNodeStake.addPool(address(0), 1, 10, 2, false);
    }

    // 测试ETH质押功能
    function test_depositETH() public {
        // 前置：添加ETH池
        vm.prank(admin);
        metaNodeStake.addPool(address(0), 100, 1 ether, 10, false);

        vm.startPrank(user1);
        // 质押金额小于最小值，预期失败
        vm.expectRevert("deposit amount is too small");
        metaNodeStake.depositETH{value: 0.5 ether}();

        // 事件断言
        vm.expectEmit(true, true, false, false);
        emit Deposit(user1, 0, 2 ether);
        // 正常质押ETH
        metaNodeStake.depositETH{value: 2 ether}();

        // 校验质押结果
        assertEq(metaNodeStake.stakingBalance(0, user1), 2 ether);
        assertEq(address(metaNodeStake).balance, 2 ether);
        vm.stopPrank();
    }

    // 测试ERC20质押功能
    function test_depositERC20() public {
        // 前置：添加池子
        vm.prank(admin);
        metaNodeStake.addPool(address(0), 100, 1 ether, 10, false);
        vm.prank(admin);
        metaNodeStake.addPool(address(testErc20), 200, 5, 10, false);

        vm.startPrank(user1);
        // 授权代币
        testErc20.approve(address(metaNodeStake), 100);

        // 事件断言
        vm.expectEmit(true, true, false, false);
        emit Deposit(user1, 1, 10);
        // 质押ERC20
        metaNodeStake.deposit(1, 10);

        // 校验
        assertEq(metaNodeStake.stakingBalance(1, user1), 10);
        assertEq(testErc20.balanceOf(address(metaNodeStake)), 10);
        vm.stopPrank();
    }

    // 测试申请解质押功能
    function test_unstake() public {
        // 前置准备
        vm.prank(admin);
        metaNodeStake.addPool(address(0), 100, 1 ether, 10, false);
        vm.prank(user1);
        metaNodeStake.depositETH{value: 2 ether}();

        vm.startPrank(user1);
        // 解质押超过质押数量，预期失败
        vm.expectRevert("Not enough staking token balance");
        metaNodeStake.unstake(0, 3 ether);

        // 事件断言
        vm.expectEmit(true, true, false, false);
        emit RequestUnstake(user1, 0, 1 ether);
        // 正常解质押
        metaNodeStake.unstake(0, 1 ether);

        // 校验质押余额减少
        assertEq(metaNodeStake.stakingBalance(0, user1), 1 ether);
        vm.stopPrank();
    }
 
    // 测试解锁后提现功能
    function test_withdraw() public {
        // 前置准备
        vm.prank(admin);
        metaNodeStake.addPool(address(0), 100, 1 ether, 10, false);
        vm.prank(user1);
        metaNodeStake.depositETH{value: 2 ether}();
        vm.prank(user1);
        metaNodeStake.unstake(0, 1 ether);

        // 区块未到解锁高度，提现无金额
        vm.prank(user1);
        metaNodeStake.withdraw(0);
        assertEq(user1.balance, 98 ether);

        // 跳过锁定区块
        vm.roll(block.number + 20);

        vm.startPrank(user1);
        // 事件断言
        vm.expectEmit(true, true, false, true);
        emit Withdraw(user1, 0, 1 ether, block.number + 20);
        // 提现
        metaNodeStake.withdraw(0);

        // 校验ETH到账
        assertEq(user1.balance, 99 ether);
        vm.stopPrank();
    }

    // 测试领取奖励功能
    function test_claimReward() public {
        // 1. 给质押合约转入足量奖励代币（核心）
        deal(address(metaNodeToken), address(metaNodeStake), 100_000 ether);

        // 2. 管理员添加ETH池（必须开启_withUpdate=true，初始化奖励计算）
        vm.startPrank(admin);
        // 参数：ETH地址、权重100、最小质押1 ether、锁定10区块、更新奖励
        metaNodeStake.addPool(address(0), 100, 1 ether, 10, true);
        vm.stopPrank();

        // 3. 用户1质押ETH
        vm.startPrank(user1);
        metaNodeStake.depositETH{value: 2 ether}();
        vm.stopPrank();

        // 4. 强制跳过大量区块，触发奖励累计（核心：必须超过开始区块）
        vm.roll(START_BLOCK + 500);

        // 5. 预查询待领取奖励（调试用，可删除）
        uint256 pending = metaNodeStake.pendingMetaNode(0, user1);
        console2.log("Pending Reward:", pending); // 打印待领取奖励

        // 6. 领取奖励
        vm.startPrank(user1);
        uint256 beforeBalance = metaNodeToken.balanceOf(user1);

        // 事件断言
        vm.expectEmit(true, true, false, false);
        emit Claim(user1, 0, pending);
        metaNodeStake.claim(0);

        // 7. 校验奖励到账（修复断言）
        uint256 afterBalance = metaNodeToken.balanceOf(user1);
        assertGt(afterBalance, beforeBalance, "Reward not received");
        vm.stopPrank();
    }

    // 测试暂停功能生效（提现暂停后无法操作）
    function test_fail_WithdrawWhenPaused() public {
        // 前置准备
        vm.prank(admin);
        metaNodeStake.addPool(address(0), 100, 1 ether, 10, false);
        vm.prank(user1);
        metaNodeStake.depositETH{value: 2 ether}();
        vm.prank(user1);
        metaNodeStake.unstake(0, 1 ether);
        vm.roll(block.number + 20);

        // 管理员暂停提现
        vm.prank(admin);
        metaNodeStake.pauseWithdraw();

        // 用户尝试提现，预期失败
        vm.prank(user1);
        vm.expectRevert("withdraw is paused");
        metaNodeStake.withdraw(0);
    }

    // 测试暂停领取奖励功能生效
    function test_fail_ClaimWhenPaused() public {
        // 前置准备
        deal(address(metaNodeToken), address(metaNodeStake), 10000 ether);
        vm.prank(admin);
        metaNodeStake.addPool(address(0), 100, 1 ether, 10, false);
        vm.prank(user1);
        metaNodeStake.depositETH{value: 2 ether}();
        vm.roll(block.number + 50);

        // 管理员暂停领取
        vm.prank(admin);
        metaNodeStake.pauseClaim();

        // 用户尝试领奖励，预期失败
        vm.prank(user1);
        vm.expectRevert("claim is paused");
        metaNodeStake.claim(0);
    }
}