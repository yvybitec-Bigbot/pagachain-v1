// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Aviso de apertura o aplazamiento de un lote, para el Operador.
interface IAvisoApertura {
    /// @param indice Índice del lote (0 = adopción 2026 … 4 = 2030).
    /// @param cantidad PAGA del lote, si se abre; 0 en un aplazamiento.
    /// @param quedanEnDestino Saldo de PAGA en el destino (lote del Operador).
    /// @param abierto True si el lote se liberó; false si se aplazó.
    /// @param nuevoIntento Nueva fecha de reintento (0 si se abrió).
    function onAperturaLote(
        uint256 indice,
        uint256 cantidad,
        uint256 quedanEnDestino,
        bool abierto,
        uint256 nuevoIntento
    ) external;
}
