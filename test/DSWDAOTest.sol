// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/DSWDAO.sol";

contract DSWDAOTest is Test {
    DSWDAO public token;
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public user3 = address(0x4);

    uint256 constant INITIAL_SUPPLY = 20_000_000 * 10**18;
    uint256 constant STAKE_AMOUNT = 5000 * 10**18;
    uint256 constant PROPOSAL_THRESHOLD = 10000 * 10**18;

    function setUp() public {
        vm.startPrank(owner);
        token = new DSWDAO();
        
        // Distribuisci token agli utenti per testing
        token.transfer(user1, 50000 * 10**18);
        token.transfer(user2, 50000 * 10**18);
        token.transfer(user3, 50000 * 10**18);
        
        // Unpause il contratto per testing
        token.unpause();
        vm.stopPrank();
    }

    // ✅ Test base functionality
    function test_InitialState() public {
        assertEq(token.name(), "DSWDAO Token");
        assertEq(token.symbol(), "DSW");
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY - 150000 * 10**18);
        assertFalse(token.isPaused()); // Dovrebbe essere unpaused dopo setup
    }

    // ✅ Test pause/unpause functionality
    function test_PauseUnpause() public {
        vm.prank(owner);
        token.pause();
        assertTrue(token.isPaused());

        vm.prank(owner);
        token.unpause();
        assertFalse(token.isPaused());
    }

    // ✅ Test staking functionality
    function test_StakeUnstake() public {
        vm.startPrank(user1);
        uint256 initialBalance = token.balanceOf(user1);
        
        token.stake(STAKE_AMOUNT);
        assertEq(token.totalStaked(), STAKE_AMOUNT);
        assertEq(token.getVotingPower(user1), STAKE_AMOUNT);
        assertEq(token.balanceOf(user1), initialBalance - STAKE_AMOUNT);

        token.unstake(STAKE_AMOUNT);
        assertEq(token.totalStaked(), 0);
        assertEq(token.getVotingPower(user1), 0);
        assertEq(token.balanceOf(user1), initialBalance);
        vm.stopPrank();
    }

    // ✅ Test rewards calculation
    function test_RewardsCalculation() public {
        vm.startPrank(user1);
        token.stake(STAKE_AMOUNT);
        
        // Avanza di alcuni blocchi per accumulare rewards
        vm.roll(block.number + 1000);
        
        uint256 pendingRewards = token.getPendingRewards(user1);
        assertGt(pendingRewards, 0);

        token.claimRewards();
        assertGt(token.balanceOf(user1), 0);
        vm.stopPrank();
    }

    // ✅ Test max supply protection - FIXED
    function test_MaxSupplyProtection() public {
        // Setup per accumulare molti rewards
        vm.startPrank(user1);
        token.stake(100000 * 10**18); // Stake grande per rewards elevati
        
        // Avanza di molti blocchi per generare rewards che eccedono max supply
        vm.roll(block.number + 10000000);
        
        // Dovrebbe fallire perché supererebbe max supply
        vm.expectRevert("DSWDAO: Max supply exceeded");
        token.claimRewards();
        vm.stopPrank();
    }

    // ✅ Test proposal creation and voting
    function test_ProposalCreationAndVoting() public {
        // User1 deve avere abbastanza voting power
        vm.startPrank(user1);
        token.stake(PROPOSAL_THRESHOLD);
        vm.stopPrank();

        vm.prank(user1);
        uint256 proposalId = token.createProposal("Test Proposal");

        DSWDAO.Proposal memory proposal = token.getProposal(proposalId);
        assertEq(proposal.id, proposalId);
        assertEq(proposal.proposer, user1);
        assertFalse(proposal.executed);

        // User1 vota a favore
        vm.prank(user1);
        token.vote(proposalId, true);

        // Avanza nel tempo oltre la deadline
        vm.warp(block.timestamp + 8 days);
        
        // Esegui la proposal
        token.executeProposal(proposalId);
        proposal = token.getProposal(proposalId);
        assertTrue(proposal.executed);
    }

    // ✅ Test snapshot functionality - FIXED
    function test_ProposalUsesSnapshot() public {
        // Setup iniziale
        vm.startPrank(user1);
        token.stake(PROPOSAL_THRESHOLD);
        uint256 initialVotingPower = token.getVotingPower(user1);
        vm.stopPrank();

        // Crea proposal (crea snapshot)
        vm.prank(user1);
        uint256 proposalId = token.createProposal("Snapshot Test");
        DSWDAO.Proposal memory proposal = token.getProposal(proposalId);

        // Cambia voting power dopo la snapshot
        vm.prank(user1);
        token.stake(5000 * 10**18); // Aumenta voting power

        // Verifica che lo snapshot abbia preservato il vecchio voting power
        uint256 snapshotVotingPower = token.getSnapshotVotingPower(proposal.snapshotId, user1);
        assertEq(snapshotVotingPower, initialVotingPower);
        assertLt(snapshotVotingPower, token.getVotingPower(user1)); // Current should be higher
    }

    // ✅ Test treasury functionality
    function test_TreasuryOperations() public {
        vm.startPrank(user1);
        uint256 depositAmount = 1000 * 10**18;
        token.depositToTreasury(depositAmount);
        assertEq(token.treasuryBalance(), depositAmount);
        vm.stopPrank();

        // Solo owner può prelevare
        vm.prank(owner);
        token.withdrawFromTreasury(depositAmount);
        assertEq(token.treasuryBalance(), 0);
    }

    // ✅ Test emergency withdraw - FIXED
    function test_EmergencyWithdraw() public {
        // Prima deposita fondi extra nel contratto
        vm.prank(user1);
        token.transfer(address(token), 1000 * 10**18);

        uint256 initialOwnerBalance = token.balanceOf(owner);
        
        vm.prank(owner);
        token.emergencyWithdraw();
        
        assertGt(token.balanceOf(owner), initialOwnerBalance);
    }

    // ✅ Test timelock functionality
    function test_TimelockOperations() public {
        uint256 timelockAmount = 5000 * 10**18;
        
        // Deposita nel treasury prima
        vm.prank(owner);
        token.depositToTreasury(timelockAmount);

        vm.prank(owner);
        token.createTimelock(user2, timelockAmount, 3 days);

        // Prova ad eseguire prima del tempo - dovrebbe fallire
        vm.prank(user2);
        vm.expectRevert("DSWDAO: Timelock active");
        token.executeTimelock();

        // Avanza nel tempo e esegui
        vm.warp(block.timestamp + 3 days);
        vm.prank(user2);
        token.executeTimelock();

        assertEq(token.balanceOf(user2), timelockAmount);
    }

    // ✅ Test cooldown proposal
    function test_ProposalCooldown() public {
        vm.startPrank(user1);
        token.stake(PROPOSAL_THRESHOLD);

        token.createProposal("First Proposal");
        
        // Prova a creare un'altra proposal troppo presto
        vm.expectRevert("DSWDAO: Cooldown active");
        token.createProposal("Second Proposal Too Soon");
        vm.stopPrank();
    }

    // ✅ Test snapshot creation
    function test_SnapshotCreation() public {
        uint256 initialSnapshotId = token.getCurrentSnapshotId();
        
        vm.prank(owner);
        uint256 newSnapshotId = token.createSnapshot();
        
        assertGt(newSnapshotId, initialSnapshotId);
        assertEq(token.snapshotTotalSupply(newSnapshotId), token.totalSupply());
    }

    // ✅ Test voting with snapshot
    function test_VotingWithSnapshot() public {
        // Setup
        vm.startPrank(user1);
        token.stake(PROPOSAL_THRESHOLD);
        uint256 initialVP = token.getVotingPower(user1);
        vm.stopPrank();

        // Crea proposal (crea snapshot)
        vm.prank(user1);
        uint256 proposalId = token.createProposal("Voting Test");

        // Cambia voting power dopo snapshot
        vm.prank(user1);
        token.stake(5000 * 10**18);

        // Vota - dovrebbe usare lo snapshot voting power
        vm.prank(user1);
        token.vote(proposalId, true);

        DSWDAO.Proposal memory proposal = token.getProposal(proposalId);
        assertEq(proposal.forVotes, initialVP); // Usa lo snapshot, non il current
    }

    // ✅ Test edge cases
    function test_Revert_StakeWhenPaused() public {
        vm.prank(owner);
        token.pause();

        vm.prank(user1);
        vm.expectRevert("DSWDAO: Contract paused");
        token.stake(STAKE_AMOUNT);
    }

    function test_Revert_UnstakeZero() public {
        vm.prank(user1);
        vm.expectRevert("DSWDAO: Zero amount");
        token.unstake(0);
    }

    function test_Revert_TransferToZero() public {
        vm.prank(user1);
        vm.expectRevert("DSWDAO: Zero address");
        token.transfer(address(0), 100);
    }

    // ✅ Test ownership functionality
    function test_OnlyOwnerFunctions() public {
        vm.prank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        token.pause();

        vm.prank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        token.setStakingRewardRate(20);
    }

    // ✅ Test staking rate update
    function test_StakingRateUpdate() public {
        uint256 newRate = 25;
        vm.prank(owner);
        token.setStakingRewardRate(newRate);
        
        assertEq(token.stakingRewardRate(), newRate);
    }

    // ✅ Test multiple users staking
    function test_MultipleUsersStaking() public {
        vm.startPrank(user1);
        token.stake(STAKE_AMOUNT);
        vm.stopPrank();

        vm.startPrank(user2);
        token.stake(STAKE_AMOUNT * 2);
        vm.stopPrank();

        assertEq(token.totalStaked(), STAKE_AMOUNT * 3);
        assertEq(token.getVotingPower(user1), STAKE_AMOUNT);
        assertEq(token.getVotingPower(user2), STAKE_AMOUNT * 2);
    }
}