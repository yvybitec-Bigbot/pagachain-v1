// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Vista del Operador que usan lotes, fundadoras y dispensador (solo lecturas de su propio almacenamiento).
interface IPagaOperadorVista {
    function paga() external view returns (address);
    function inicio() external view returns (uint256);
    function cuentaCerrada() external view returns (bool);
    function totalRecompensas() external view returns (uint256);
    function recompensa(address cartera) external view returns (uint256);
}

interface IPagaLote {
    function paga() external view returns (address);
    function operador() external view returns (address);
    function bloqueo() external view returns (address);
    function inicio() external view returns (uint256);
    function disponibleIntercambio() external view returns (uint256);
    function entregar(address destino, uint256 cantidad) external;
}

interface IPagaLoteImplementacion {
    function fundadoras() external view returns (address);
}

interface IPagaDispensador {
    function paga() external view returns (address);
    function operador() external view returns (address);
    function inicio() external view returns (uint256);
    function disponibleBots() external view returns (uint256);
    function entregarBots(address destino, uint256 cantidad) external;
    function entregarFaucet(address cartera) external;
}

interface IPagaFundadoras {
    function paga() external view returns (address);
    function operador() external view returns (address);
    function bloqueo() external view returns (address);
    function activar() external;
}

interface IPagaBloqueo {
    function paga() external view returns (address);
}
