// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract Staking {
    // Time constants
    uint256 private constant ONE_DAY = 86400;
    uint256 private constant ONE_WEEK = 604800;

    // State variables
    IERC20 public immutable token;
    address public owner;
    
    mapping(address => uint256) public stakedAmount;
    mapping(address => uint256) public stakingStartTime;
    mapping(address => bool) public hasClaimedInterest;
    
    // Reentrancy guard
    bool private locked;

    // Events
    event Staked(address indexed user, uint256 amount);
    event Redeemed(address indexed user, uint256 amount);
    event InterestClaimed(address indexed user, uint256 interest);
    event Swept(address indexed owner, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "Staking: caller is not the owner");
        _;
    }

    modifier nonReentrant() {
        require(!locked, "Staking: reentrant call");
        locked = true;
        _;
        locked = false;
    }

    constructor(address _token) {
        require(_token != address(0), "Staking: invalid token address");
        token = IERC20(_token);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /**
     * @notice Allows users to stake their tokens
     * @param amount The amount of tokens to stake
     * @dev If user already has a staked balance, transfers accumulated rewards 
     *      and staked tokens before adding the new deposit
     */
    function stake(uint256 amount) public nonReentrant {
        require(amount > 0, "Staking: amount must be greater than zero");
        
        address user = msg.sender;
        uint256 currentStake = stakedAmount[user];
        
        // If user has existing stake, handle it first
        if (currentStake > 0) {
            // Calculate and transfer accumulated rewards if not already claimed
            if (!hasClaimedInterest[user]) {
                uint256 interest = _calculateInterest(user);
                if (interest > 0) {
                    require(
                        token.transfer(user, interest),
                        "Staking: interest transfer failed"
                    );
                    emit InterestClaimed(user, interest);
                }
            }
            
            // Transfer existing staked tokens back to user
            require(
                token.transfer(user, currentStake),
                "Staking: stake return transfer failed"
            );
            emit Redeemed(user, currentStake);
            
            // Reset staking state
            stakedAmount[user] = 0;
            stakingStartTime[user] = 0;
            hasClaimedInterest[user] = false;
        }
        
        // Transfer new tokens from user to contract
        require(
            token.transferFrom(user, address(this), amount),
            "Staking: token transfer failed"
        );
        
        // Update staking state
        stakedAmount[user] = amount;
        stakingStartTime[user] = block.timestamp;
        hasClaimedInterest[user] = false;
        
        emit Staked(user, amount);
    }

    /**
     * @notice Allows stakers to redeem their staked tokens
     * @param amount The amount of tokens to redeem
     * @dev If user redeems before claiming interest, no interest is paid
     */
    function redeem(uint256 amount) public nonReentrant {
        require(amount > 0, "Staking: amount must be greater than zero");
        
        address user = msg.sender;
        uint256 currentStake = stakedAmount[user];
        
        require(amount <= currentStake, "Staking: insufficient staked balance");
        
        // If user redeems before claiming interest, they forfeit all interest
        // Mark as claimed to prevent future interest claims
        if (!hasClaimedInterest[user]) {
            hasClaimedInterest[user] = true;
        }
        
        // Update staked amount
        stakedAmount[user] = currentStake - amount;
        
        // If all tokens are redeemed, reset staking state
        if (stakedAmount[user] == 0) {
            stakingStartTime[user] = 0;
        }
        
        // Transfer tokens to user
        require(
            token.transfer(user, amount),
            "Staking: redemption transfer failed"
        );
        
        emit Redeemed(user, amount);
    }

    /**
     * @notice Transfers the rewards to the staker
     * @dev Reverts if no interest is due or if interest was already claimed
     */
    function claimInterest() public nonReentrant {
        address user = msg.sender;
        uint256 currentStake = stakedAmount[user];
        
        require(currentStake > 0, "Staking: no staked balance");
        require(!hasClaimedInterest[user], "Staking: interest already claimed");
        
        uint256 interest = _calculateInterest(user);
        require(interest > 0, "Staking: no interest due");
        
        // Mark interest as claimed
        hasClaimedInterest[user] = true;
        
        // Transfer interest to user
        require(
            token.transfer(user, interest),
            "Staking: interest transfer failed"
        );
        
        emit InterestClaimed(user, interest);
    }

    /**
     * @notice Returns the accrued interest for a user
     * @param user The address of the user
     * @return The amount of accrued interest
     */
    function getAccruedInterest(address user) public view returns (uint256) {
        if (stakedAmount[user] == 0 || hasClaimedInterest[user]) {
            return 0;
        }
        return _calculateInterest(user);
    }

    /**
     * @notice Allows the owner to withdraw all staked tokens
     * @dev Only owner can call this function
     */
    function sweep() public onlyOwner nonReentrant {
        
    }

    /**
     * @notice Transfers ownership of the contract to a new account
     * @param newOwner The address of the new owner
     */
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Staking: new owner is the zero address");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /**
     * @notice Internal function to calculate interest based on staking duration
     * @param user The address of the user
     * @return The calculated interest amount
     */
    function _calculateInterest(address user) private view returns (uint256) {
        uint256 stakeAmount = stakedAmount[user];
        if (stakeAmount == 0) {
            return 0;
        }
        
        uint256 startTime = stakingStartTime[user];
        if (startTime == 0) {
            return 0;
        }
        
        uint256 timeElapsed = block.timestamp - startTime;
        
        // Less than 1 day: no rewards
        if (timeElapsed < ONE_DAY) {
            return 0;
        }
        // More than 1 day but less than 1 week: 1% reward
        else if (timeElapsed < ONE_WEEK) {
            return stakeAmount / 100; // 1%
        }
        // More than 1 week: 10% reward
        else {
            return stakeAmount * 10 / 100; // 10%
        }
    }
}
