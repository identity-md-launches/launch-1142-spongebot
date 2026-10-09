// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice An ERC-20 whose transfer functions can be made to return nothing (USDT style) or return false, to test
/// the vault's tolerant transfer wrappers. Anyone may mint.
contract QuirkyERC20 {
    enum Mode {
        Normal,
        NoReturn,
        ReturnFalse
    }

    Mode public mode;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
        _return();
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        _return();
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    /// @dev Returns `true`, nothing, or `false` depending on the mode. Written in assembly so one function body can
    /// return different ABI shapes.
    function _return() internal view {
        Mode m = mode;
        if (m == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        bool value = m == Mode.Normal;
        assembly ("memory-safe") {
            mstore(0, value)
            return(0, 32)
        }
    }
}
