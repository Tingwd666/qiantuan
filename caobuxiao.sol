// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

// ============ 测试版本参数 ============
// 第一阶段：上级20万，下级5万，持仓30分钟，黑洞销毁1万进二阶段
// 第二阶段：上级10万，下级3万，黑洞销毁5000
// 第三阶段：上级5万，下级1万，黑洞销毁3000
// 持仓时间：30分钟，阶段冷却：3分钟（方便测试）

import "@openzeppelin/contracts@4.9.0/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts@4.9.0/access/Ownable.sol";
import "@openzeppelin/contracts@4.9.0/governance/TimelockController.sol";
import "@openzeppelin/contracts@4.9.0/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts@4.9.0/utils/Address.sol";

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPancakeSwapPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IPancakeSwapRouter {
    function swapExactTokensForETH(
        uint amountIn, 
        uint amountOutMin, 
        address[] calldata path,    
        address to, 
        uint deadline
    ) external returns (uint[] memory amounts);
    
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);
    
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
}

contract TestTokenV2 is ERC20, Ownable, ReentrancyGuard {
    using Address for address;

    // ============ 常量定义 ============
    uint256 public constant BUY_FEE = 3;
    uint256 public constant SELL_FEE = 3;
    uint256 public constant FEE_DENOMINATOR = 100;
    
    uint256 public constant RATIO_75 = 75;
    uint256 public constant RATIO_25 = 25;
    
    // ============ 测试用参数：10分钟持仓，3分钟冷却 ============
    uint256 public constant HOLD_LOCK_PERIOD = 10 minutes;   // 10分钟持仓门槛
    uint256 public constant PHASE_LOCK_DELAY = 3 minutes;      // 3分钟冷却
    
    address public constant PANCAKE_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address public constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant BLACK_HOLE = 0x000000000000000000000000000000000000dEaD;

    // ============ 发行参数 ============
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10**18;
    uint256 public constant FINAL_SUPPLY = 200_000_000 * 10**18;
    uint256 public constant TOTAL_BURN_TARGET = 800_000_000 * 10**18;

    // ============ 测试用阶段销毁目标（累计销毁量） ============
    // 第一阶段：销毁1万 -> 第二阶段
    // 第二阶段：销毁1.5万 -> 第三阶段  
    // 第三阶段：销毁1.8万 -> 停止奖励
    uint256 public constant PHASE1_BURN_TARGET = 10_000 * 10**18;    // 1万
    uint256 public constant PHASE2_BURN_TARGET = 15_000 * 10**18;    // 1.5万
    uint256 public constant PHASE3_BURN_TARGET = 18_000 * 10**18;   // 1.8万
    uint256 public constant MAX_BURN_FOR_REWARD = 18_000 * 10**18;   // 1.8万停止奖励

    // ============ 阶段奖励比例 ============
    uint256 public constant PHASE1_REWARD_PERCENT = 1;
    uint256 public constant PHASE2_REWARD_PERCENT = 3;
    uint256 public constant PHASE3_REWARD_PERCENT = 5;

    // ============ 测试用阶段持仓门槛结构 ============
    // 第一阶段：上级20万，下级5万
    // 第二阶段：上级10万，下级3万
    // 第三阶段：上级5万，下级1万
    struct PhaseThreshold {
        uint256 upHold;
        uint256 userHold;
    }
    
    PhaseThreshold[] public phase1Thresholds;
    PhaseThreshold[] public phase2Thresholds;
    PhaseThreshold[] public phase3Thresholds;

    // ============ 状态变量 ============
    address public immutable rewardPool;
    address payable public immutable bnbWallet75;
    address payable public immutable bnbWallet25;
    
    mapping(address => bool) public isAMMPair;
    mapping(address => bool) public isExcludedFromFee;
    
    bool public tradingEnabled;
    uint256 public tradingEnableTime;
    
    // 阶段控制
    uint256 public phase1SwitchTime;
    uint256 public phase2SwitchTime;
    bool public phase1Locked;
    bool public phase2Locked;
    uint8 public currentPhase;
    
    // ============ 锁仓系统 ============
    struct LockInfo {
        uint256 amount;           // 锁仓数量
        uint256 startTime;        // 锁仓开始时间
        uint256 duration;         // 锁仓周期（秒）
        bool claimed;             // 是否已领取
    }
    mapping(address => LockInfo[]) public userLocks;  // 用户锁仓记录
    uint256 public constant MIN_LOCK_DURATION = 30 days;  // 最小锁仓30天
    uint256 public constant SWAP_SLIPPAGE = 200;    // 卖出兑换滑点保护 2%
    uint256 public constant BURN_SLIPPAGE = 50;     // 销毁兑换滑点保护 0.5%
    
    // 推广系统
    mapping(address => address) public referrer;
    mapping(address => uint256) public userFirstBuyTime;
    mapping(address => uint8) public userBuyPhase;
    mapping(address => bool) public hasSold;
    mapping(address => uint256) public referrerBindTime;  // 记录绑定时间
    
    // ============ 下级列表系统（支持一键批量领取）============
    mapping(address => address[]) public getMyReferrals;  // 上级 => 所有下级列表
    mapping(address => uint256) public referralCount;      // 上级 => 下级数量
    
    // ============ 持仓计时系统（新）
    mapping(address => uint256) public userThresholdStartTime;
    mapping(address => uint256) public userCurrentThreshold;
    
    // DEX累计买入记录（用于奖励资格）
    mapping(address => uint256) public cumulativeDEXBuy;
    
    // 记录达到门槛时的DEX买入量（用于判断是否真正通过DEX达到门槛）
    mapping(address => uint256) public thresholdReachedWithDEX;
    
    // 奖励领取记录：上级 => 下级 => 阶段 => 是否已领取
    mapping(address => mapping(address => mapping(uint8 => bool))) public rewardClaimed;
    
    // 最小兑换金额
    uint256 public minSwapAmount = 1000 * 10**18;

    // ============ 事件定义 ============
    event TradingEnabled(uint256 time);
    event TradingDisabled(uint256 time);
    event Burn(uint256 amount);
    event ReferrerBound(address indexed user, address indexed referrer);
    event RewardClaimed(address indexed up, address indexed user, uint256 rewardAmount, uint8 phase);
    event RewardClaimFailed(address indexed up, address indexed user, string reason);
    event RewardAvailable(address indexed up, address indexed user, uint256 rewardAmount, uint8 phase, uint256 threshold);
    event BuyFeeCollected(address indexed buyer, uint256 feeAmount);
    event SellFeeCollected(address indexed seller, uint256 feeAmount);
    event PhaseSwitched(uint8 newPhase, uint256 switchTime);
    event PhaseLocked(uint8 phase, uint256 burnedAmount, string reason);
    event BurnToBlackHole(address indexed burner, uint256 bnbAmount, uint256 tokenAmount);
    event BurnTokensToBlackHole(address indexed burner, uint256 tokenAmount, uint256 burnedBalance);
    event ThresholdReached(address indexed user, uint256 threshold, uint256 startTime);
    event ThresholdBroken(address indexed user, uint256 threshold);
    event AMMPairAdded(address indexed pair);
    event AMMPairRemoved(address indexed pair);
    event TokensExtracted(uint256 amount);
    event TokensLocked(address indexed user, uint256 amount, uint256 duration, uint256 lockId);
    event TokensUnlocked(address indexed user, uint256 amount, uint256 lockId);
    event RewardCheckRequested(address indexed user, uint8 currentPhase, bool eligible, uint256 rewardAmount);
    event DEXBuyRecorded(address indexed user, uint256 amount, uint256 total);

    // ============ 构造函数 ============
    constructor(
        string memory _name,
        string memory _symbol,
        address _rewardPool,
        address payable _bnb75,
        address payable _bnb25
    ) ERC20(_name, _symbol) {
        require(_rewardPool != address(0), "rewardPool zero");
        require(_bnb75 != address(0), "bnb75 zero");
        require(_bnb25 != address(0), "bnb25 zero");
        require(decimals() == 18, "decimals must be 18");

        rewardPool = _rewardPool;
        bnbWallet75 = _bnb75;
        bnbWallet25 = _bnb25;

        // ============ 测试用阶段门槛 ============
        // 第一阶段：上级20万，下级5万
        phase1Thresholds.push(PhaseThreshold(200_000 * 10**18, 50_000 * 10**18));
        
        // 第二阶段：上级10万，下级3万
        phase2Thresholds.push(PhaseThreshold(100_000 * 10**18, 30_000 * 10**18));
        
        // 第三阶段：上级5万，下级1万
        phase3Thresholds.push(PhaseThreshold(50_000 * 10**18, 10_000 * 10**18));

        _mint(msg.sender, TOTAL_SUPPLY);
        
        isExcludedFromFee[address(this)] = true;
        isExcludedFromFee[_rewardPool] = true;
        isExcludedFromFee[_bnb75] = true;
        isExcludedFromFee[_bnb25] = true;
        
        currentPhase = 1;
    }

    // ============ 管理功能 ============
    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "Trading already enabled");
        tradingEnabled = true;
        tradingEnableTime = block.timestamp;
        emit TradingEnabled(block.timestamp);
    }

    function disableTrading() external onlyOwner {
        require(tradingEnabled, "Trading already disabled");
        tradingEnabled = false;
        emit TradingDisabled(block.timestamp);
    }

    function addAMMPair(address _pair) external onlyOwner {
        require(_pair != address(0), "zero address");
        require(!isAMMPair[_pair], "already exists");
        
        // 验证必须是 PancakeSwap 的 LP
        IPancakeSwapPair pair = IPancakeSwapPair(_pair);
        require(pair.token0() == address(this) || pair.token1() == address(this), "not pancake pair");
        
        isAMMPair[_pair] = true;
        emit AMMPairAdded(_pair);
    }

    // ============ 时间锁 ============
    uint256 public constant TIMELOCK_DELAY = 24 hours;
    
    struct TimelockAction {
        string action;
        address target;
        uint256 executeTime;
    }
    mapping(bytes32 => TimelockAction) public timelockActions;
    
    // 高敏感操作需要时间锁
    function proposeRemoveAMMPair(address _pair) external onlyOwner returns (bytes32) {
        require(isAMMPair[_pair], "not exists");
        bytes32 operationId = keccak256(abi.encode(msg.sender, block.timestamp, "removeAMMPair", _pair));
        timelockActions[operationId] = TimelockAction({
            action: "removeAMMPair",
            target: _pair,
            executeTime: block.timestamp + TIMELOCK_DELAY
        });
        emit OperationQueued(operationId, "removeAMMPair", _pair, TIMELOCK_DELAY);
        return operationId;
    }
    
    // 执行时间锁操作
    function executeQueuedOperation(bytes32 operationId) external onlyOwner {
        TimelockAction memory action = timelockActions[operationId];
        require(action.executeTime > 0, "not queued");
        require(block.timestamp >= action.executeTime, "timelock not expired");
        
        if (keccak256(abi.encodePacked(action.action)) == keccak256("removeAMMPair")) {
            isAMMPair[action.target] = false;
            emit AMMPairRemoved(action.target);
        }
        
        delete timelockActions[operationId];
        emit OperationExecuted(operationId);
    }
    
    event OperationQueued(bytes32 indexed id, string action, address target, uint256 delay);
    event OperationExecuted(bytes32 indexed id);
    
    function setExcludedFromFee(address account, bool excluded) external onlyOwner {
        isExcludedFromFee[account] = excluded;
    }

    function setMinSwapAmount(uint256 _amount) external onlyOwner {
        minSwapAmount = _amount;
    }

    // ============ 推广绑定 ============
    function bindReferrer(address refAddr) external {
        require(refAddr != address(0) && refAddr != msg.sender, "invalid referrer");
        require(referrer[msg.sender] == address(0), "already bound");
        referrer[msg.sender] = refAddr;
        referrerBindTime[msg.sender] = block.timestamp;  // 记录绑定时间
        
        // 记录下级到上级的列表（支持一键批量领取）
        getMyReferrals[refAddr].push(msg.sender);
        referralCount[refAddr] += 1;
        
        emit ReferrerBound(msg.sender, refAddr);
    }
    
    // ============ 查看我的下级列表 ============
    function getMyReferralsCount() external view returns (uint256) {
        return referralCount[msg.sender];
    }
    
    // 获取我的所有下级地址
    function getMyReferralList() external view returns (address[] memory) {
        return getMyReferrals[msg.sender];
    }
    
    // 获取我的可领取奖励的下级数量
    function getClaimableReferralsCount() external view returns (uint256 count) {
        uint8 phase = getRewardPhase();
        if (phase == 0) return 0;
        
        address[] storage referrals = getMyReferrals[msg.sender];
        for (uint i = 0; i < referrals.length; i++) {
            if (!rewardClaimed[msg.sender][referrals[i]][phase] && canParticipateCurrentPhase(referrals[i])) {
                (bool qualified, , ) = checkHoldQualified(referrals[i]);
                if (qualified) {
                    count++;
                }
            }
        }
    }
    
    // ============ 一键领取所有推广奖励 ============
    function claimAllReferralRewards() external nonReentrant {
        require(tradingEnabled, "trading not enabled");
        uint8 phase = getRewardPhase();
        require(phase > 0, "reward not active");
        
        address[] storage referrals = getMyReferrals[msg.sender];
        require(referrals.length > 0, "no referrals");
        
        uint256 totalReward = _processBatchClaim(phase, referrals);
        require(totalReward > 0, "no claimable reward");
        emit RewardBatchClaimed(msg.sender, totalReward);
    }
    
    function _processBatchClaim(uint8 phase, address[] storage referrals) internal returns (uint256 totalReward) {
        uint256 rewardPercent = _getRewardPercent(phase);
        
        for (uint i = 0; i < referrals.length; i++) {
            address user = referrals[i];
            
            if (rewardClaimed[msg.sender][user][phase]) continue;
            if (!canParticipateCurrentPhase(user)) continue;
            
            (bool qualified, uint256 threshold, ) = checkHoldQualified(user);
            if (!qualified) continue;
            if (thresholdReachedWithDEX[user] < threshold) continue;
            
            if (!_checkUpQualified(phase, threshold)) continue;
            
            uint256 reward = threshold * rewardPercent / 100;
            
            if (balanceOf(rewardPool) >= reward) {
                rewardClaimed[msg.sender][user][phase] = true;
                _transfer(rewardPool, msg.sender, reward);
                totalReward += reward;
                emit RewardClaimed(msg.sender, user, reward, phase);
            }
        }
    }
    
    function _getRewardPercent(uint8 phase) internal pure returns (uint256) {
        if (phase == 1) return PHASE1_REWARD_PERCENT;
        if (phase == 2) return PHASE2_REWARD_PERCENT;
        return PHASE3_REWARD_PERCENT;
    }
    
    function _checkUpQualified(uint8 phase, uint256 threshold) internal view returns (bool) {
        PhaseThreshold[] storage thresholds;
        if (phase == 1) thresholds = phase1Thresholds;
        else if (phase == 2) thresholds = phase2Thresholds;
        else thresholds = phase3Thresholds;
        
        uint256 upBalance = balanceOf(msg.sender);
        
        for (uint j = 0; j < thresholds.length; j++) {
            if (thresholds[j].userHold == threshold && upBalance >= thresholds[j].upHold) {
                if (thresholdReachedWithDEX[msg.sender] >= thresholds[j].userHold) {
                    return true;
                }
            }
        }
        return false;
    }
    
    event RewardBatchClaimed(address indexed user, uint256 totalReward);

    // ============ 阶段管理 ============
    // 黑洞销毁达标 -> 立即停止当前阶段奖励 -> 冷却后开启下一阶段
    
    function _checkPhaseSwitch() internal {
        uint256 burned = balanceOf(BLACK_HOLE);
        
        // 第一阶段：销毁达到1万 -> 立即锁定 -> 3分钟后开启第二阶段
        if (!phase1Locked && burned >= PHASE1_BURN_TARGET) {
            phase1Locked = true;
            phase1SwitchTime = block.timestamp + PHASE_LOCK_DELAY;
            emit PhaseLocked(1, burned, "Phase1 reward stopped");
        }
        
        // 第二阶段：销毁达到1.5万 -> 立即锁定 -> 3分钟后开启第三阶段
        if (phase1Locked && !phase2Locked && burned >= PHASE2_BURN_TARGET) {
            phase2Locked = true;
            phase2SwitchTime = block.timestamp + PHASE_LOCK_DELAY;
            emit PhaseLocked(2, burned, "Phase2 reward stopped");
        }
        
        _updateCurrentPhase();
    }

    // 判断当前阶段推广奖励是否有效
    function isRewardActive() public view returns (bool) {
        uint256 burned = balanceOf(BLACK_HOLE);
        
        // 销毁达到1.8万，停止所有推广奖励
        if (burned >= PHASE3_BURN_TARGET) {
            return false;
        }
        
        // 第一阶段：未达到1万销毁量
        if (burned < PHASE1_BURN_TARGET) {
            return true;
        }
        
        // 第一阶段达标，等待冷却开启第二阶段
        if (!phase1Locked || block.timestamp < phase1SwitchTime) {
            return false;
        }
        
        // 第二阶段：已达到1万，未达到1.5万
        if (burned < PHASE2_BURN_TARGET) {
            return true;
        }
        
        // 第二阶段达标，等待冷却开启第三阶段
        if (!phase2Locked || block.timestamp < phase2SwitchTime) {
            return false;
        }
        
        // 第三阶段
        return true;
    }
    
    // 获取当前推广阶段（0=已结束）
    function getRewardPhase() public view returns (uint8) {
        if (!isRewardActive()) return 0;
        
        uint256 burned = balanceOf(BLACK_HOLE);
        
        if (burned < PHASE1_BURN_TARGET) return 1;
        if (burned < PHASE2_BURN_TARGET) return 2;
        return 3;
    }

    function _updateCurrentPhase() internal {
        uint8 newPhase = currentPhase;
        
        if (phase2Locked && block.timestamp >= phase2SwitchTime) {
            newPhase = 3;
        } else if (phase1Locked && block.timestamp >= phase1SwitchTime) {
            newPhase = 2;
        }
        
        if (newPhase != currentPhase) {
            currentPhase = newPhase;
            emit PhaseSwitched(newPhase, block.timestamp);
        }
    }

    function getCurrentPhase() public view returns (uint8) {
        if (phase2Locked && block.timestamp >= phase2SwitchTime) return 3;
        if (phase1Locked && block.timestamp >= phase1SwitchTime) return 2;
        return 1;
    }

    // 检查用户是否可以参与当前阶段
    function canParticipateCurrentPhase(address user) public view returns (bool) {
        uint8 phase = getUserPhase(user);
        uint8 rewardPhase = getRewardPhase();
        
        if (phase == 0) return true;
        if (hasSold[user] && balanceOf(user) <= 1) return true;
        
        uint256 userBalance = balanceOf(user);
        
        if (rewardPhase == 1) {
            return phase == 1;
        } else if (rewardPhase == 2) {
            if (phase == 1) {
                return userBalance <= 1;
            }
            return phase >= 2;
        } else if (rewardPhase == 3) {
            if (phase < 3) {
                return userBalance <= 1;
            }
            return phase == 3;
        }
        
        return false;
    }

    function getUserPhase(address user) public view returns (uint8) {
        if (userBuyPhase[user] == 0) return 0;
        return userBuyPhase[user];
    }

    // ============ 持仓计时系统 ============
    function _updateHoldTimer(address user) internal {
        uint8 phase = getCurrentPhase();
        if (phase == 0) return;
        
        PhaseThreshold[] storage thresholds;
        if (phase == 1) thresholds = phase1Thresholds;
        else if (phase == 2) thresholds = phase2Thresholds;
        else thresholds = phase3Thresholds;
        
        uint256 userBalance = balanceOf(user);
        uint256 applicableThreshold = 0;
        
        for (uint i = 0; i < thresholds.length; i++) {
            if (userBalance >= thresholds[i].userHold) {
                applicableThreshold = thresholds[i].userHold;
                break;
            }
        }
        
        uint256 currentThreshold = userCurrentThreshold[user];
        
        if (applicableThreshold > 0) {
            if (currentThreshold == 0) {
                userCurrentThreshold[user] = applicableThreshold;
                userThresholdStartTime[user] = block.timestamp;
                thresholdReachedWithDEX[user] = cumulativeDEXBuy[user];
                emit ThresholdReached(user, applicableThreshold, block.timestamp);
            } else if (userBalance >= currentThreshold) {
                _checkAndNotifyReward(user, phase);
            } else {
                userCurrentThreshold[user] = 0;
                userThresholdStartTime[user] = 0;
                thresholdReachedWithDEX[user] = 0;
                emit ThresholdBroken(user, currentThreshold);
            }
        } else {
            if (currentThreshold > 0 && userBalance < currentThreshold) {
                userCurrentThreshold[user] = 0;
                userThresholdStartTime[user] = 0;
                thresholdReachedWithDEX[user] = 0;
                emit ThresholdBroken(user, currentThreshold);
            }
        }
    }

    // 检查并通知上级奖励可领取
    function _checkAndNotifyReward(address user, uint8 phase) internal {
        address up = referrer[user];
        if (up == address(0)) return;
        
        if (rewardClaimed[up][user][phase]) return;
        
        uint256 threshold = userCurrentThreshold[user];
        uint256 startTime = userThresholdStartTime[user];
        
        if (startTime == 0) return;
        if (block.timestamp < startTime + HOLD_LOCK_PERIOD) return;
        
        if (thresholdReachedWithDEX[user] < threshold) return;
        
        uint256 upStartTime = userThresholdStartTime[up];
        if (upStartTime == 0 || upStartTime > startTime) return;
        
        PhaseThreshold[] storage thresholds;
        if (phase == 1) thresholds = phase1Thresholds;
        else if (phase == 2) thresholds = phase2Thresholds;
        else thresholds = phase3Thresholds;
        
        uint256 upBalance = balanceOf(up);
        bool upQualified = false;
        for (uint i = 0; i < thresholds.length; i++) {
            if (thresholds[i].userHold == threshold && upBalance >= thresholds[i].upHold) {
                if (thresholdReachedWithDEX[up] >= thresholds[i].userHold) {
                    upQualified = true;
                }
                break;
            }
        }
        
        if (upQualified) {
            uint256 rewardPercent;
            if (phase == 1) rewardPercent = PHASE1_REWARD_PERCENT;
            else if (phase == 2) rewardPercent = PHASE2_REWARD_PERCENT;
            else rewardPercent = PHASE3_REWARD_PERCENT;
            
            uint256 reward = threshold * rewardPercent / 100;
            emit RewardAvailable(up, user, reward, phase, threshold);
        }
    }

    // ============ 用户主动查询奖励资格 ============
    function checkMyReward() external {
        address user = msg.sender;
        address up = referrer[user];
        
        require(up != address(0), "no referrer");
        
        uint8 phase = getRewardPhase();
        require(isRewardActive(), "reward not active");
        
        bool alreadyClaimed = rewardClaimed[up][user][phase];
        (bool qualified, uint256 threshold, ) = checkHoldQualified(user);
        
        uint256 rewardAmount = 0;
        if (qualified && phase > 0) {
            uint256 rewardPercent;
            if (phase == 1) rewardPercent = PHASE1_REWARD_PERCENT;
            else if (phase == 2) rewardPercent = PHASE2_REWARD_PERCENT;
            else rewardPercent = PHASE3_REWARD_PERCENT;
            rewardAmount = threshold * rewardPercent / 100;
        }
        
        bool eligible = qualified && !alreadyClaimed && isRewardActive();
        emit RewardCheckRequested(user, phase, eligible, rewardAmount);
    }

    function checkHoldQualified(address user) public view returns (bool, uint256, uint256) {
        uint256 threshold = userCurrentThreshold[user];
        uint256 startTime = userThresholdStartTime[user];
        
        if (threshold == 0 || startTime == 0) return (false, 0, 0);
        
        uint256 endTime = startTime + HOLD_LOCK_PERIOD;
        bool qualified = block.timestamp >= endTime && balanceOf(user) >= threshold;
        
        return (qualified, threshold, endTime);
    }

    // ============ 推广奖励领取 ============
    function claimReward(address user) external nonReentrant {
        address up = msg.sender;
        require(referrer[user] == up, "not the referrer");
        require(tradingEnabled, "trading not enabled");
        
        uint8 phase = getRewardPhase();
        require(phase > 0, "reward not active");
        require(!rewardClaimed[up][user][phase], "already claimed in this phase");
        require(canParticipateCurrentPhase(user), "user cannot participate in current phase");
        
        if (userBuyPhase[user] < phase) {
            userBuyPhase[user] = phase;
        }
        
        (bool qualified, uint256 threshold, ) = checkHoldQualified(user);
        require(qualified, "hold requirement not met");
        require(thresholdReachedWithDEX[user] >= threshold, "threshold not reached via DEX");
        
        PhaseThreshold[] storage thresholds;
        if (phase == 1) thresholds = phase1Thresholds;
        else if (phase == 2) thresholds = phase2Thresholds;
        else thresholds = phase3Thresholds;
        
        uint256 upBalance = balanceOf(up);
        bool upQualified = false;
        for (uint i = 0; i < thresholds.length; i++) {
            if (thresholds[i].userHold == threshold && upBalance >= thresholds[i].upHold) {
                if (thresholdReachedWithDEX[up] >= thresholds[i].userHold) {
                    upQualified = true;
                }
                break;
            }
        }
        require(upQualified, "up hold not enough or not via DEX");
        
        uint256 rewardPercent;
        if (phase == 1) rewardPercent = PHASE1_REWARD_PERCENT;
        else if (phase == 2) rewardPercent = PHASE2_REWARD_PERCENT;
        else rewardPercent = PHASE3_REWARD_PERCENT;
        
        uint256 reward = threshold * rewardPercent / 100;
        require(balanceOf(rewardPool) >= reward, "reward pool insufficient");
        
        rewardClaimed[up][user][phase] = true;
        _transfer(rewardPool, up, reward);
        
        emit RewardClaimed(up, user, reward, phase);
    }

    // ============ 核心转账逻辑 ============
    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0), "transfer from zero");
        require(to != address(0), "transfer to zero");
        require(amount > 0, "transfer zero amount");
        
        if (!tradingEnabled) {
            super._transfer(from, to, amount);
            return;
        }

        _checkPhaseSwitch();

        bool isBuy = isAMMPair[from] && !isAMMPair[to];
        bool isSell = !isAMMPair[from] && isAMMPair[to];
        
        if (isExcludedFromFee[from] || isExcludedFromFee[to]) {
            super._transfer(from, to, amount);
            _updateUserInfo(from, to, isBuy, false);
            return;
        }

        bool shouldUpdateSeller = false;
        if (isBuy) {
            _handleBuy(from, to, amount);
        } else if (isSell) {
            shouldUpdateSeller = true;
            _handleSell(from, to, amount);
        } else {
            super._transfer(from, to, amount);
        }
        
        _updateUserInfo(from, to, isBuy, shouldUpdateSeller);
    }

    function _handleBuy(address from, address to, uint256 amount) internal {
        uint256 fee = amount * BUY_FEE / FEE_DENOMINATOR;
        uint256 receiveAmount = amount - fee;

        super._transfer(from, to, receiveAmount);
        
        if (referrer[to] != address(0) && referrerBindTime[to] > 0) {
            cumulativeDEXBuy[to] += receiveAmount;
            emit DEXBuyRecorded(to, receiveAmount, cumulativeDEXBuy[to]);
        }
        
        if (fee > 0) {
            super._transfer(from, rewardPool, fee);
            emit BuyFeeCollected(to, fee);
        }
    }

    function _handleSell(address from, address to, uint256 amount) internal nonReentrant {
        uint256 fee = amount * SELL_FEE / FEE_DENOMINATOR;
        uint256 sellAmount = amount - fee;

        super._transfer(from, address(this), fee);
        _swapFeeToBNB(fee);
        super._transfer(from, to, sellAmount);
        
        emit SellFeeCollected(from, fee);
    }

    function _swapFeeToBNB(uint256 tokenAmount) internal {
        if (tokenAmount < minSwapAmount) return;

        _approve(address(this), ROUTER, tokenAmount);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WBNB;

        uint256 minOut = 0;
        IPancakeSwapPair pair = IPancakeSwapPair(IPancakeFactory(PANCAKE_FACTORY).getPair(address(this), WBNB));
        if (pair != IPancakeSwapPair(address(0))) {
            (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
            uint256 reserveIn = address(this) == pair.token0() ? reserve0 : reserve1;
            uint256 reserveOut = address(this) == pair.token0() ? reserve1 : reserve0;
            if (reserveIn > 0 && reserveOut > 0) {
                minOut = tokenAmount * reserveOut / reserveIn * (10000 - SWAP_SLIPPAGE) / 10000;
            }
        }

        try IPancakeSwapRouter(ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            minOut,
            path,
            address(this),
            block.timestamp + 300
        ) {
            uint256 bnbBalance = address(this).balance;
            if (bnbBalance > 0) {
                uint256 to75 = bnbBalance * RATIO_75 / 100;
                uint256 to25 = bnbBalance - to75;
                
                (bool success25, ) = bnbWallet25.call{value: to25}("");
                require(success25, "BNB 25% transfer failed");
            }
        } catch {
            // 兑换失败，代币留在合约
        }
    }
    
    // ============ 手动销毁到黑洞 ============
    function burnToBlackHole(uint256 bnbAmount) external onlyOwner nonReentrant {
        require(bnbAmount > 0 && bnbAmount <= address(this).balance, "invalid amount");
        
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = address(this);
        
        uint256 minOut = 0;
        IPancakeSwapPair pair = IPancakeSwapPair(IPancakeFactory(PANCAKE_FACTORY).getPair(address(this), WBNB));
        if (pair != IPancakeSwapPair(address(0))) {
            (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
            uint256 reserveIn = WBNB == pair.token0() ? reserve0 : reserve1;
            uint256 reserveOut = WBNB == pair.token0() ? reserve1 : reserve0;
            if (reserveIn > 0 && reserveOut > 0) {
                minOut = bnbAmount * reserveOut / reserveIn * (10000 - BURN_SLIPPAGE) / 10000;
            }
        }
        
        uint256 tokenBefore = balanceOf(BLACK_HOLE);
        IPancakeSwapRouter(ROUTER).swapExactETHForTokens{value: bnbAmount}(
            minOut,
            path,
            BLACK_HOLE,
            block.timestamp + 300
        );
        uint256 tokenAfter = balanceOf(BLACK_HOLE);
        
        emit BurnToBlackHole(msg.sender, bnbAmount, tokenAfter - tokenBefore);
    }
    
    function burnTokensToBlackHole(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "amount zero");
        _transfer(msg.sender, BLACK_HOLE, amount);
        emit BurnTokensToBlackHole(msg.sender, amount, balanceOf(BLACK_HOLE));
    }
    
    function claimBNB75() external onlyOwner nonReentrant {
        uint256 bnbBalance = address(this).balance;
        require(bnbBalance > 0, "no BNB");
        (bool success, ) = bnbWallet75.call{value: bnbBalance}("");
        require(success, "BNB transfer failed");
    }

    function _updateUserInfo(address from, address to, bool isBuy, bool isSell) internal {
        uint8 rewardPhase = getRewardPhase();
        
        if (isBuy) {
            if (userFirstBuyTime[to] == 0) {
                userFirstBuyTime[to] = block.timestamp;
                userBuyPhase[to] = rewardPhase > 0 ? rewardPhase : 1;
            } else {
                if (balanceOf(to) <= 1 && rewardPhase > userBuyPhase[to]) {
                    userBuyPhase[to] = rewardPhase;
                    hasSold[to] = false;
                }
            }
            
            if (referrer[to] != address(0)) {
                _updateHoldTimer(to);
            }
        }
        
        if (isSell) {
            if (!hasSold[from]) {
                hasSold[from] = true;
            }
            
            if (referrer[from] != address(0)) {
                _updateHoldTimer(from);
            }
        }
    }

    function extractFailedSwapTokens() external onlyOwner {
        uint256 balance = balanceOf(address(this));
        require(balance > 0, "no tokens to extract");
        
        _transfer(address(this), bnbWallet25, balance);
        emit TokensExtracted(balance);
    }

    // ============ 查询功能 ============
    function getBurnedAmount() external view returns (uint256) {
        return balanceOf(BLACK_HOLE);
    }

    function getContractBNBBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getUserHoldInfo(address user) external view returns (
        uint256 currentThreshold,
        uint256 startTime,
        uint256 endTime,
        bool qualified,
        uint256 userBalance
    ) {
        currentThreshold = userCurrentThreshold[user];
        startTime = userThresholdStartTime[user];
        userBalance = balanceOf(user);
        (qualified, , endTime) = checkHoldQualified(user);
    }
    
    function getUserDEXBuyInfo(address user) external view returns (
        uint256 cumulativeBuy,
        uint256 thresholdReachedWith,
        uint256 userThreshold,
        bool qualified
    ) {
        cumulativeBuy = cumulativeDEXBuy[user];
        thresholdReachedWith = thresholdReachedWithDEX[user];
        userThreshold = userCurrentThreshold[user];
        qualified = thresholdReachedWith >= userThreshold && userThreshold > 0;
    }

    // ============ 锁仓功能 ============
    uint256 public totalLockedAmount;
    uint256 public constant MAX_LOCK_RATIO = 50;
    
    function lockMarketMakerTokens(uint256 amount, uint256 duration) external onlyOwner {
        require(amount > 0, "amount zero");
        require(amount <= balanceOf(address(this)) * MAX_LOCK_RATIO / 100, "exceed max lock ratio");
        require(duration >= MIN_LOCK_DURATION, "duration too short");
        
        _transfer(msg.sender, address(this), amount);
        
        LockInfo memory lock = LockInfo({
            amount: amount,
            startTime: block.timestamp,
            duration: duration,
            claimed: false
        });
        
        totalLockedAmount += amount;
        userLocks[msg.sender].push(lock);
        uint256 lockId = userLocks[msg.sender].length - 1;
        
        emit TokensLocked(msg.sender, amount, duration, lockId);
    }
    
    function claimLockedTokens(uint256 lockId) external nonReentrant {
        LockInfo[] storage locks = userLocks[msg.sender];
        require(lockId < locks.length, "invalid lockId");
        
        LockInfo storage lock = locks[lockId];
        require(!lock.claimed, "already claimed");
        require(block.timestamp >= lock.startTime + lock.duration, "lock not expired");
        
        lock.claimed = true;
        totalLockedAmount -= lock.amount;
        
        uint256 toReturn = lock.amount * 80 / 100;
        _transfer(address(this), msg.sender, toReturn);
        
        emit TokensUnlocked(msg.sender, toReturn, lockId);
    }
    
    function getUserLockInfo(address user) external view returns (
        uint256 totalLocked,
        uint256 totalClaimable,
        uint256 lockCount
    ) {
        LockInfo[] storage locks = userLocks[user];
        lockCount = locks.length;
        
        for (uint i = 0; i < locks.length; i++) {
            totalLocked += locks[i].amount;
            if (!locks[i].claimed && block.timestamp >= locks[i].startTime + locks[i].duration) {
                totalClaimable += locks[i].amount * 80 / 100;
            }
        }
    }

    receive() external payable {}
}
