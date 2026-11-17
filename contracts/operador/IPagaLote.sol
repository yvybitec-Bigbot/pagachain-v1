// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./IERC20.sol";

/// @title IPagaLote — interfaz estándar de un lote bloqueado de PAGA
/// @notice Pieza reutilizable para Pagachain y para próximas L3: cada lote se
///         crea por separado, se fondea o recarga enviando PAGA (sin tope ni
///         cantidad fija) y solo entrega a través del contrato autorizado.
interface IPagaLote {
    function paga() external view returns (IERC20);
    function autorizado() external view returns (address);
    function disponible() external view returns (uint256);
    function entregar(address destino, uint256 cantidad) external returns (bool);
}
