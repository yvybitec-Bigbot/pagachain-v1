// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PAGA - token de la L3 Paga (chain 3690369)
/// @notice ERC-20 simple, 6 decimales, suministro fijo acuñado una sola vez al desplegar.
///         Sin funciones de mint posteriores, sin owner, sin pausas.
contract Paga {
    string public constant name = "Paga";
    string public constant symbol = "PAGA";
    uint8 public constant decimals = 6;

    // 2.628.000.000 DOGE x $0,071289 / $0,10 = 1.873.474.920 PAGA (precio DOGE 8 nov 2026, 16:22 Londres)
    uint256 public constant totalSupply = 1_873_474_920 * 10 ** 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= value, "PAGA: allowance");
            allowance[from][msg.sender] = allowed - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(to != address(0), "PAGA: to zero");
        uint256 bal = balanceOf[from];
        require(bal >= value, "PAGA: balance");
        unchecked {
            balanceOf[from] = bal - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }
}
