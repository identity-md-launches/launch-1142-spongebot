// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title SpongeBot launch token
/// @notice Fixed-supply ERC-20: 1,000,000,000 SPONGEBOT (18 decimals) minted once to the deployer.
/// @dev No owner, no mint, no burn, no pause, no fees, no upgrade path. Swap fees live in the hook.
contract SPONGEBOT {
    string public constant name = "SpongeBot";
    string public constant symbol = "SPONGEBOT";
    uint8 public constant decimals = 18;

    /// @notice The whole supply, minted to the deployer in the constructor.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    uint256 public immutable totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance();
    error InsufficientAllowance();
    error TransferToZeroAddress();

    constructor() {
        totalSupply = TOTAL_SUPPLY;
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert TransferToZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = fromBalance - amount;
            // Supply is fixed, so the sum of balances cannot exceed TOTAL_SUPPLY and this cannot overflow.
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
