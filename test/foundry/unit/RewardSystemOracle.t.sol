// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Setup.sol";
import {MockOracle} from "../../../contracts/mocks/MockOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock ERC20 with configurable decimals for testing different loanTokens
contract MockERC20 is ERC20 {
    uint8 private _dec;

    constructor(string memory name, string memory symbol, uint8 dec_) ERC20(name, symbol) {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RewardSystemOracleTest is Setup {
    uint256 pid;

    function setUp() public override {
        super.setUp();
        pid = _createProject(20_000e6, 40_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  Oracle price integration
    // ═══════════════════════════════════════════════════════════════

    function test_recordInvestment_usesOraclePrice() public {
        _investAs(investor, pid, 25_000e6, inviter);

        // tokenPercentage = 6% -> 1500 USDC worth of tokens
        // Oracle price = 1e6 (0.01 USD in 8 decimals)
        // tokensAmount = 1500e6 * 1e8 * 1e18 / (1e6 * 1e6) = 150_000e18
        (,uint256 totalTokens,,,) = rewardSystem.getProjectRewards(investor, pid);
        assertEq(totalTokens, 150_000e18, "Token reward amount from oracle incorrect");
    }

    function test_recordInvestment_revertsWhenOraclePriceZero() public {
        // Set oracle to one that returns price=0
        MockOracle zeroOracle = new MockOracle();
        vm.prank(owner);
        rewardSystem.setOracle(address(zeroOracle));

        // Prepare invest manually (can't use _investAs with expectRevert)
        vm.prank(owner);
        usdc.mint(investor, 25_000e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 25_000e6);

        uint256 currentNonce = fundraise.userNonces(investor);
        bytes memory sig = _signInvest(investor, pid, 25_000e6, currentNonce + 1, inviter);

        vm.prank(investor);
        vm.expectRevert("Oracle: no valid price");
        fundraise.investUpdateV2(pid, 25_000e6, currentNonce + 1, sig, inviter);
    }

    function test_recordInvestment_revertsWhenOracleNotSet() public {
        // Deploy a fresh RewardSystem without oracle set
        vm.startPrank(owner);
        RewardSystem impl = new RewardSystem();
        bytes memory initData = abi.encodeCall(
            RewardSystem.initialize,
            (address(managerRegistry), address(token), address(usdc), address(mockRouter))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        RewardSystem freshRS = RewardSystem(address(proxy));

        // Point both managerRegistry AND fundraise to fresh RS
        managerRegistry.setContractAddresses(
            address(freshRS),
            address(fundraise),
            address(treasury)
        );
        fundraise.setRewardSystem(address(freshRS));
        vm.stopPrank();

        // Prepare invest manually
        vm.prank(owner);
        usdc.mint(investor, 25_000e6);
        vm.prank(investor);
        usdc.approve(address(fundraise), 25_000e6);

        uint256 currentNonce = fundraise.userNonces(investor);
        bytes memory sig = _signInvest(investor, pid, 25_000e6, currentNonce + 1, inviter);

        vm.prank(investor);
        vm.expectRevert(Fundraise.OracleNotSet.selector);
        fundraise.investUpdateV2(pid, 25_000e6, currentNonce + 1, sig, inviter);

        // Restore original reward system
        vm.startPrank(owner);
        managerRegistry.setContractAddresses(
            address(rewardSystem),
            address(fundraise),
            address(treasury)
        );
        fundraise.setRewardSystem(address(rewardSystem));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //                  setOracle
    // ═══════════════════════════════════════════════════════════════

    function test_setOracle_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Invalid address");
        rewardSystem.setOracle(address(0));
    }

    function test_setOracle_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        rewardSystem.setOracle(address(mockOracle));
    }

    function test_setOracle_updatesOracleAddress() public {
        MockOracle newOracle = new MockOracle();

        vm.prank(owner);
        rewardSystem.setOracle(address(newOracle));

        assertEq(rewardSystem.oracle(), address(newOracle), "Oracle address not updated");
    }

    function test_setOracle_emitsEvent() public {
        MockOracle newOracle = new MockOracle();

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit RewardSystem.OracleUpdated(address(newOracle));
        rewardSystem.setOracle(address(newOracle));
    }

    // ═══════════════════════════════════════════════════════════════
    //          T-02: Bonus exploit via cheap tokens
    // ═══════════════════════════════════════════════════════════════

    /// @notice Helper to create a project with a custom loanToken
    function _createProjectWithLoanToken(uint256 softCap, uint256 hardCap, address loanToken)
        internal
        returns (uint256 projectId)
    {
        Fundraise.Project memory proj = Fundraise.Project({
            hardCap: hardCap,
            softCap: softCap,
            totalInvested: 0,
            startAt: block.timestamp - 10,
            preFundDuration: 7 days,
            investorInterestRate: INVESTOR_INTEREST,
            openStageEndAt: block.timestamp + 7 days,
            innerStruct: Fundraise.InnerProjectStruct({
                platformInterestRate: PLATFORM_FEE,
                totalRepaid: 0,
                borrower: borrower,
                fundedTime: 0,
                loanToken: IERC20(loanToken),
                stage: Fundraise.Stage.ComingSoon
            })
        });

        vm.prank(manager);
        projectId = fundraise.createProject(proj, 1);
    }

    /// @notice Helper to invest with a custom loanToken
    function _investWithToken(
        address _investor,
        uint256 _pid,
        uint256 _amount,
        address _inviter,
        MockERC20 _loanToken
    ) internal {
        _loanToken.mint(_investor, _amount);

        vm.prank(_investor);
        IERC20(address(_loanToken)).approve(address(fundraise), _amount);

        uint256 currentNonce = fundraise.userNonces(_investor);
        uint256 nonceForSig = currentNonce + 1;
        bytes memory sig = _signInvest(_investor, _pid, _amount, nonceForSig, _inviter);

        vm.prank(_investor);
        fundraise.investUpdateV2(_pid, _amount, nonceForSig, sig, _inviter);
    }

    /// @notice Invest 1000 of worthless token (oracle price ~0) -> no bonus
    function test_bonusExploit_worthlessToken_noBonus() public {
        // Deploy a worthless 18-decimal token
        MockERC20 worthlessToken = new MockERC20("Worthless", "WRTH", 18);

        // Set oracle price: nearly 0 (1 = 0.00000001 USD in 8 decimals)
        vm.prank(owner);
        mockOracle.setPrice(address(worthlessToken), 1);

        // Create a project using worthless token as loanToken
        uint256 worthlessPid = _createProjectWithLoanToken(500e18, 5_000e18, address(worthlessToken));

        // Invest 1000e18 of worthless token (attacker tries to meet the 1000e6 USDC threshold)
        _investWithToken(attacker, worthlessPid, 1000e18, inviter, worthlessToken);

        // investmentUSD = 1000e18 * 1 / (1e8 * 1e12) = 1000e18 / 1e20 = 0.01e6 = 10000
        // 10000 < 1000e6 (minInvestmentForBonus) -> no bonus
        (uint256 attackerUSDC,,,,) = rewardSystem.getProjectRewards(attacker, worthlessPid);
        assertEq(attackerUSDC, 0, "Worthless token should not earn welcome bonus");
    }

    /// @notice Invest 1000 USDC equivalent -> bonus awarded
    function test_bonus_usdcInvestment_bonusAwarded() public {
        // The default setup already has USDC at price 1e8 ($1)
        // Create project with USDC as loanToken
        uint256 usdcPid = _createProject(500e6, 5_000e6);

        // Invest exactly 1000 USDC (threshold amount)
        _investAs(investor, usdcPid, 1_000e6, inviter);

        // investmentUSD = 1000e6 * 1e8 / 1e8 = 1000e6 >= minInvestmentForBonus (1000e6)
        (uint256 investorUSDC,,,,) = rewardSystem.getProjectRewards(investor, usdcPid);
        assertEq(investorUSDC, 30e6, "USDC investment at threshold should earn 30 USDC welcome bonus");
    }

    /// @notice Invest 500 of token worth $3 each -> $1500 USD -> bonus awarded
    function test_bonus_valuableToken_bonusAwarded() public {
        // Deploy a valuable 18-decimal token
        MockERC20 valuableToken = new MockERC20("Valuable", "VAL", 18);

        // Set oracle price: $3 = 3e8 (8 decimals)
        vm.prank(owner);
        mockOracle.setPrice(address(valuableToken), 3e8);

        // Create a project using valuable token as loanToken
        uint256 valPid = _createProjectWithLoanToken(100e18, 5_000e18, address(valuableToken));

        // Invest 500e18 of valuable token (worth $1500 USD)
        _investWithToken(investor, valPid, 500e18, inviter, valuableToken);

        // investmentUSD = 500e18 * 3e8 / (1e8 * 1e12) = 500e18 * 3e8 / 1e20 = 1500e6
        // 1500e6 >= 1000e6 (minInvestmentForBonus) -> bonus awarded
        (uint256 investorUSDC,,,,) = rewardSystem.getProjectRewards(investor, valPid);
        assertEq(investorUSDC, 30e6, "Valuable token investment worth $1500 should earn 30 USDC welcome bonus");
    }
}
