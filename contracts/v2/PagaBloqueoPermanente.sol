// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./IERC20.sol";

/// @title PagaBloqueoPermanente (v2)
/// @notice Recibe PAGA y no tiene ninguna función para sacarlo: lo enviado aquí sale de la circulación para
///         siempre (no del supply total). Sin admin, sin funciones de escritura.
contract PagaBloqueoPermanente {
    IERC20 public immutable paga;

    error DireccionCero();

    constructor(address paga_) {
        if (paga_ == address(0)) revert DireccionCero();
        paga = IERC20(paga_);
    }

    function bloqueado() external view returns (uint256) {
        return paga.balanceOf(address(this));
    }
}
