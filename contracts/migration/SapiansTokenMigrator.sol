// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.7.5;

import "../interfaces/IERC20.sol";
import "../interfaces/IsSAPI.sol";
import "../interfaces/IwsSAPI.sol";
import "../interfaces/IgSAPI.sol";
import "../interfaces/ITreasury.sol";
import "../interfaces/IStaking.sol";
import "../interfaces/IOwnable.sol";
import "../interfaces/IUniswapV2Router.sol";
import "../interfaces/IStakingV1.sol";
import "../interfaces/ITreasuryV1.sol";

import "../types/SapiansAccessControlled.sol";

import "../libraries/SafeMath.sol";
import "../libraries/SafeERC20.sol";


contract SapiansTokenMigrator is SapiansAccessControlled {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IgSAPI;
    using SafeERC20 for IsSAPI;
    using SafeERC20 for IwsSAPI;

    /* ========== MIGRATION ========== */

    event TimelockStarted(uint256 block, uint256 end);
    event Migrated(address staking, address treasury);
    event Funded(uint256 amount);
    event Defunded(uint256 amount);

    /* ========== STATE VARIABLES ========== */

    IERC20 public immutable oldSAPI;
    IsSAPI public immutable oldsSAPI;
    IwsSAPI public immutable oldwsSAPI;
    ITreasuryV1 public immutable oldTreasury;
    IStakingV1 public immutable oldStaking;

    IUniswapV2Router public immutable sushiRouter;
    IUniswapV2Router public immutable uniRouter;

    IgSAPI public gSAPI;
    ITreasury public newTreasury;
    IStaking public newStaking;
    IERC20 public newSAPI;

    bool public sapiMigrated;
    bool public shutdown;

    uint256 public immutable timelockLength;
    uint256 public timelockEnd;

    uint256 public oldSupply;

    constructor(
        address _oldSAPI,
        address _oldsSAPI,
        address _oldTreasury,
        address _oldStaking,
        address _oldwsSAPI,
        address _sushi,
        address _uni,
        uint256 _timelock,
        address _authority
    ) SapiansAccessControlled(ISapiansAuthority(_authority)) {
        require(_oldSAPI != address(0), "Zero address: SAPI");
        oldSAPI = IERC20(_oldSAPI);
        require(_oldsSAPI != address(0), "Zero address: sSAPI");
        oldsSAPI = IsSAPI(_oldsSAPI);
        require(_oldTreasury != address(0), "Zero address: Treasury");
        oldTreasury = ITreasuryV1(_oldTreasury);
        require(_oldStaking != address(0), "Zero address: Staking");
        oldStaking = IStakingV1(_oldStaking);
        require(_oldwsSAPI != address(0), "Zero address: wsSAPI");
        oldwsSAPI = IwsSAPI(_oldwsSAPI);
        require(_sushi != address(0), "Zero address: Sushi");
        sushiRouter = IUniswapV2Router(_sushi);
        require(_uni != address(0), "Zero address: Uni");
        uniRouter = IUniswapV2Router(_uni);
        timelockLength = _timelock;
    }

    /* ========== MIGRATION ========== */

    enum TYPE {
        UNSTAKED,
        STAKED,
        WRAPPED
    }

    // migrate SAPIv1, sSAPIv1, or wsSAPI for SAPIv2, sSAPIv2, or gSAPI
    function migrate(
        uint256 _amount,
        TYPE _from,
        TYPE _to
    ) external {
        require(!shutdown, "Shut down");

        uint256 wAmount = oldwsSAPI.sSAPITowSAPI(_amount);

        if (_from == TYPE.UNSTAKED) {
            require(sapiMigrated, "Only staked until migration");
            oldSAPI.safeTransferFrom(msg.sender, address(this), _amount);
        } else if (_from == TYPE.STAKED) {
            oldsSAPI.safeTransferFrom(msg.sender, address(this), _amount);
        } else {
            oldwsSAPI.safeTransferFrom(msg.sender, address(this), _amount);
            wAmount = _amount;
        }

        if (sapiMigrated) {
            require(oldSupply >= oldSAPI.totalSupply(), "SAPIv1 minted");
            _send(wAmount, _to);
        } else {
            gSAPI.mint(msg.sender, wAmount);
        }
    }

    // migrate all olympus tokens held
    function migrateAll(TYPE _to) external {
        require(!shutdown, "Shut down");

        uint256 sapiBal = 0;
        uint256 sSAPIBal = oldsSAPI.balanceOf(msg.sender);
        uint256 wsSAPIBal = oldwsSAPI.balanceOf(msg.sender);

        if (oldSAPI.balanceOf(msg.sender) > 0 && sapiMigrated) {
            sapiBal = oldSAPI.balanceOf(msg.sender);
            oldSAPI.safeTransferFrom(msg.sender, address(this), sapiBal);
        }
        if (sSAPIBal > 0) {
            oldsSAPI.safeTransferFrom(msg.sender, address(this), sSAPIBal);
        }
        if (wsSAPIBal > 0) {
            oldwsSAPI.safeTransferFrom(msg.sender, address(this), wsSAPIBal);
        }

        uint256 wAmount = wsSAPIBal.add(oldwsSAPI.sSAPITowSAPI(sapiBal.add(sSAPIBal)));
        if (sapiMigrated) {
            require(oldSupply >= oldSAPI.totalSupply(), "SAPIv1 minted");
            _send(wAmount, _to);
        } else {
            gSAPI.mint(msg.sender, wAmount);
        }
    }

    // send preferred token
    function _send(uint256 wAmount, TYPE _to) internal {
        if (_to == TYPE.WRAPPED) {
            gSAPI.safeTransfer(msg.sender, wAmount);
        } else if (_to == TYPE.STAKED) {
            newStaking.unwrap(msg.sender, wAmount);
        } else if (_to == TYPE.UNSTAKED) {
            newStaking.unstake(msg.sender, wAmount, false, false);
        }
    }

    // bridge back to SAPI, sSAPI, or wsSAPI
    function bridgeBack(uint256 _amount, TYPE _to) external {
        if (!sapiMigrated) {
            gSAPI.burn(msg.sender, _amount);
        } else {
            gSAPI.safeTransferFrom(msg.sender, address(this), _amount);
        }

        uint256 amount = oldwsSAPI.wSAPITosSAPI(_amount);
        // error throws if contract does not have enough of type to send
        if (_to == TYPE.UNSTAKED) {
            oldSAPI.safeTransfer(msg.sender, amount);
        } else if (_to == TYPE.STAKED) {
            oldsSAPI.safeTransfer(msg.sender, amount);
        } else if (_to == TYPE.WRAPPED) {
            oldwsSAPI.safeTransfer(msg.sender, _amount);
        }
    }

    /* ========== OWNABLE ========== */

    // halt migrations (but not bridging back)
    function halt() external onlyPolicy {
        require(!sapiMigrated, "Migration has occurred");
        shutdown = !shutdown;
    }

    // withdraw backing of migrated SAPI
    function defund(address reserve) external onlyGovernor {
        require(sapiMigrated, "Migration has not begun");
        require(timelockEnd < block.number && timelockEnd != 0, "Timelock not complete");

        oldwsSAPI.unwrap(oldwsSAPI.balanceOf(address(this)));

        uint256 amountToUnstake = oldsSAPI.balanceOf(address(this));
        oldsSAPI.approve(address(oldStaking), amountToUnstake);
        oldStaking.unstake(amountToUnstake, false);

        uint256 balance = oldSAPI.balanceOf(address(this));

        if(balance > oldSupply) {
            oldSupply = 0;
        } else {
            oldSupply -= balance;
        }

        uint256 amountToWithdraw = balance.mul(1e9);
        oldSAPI.approve(address(oldTreasury), amountToWithdraw);
        oldTreasury.withdraw(amountToWithdraw, reserve);
        IERC20(reserve).safeTransfer(address(newTreasury), IERC20(reserve).balanceOf(address(this)));

        emit Defunded(balance);
    }

    // start timelock to send backing to new treasury
    function startTimelock() external onlyGovernor {
        require(timelockEnd == 0, "Timelock set");
        timelockEnd = block.number.add(timelockLength);

        emit TimelockStarted(block.number, timelockEnd);
    }

    // set gSAPI address
    function setgSAPI(address _gSAPI) external onlyGovernor {
        require(address(gSAPI) == address(0), "Already set");
        require(_gSAPI != address(0), "Zero address: gSAPI");

        gSAPI = IgSAPI(_gSAPI);
    }

    // call internal migrate token function
    function migrateToken(address token) external onlyGovernor {
        _migrateToken(token, false);
    }

    /**
     *   @notice Migrate LP and pair with new SAPI
     */
    function migrateLP(
        address pair,
        bool sushi,
        address token,
        uint256 _minA,
        uint256 _minB
    ) external onlyGovernor {
        uint256 oldLPAmount = IERC20(pair).balanceOf(address(oldTreasury));
        oldTreasury.manage(pair, oldLPAmount);

        IUniswapV2Router router = sushiRouter;
        if (!sushi) {
            router = uniRouter;
        }

        IERC20(pair).approve(address(router), oldLPAmount);
        (uint256 amountA, uint256 amountB) = router.removeLiquidity(
            token, 
            address(oldSAPI), 
            oldLPAmount,
            _minA, 
            _minB, 
            address(this), 
            block.timestamp
        );

        newTreasury.mint(address(this), amountB);

        IERC20(token).approve(address(router), amountA);
        newSAPI.approve(address(router), amountB);

        router.addLiquidity(
            token, 
            address(newSAPI), 
            amountA, 
            amountB, 
            amountA, 
            amountB, 
            address(newTreasury), 
            block.timestamp
        );
    }

    // Failsafe function to allow owner to withdraw funds sent directly to contract in case someone sends non-sapi tokens to the contract
    function withdrawToken(
        address tokenAddress,
        uint256 amount,
        address recipient
    ) external onlyGovernor {
        require(tokenAddress != address(0), "Token address cannot be 0x0");
        require(tokenAddress != address(gSAPI), "Cannot withdraw: gSAPI");
        require(tokenAddress != address(oldSAPI), "Cannot withdraw: old-SAPI");
        require(tokenAddress != address(oldsSAPI), "Cannot withdraw: old-sSAPI");
        require(tokenAddress != address(oldwsSAPI), "Cannot withdraw: old-wsSAPI");
        require(amount > 0, "Withdraw value must be greater than 0");
        if (recipient == address(0)) {
            recipient = msg.sender; // if no address is specified the value will will be withdrawn to Owner
        }

        IERC20 tokenContract = IERC20(tokenAddress);
        uint256 contractBalance = tokenContract.balanceOf(address(this));
        if (amount > contractBalance) {
            amount = contractBalance; // set the withdrawal amount equal to balance within the account.
        }
        // transfer the token from address of this contract
        tokenContract.safeTransfer(recipient, amount);
    }

    // migrate contracts
    function migrateContracts(
        address _newTreasury,
        address _newStaking,
        address _newSAPI,
        address _newsSAPI,
        address _reserve
    ) external onlyGovernor {
        require(!sapiMigrated, "Already migrated");
        sapiMigrated = true;
        shutdown = false;

        require(_newTreasury != address(0), "Zero address: Treasury");
        newTreasury = ITreasury(_newTreasury);
        require(_newStaking != address(0), "Zero address: Staking");
        newStaking = IStaking(_newStaking);
        require(_newSAPI != address(0), "Zero address: SAPI");
        newSAPI = IERC20(_newSAPI);

        oldSupply = oldSAPI.totalSupply(); // log total supply at time of migration

        gSAPI.migrate(_newStaking, _newsSAPI); // change gSAPI minter

        _migrateToken(_reserve, true); // will deposit tokens into new treasury so reserves can be accounted for

        _fund(oldsSAPI.circulatingSupply()); // fund with current staked supply for token migration

        emit Migrated(_newStaking, _newTreasury);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    // fund contract with gSAPI
    function _fund(uint256 _amount) internal {
        newTreasury.mint(address(this), _amount);
        newSAPI.approve(address(newStaking), _amount);
        newStaking.stake(address(this), _amount, false, true); // stake and claim gSAPI

        emit Funded(_amount);
    }

    /**
     *   @notice Migrate token from old treasury to new treasury
     */
    function _migrateToken(address token, bool deposit) internal {
        uint256 balance = IERC20(token).balanceOf(address(oldTreasury));

        uint256 excessReserves = oldTreasury.excessReserves();
        uint256 tokenValue = oldTreasury.valueOf(token, balance);

        if (tokenValue > excessReserves) {
            tokenValue = excessReserves;
            balance = excessReserves * 10**9;
        }

        oldTreasury.manage(token, balance);

        if (deposit) {
            IERC20(token).safeApprove(address(newTreasury), balance);
            newTreasury.deposit(balance, token, tokenValue);
        } else {
            IERC20(token).safeTransfer(address(newTreasury), balance);
        }
    }
}
