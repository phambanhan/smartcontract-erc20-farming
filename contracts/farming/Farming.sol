// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract Farming is Pausable, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
     using SafeMath for uint256;
    address public feeRecipient;                // Ví nhận phí
    uint256 public feeDecimal;                  // Phí harver: số chữ số phần thập phân
    uint256 public feeRate;                     // Phí withdraw: tỉ lệ phí
                                                // Lưu ý: Nếu phí là 1.5% thì input sẽ là: feeDecimal: 1, feeRate: 15

    mapping(address => bool) private _whitelist;// Danh sách ví được thực hiện các thau tác update, insert
    
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);

    struct PoolInfo {
        IERC20 stakingToken;                    // Token tham gia farming
        IERC20 rewardToken;                     // Token trả thưởng
        uint256 totalAmount;                    // Tổng số token tham gia farming
        uint256 rewardPerSecond;                // Số token trả thưởng mỗi giây
        uint256 startTime;                      // Thời gian bắt đầu pool
        uint256 endTime;                        // Thời gian kết thúc pool
        bool isPaused;                          // Pool có đang paused hay không, khi paused thì sẽ không deposit vào được, vẫn cho withdraw, harvest
    }

    struct UserInfo {
        uint256 amount;                         // Số token user tham gia farming
        uint256 unclaimedReward;                // Số token trả thưởng chưa claim
        uint256 lastDeposit;                    // Thời gian user deposit gần nhất (để tính reward)
    }

    PoolInfo[] public poolInfo;
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    mapping (uint256 => EnumerableSet.AddressSet) private poolUsers;

    constructor(
        address _feeRecipient,
        uint256 _feeDecimal,
        uint256 _feeRate
    ) {
        require(
            _feeRecipient != address(0),
            "feeRecipient is zero address"
        );
        feeRecipient = _feeRecipient;
        feeDecimal = _feeDecimal;
        feeRate = _feeRate;
    }

    function deposit(uint256 _pid, uint256 _amount) external whenNotPaused {
        require(_amount > 0, "amount must be greater than 0");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(!pool.isPaused, "pool is paused");
        require(block.timestamp >= pool.startTime, "Can not participate");
        require(block.timestamp < pool.endTime, "Can not participate");

        if (user.amount > 0) {
            uint256 endTime = block.timestamp <= pool.endTime ? block.timestamp : pool.endTime;

            uint256 duration = endTime - user.lastDeposit;
            if(duration > 0) {
                uint256 pendingReward = _getPendingReward(pool, user);
                if (pendingReward > 0) {
                    user.unclaimedReward = user.unclaimedReward + pendingReward;
                }
            }
        }

        _updateRewardOfPool(_pid, msg.sender);

        pool.stakingToken.transferFrom(address(msg.sender), address(this), _amount);
        pool.totalAmount = pool.totalAmount + _amount;

        user.amount = user.amount + _amount;
        user.lastDeposit = block.timestamp;
        
        poolUsers[_pid].add(address(msg.sender));

        emit Deposit(msg.sender, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) public {
        require(_amount > 0, "amount must be greater than 0");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: amount exceeded");

        harvest(_pid);
        _updateRewardOfPool(_pid, msg.sender);

        user.amount = user.amount - _amount;
        pool.totalAmount = pool.totalAmount - _amount;
        pool.stakingToken.transfer(address(msg.sender), _amount);

        //remove user nếu user withdraw tất cả
        if(user.amount == 0) {
            poolUsers[_pid].remove(address(msg.sender));
            delete userInfo[_pid][msg.sender];
        }

        emit Withdraw(msg.sender, _pid, _amount);
    }

    function harvest(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 pendingReward = _getPendingReward(pool, user);
        uint256 totalReward = pendingReward.add(user.unclaimedReward);

        //tính phí harvest
        uint256 _fee = _calculateFee(totalReward, feeRate, feeDecimal);
        uint256 netAmount = totalReward - _fee;
        require(netAmount > 0, "Reward must be greater than 0");
        require(pool.rewardToken.balanceOf(address(this)) >= totalReward, "Pool is not enough to distribute reward");

        user.unclaimedReward = 0;
        pool.rewardToken.transfer(msg.sender, netAmount);

        if (_fee > 0) {
            pool.rewardToken.transfer(feeRecipient, _fee);
        }

        emit Harvest(msg.sender, _pid, totalReward);
    }

    function addPool(
        IERC20 _stakingToken,
        IERC20 _rewardToken,
        uint256 _rewardPerSecond,
        uint256 _startTime,
        uint256 _endTime
    ) public onlyWhitelister {
        poolInfo.push(
            PoolInfo({
                stakingToken: _stakingToken,
                rewardToken: _rewardToken,
                totalAmount: 0,
                rewardPerSecond: _rewardPerSecond,
                startTime: _startTime,
                endTime: _endTime,
                isPaused: false
            })
        );
    }

    function updateRewardPerSecond(uint256 _pid, uint256 _rewardPerSecond) public onlyWhitelister {
        PoolInfo storage pool = poolInfo[_pid];
        require(!pool.isPaused, "pool is paused");
        require(_rewardPerSecond > 0, "rewardPerSecond must be greater than 0");
        pool.rewardPerSecond = _rewardPerSecond;
    }

    function getUserInfo(uint256 _pid) public view returns (uint256, uint256, uint256, uint256) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo memory user = userInfo[_pid][msg.sender];
        uint256 pendingReward = _getPendingReward(pool, user);
        uint256 totalReward = pendingReward.add(user.unclaimedReward);
        return (user.amount, totalReward, user.lastDeposit, user.unclaimedReward);
    }

    function getPoolInfo(uint256 _pid) public view returns (PoolInfo memory) {
        PoolInfo memory pool = poolInfo[_pid];
        return pool;
    }

    // feeRate: 1.5. Input: amount: 1000, feeRate 15, feeDecimal 1 => fee = (15 * 1000) / 10**(1+2) = 15
    function _calculateFee(uint256 amount_, uint256 feeRate_, uint256 feeDecimal_) private pure returns (uint256) {
        if (feeRate_ == 0) {
            return 0;
        }
        return (feeRate_ * amount_) / 10**(feeDecimal_ + 2);
    }

    // Mỗi khi deposit hoặc withdraw sẽ thay đổi totalAmount của pool nên cần phải gọi hàm này để tính unclaimedReward cho tất cả user trong pool
    function _updateRewardOfPool(uint256 _pid, address _excludeAddress) private {
        PoolInfo memory pool = poolInfo[_pid];
        uint256 length = poolUsers[_pid].length();
        for (uint256 i = 0; i < length; i++) {
            address _user = poolUsers[_pid].at(i);
            if(_user == _excludeAddress) {
                continue;
            }
            UserInfo storage user = userInfo[_pid][_user];
            if (user.amount > 0) {
                uint256 pendingReward = _getPendingReward(pool, user);
                if (pendingReward > 0) {
                    user.unclaimedReward = user.unclaimedReward + pendingReward;
                }
                user.lastDeposit = block.timestamp;
            }
        }
    }

    function _getPendingReward(PoolInfo memory pool, UserInfo memory user) private view returns (uint256) {
        uint256 endTime = block.timestamp <= pool.endTime ? block.timestamp : pool.endTime;
        uint256 duration = endTime - user.lastDeposit;
        // Lãi mỗi giây = (User Deposit Amount / Total Deposit Amount) * Reward per Second
        uint256 rewardPerSecond = user.amount.mul(pool.rewardPerSecond).div(pool.totalAmount);
        uint256 pendingReward = rewardPerSecond.mul(duration);
        return pendingReward;
    }

    function setFee(uint256 _feeRate, uint256 _feeDecimal) public onlyWhitelister {
        require(_feeRate >= 0, "Invalid input");
        require(_feeDecimal >= 0, "Invalid input");
        feeRate =_feeRate;
        feeDecimal = _feeDecimal;
    }

    function setWhitelisters(address[] calldata users, bool remove)
        public
        onlyOwner
    {
        for (uint256 i = 0; i < users.length; i++) {
            _whitelist[users[i]] = !remove;
        }
    }

    modifier onlyWhitelister() {
        require(_whitelist[_msgSender()], "Not in the whitelist");
        _;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
