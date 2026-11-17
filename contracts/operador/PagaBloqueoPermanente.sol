// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./IERC20.sol";

/// @title Bloqueo permanente de PAGA (remanente no vendido).
/// @notice Recibe PAGA y no tiene ninguna función para sacarlos. Camino
///         preparado para el remanente al cabo de 6 años, si se elige bloquear
///         en lugar de quemar. La decisión aún no está tomada.
contract PagaBloqueoPermanente {
    IERC20 public immutable paga;

    event Recibido(uint256 cantidad, address indexed origen);

    constructor(address paga_) {
        require(paga_ != address(0), "Token cero");
        paga = IERC20(paga_);
    }

    function disponible() external view returns (uint256) {
        return paga.balanceOf(address(this));
    }

    /// @notice Opcional: registrar un ingreso ya enviado por `transfer`.
    ///         No es necesario para que los tokens queden bloqueados.
    function registrar() external {
        emit Recibido(paga.balanceOf(address(this)), msg.sender);
    }
}
