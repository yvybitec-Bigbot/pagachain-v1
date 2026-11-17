// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title PausaLimitada — pausa de como máximo 5 días que se levanta sola
/// @notice El admin (inmutable; la multisig 2 de 3 al desplegar) puede pausar como máximo 5 días. La pausa
///         termina sola al cumplirse el plazo, o antes si el admin la levanta. Tras terminar, hay un
///         enfriamiento de 5 días antes de poder volver a pausar.
abstract contract PausaLimitada {
    uint256 public constant DURACION_MAX_PAUSA = 5 days;
    uint256 public constant ENFRIAMIENTO_PAUSA = 5 days;

    /// @notice Administrador inmutable. No hay transferencia de admin.
    address public immutable admin;
    /// @notice Final (exclusivo) de la última pausa. Pausado si `block.timestamp < pausaFin`.
    uint256 public pausaFin;

    event Pausado(uint256 hasta);
    event Reanudado(uint256 cuando);

    error SoloAdmin();
    error EnPausa();
    error NoPausado();
    error EnEnfriamiento();
    error DireccionCero();

    modifier soloAdmin() {
        if (msg.sender != admin) revert SoloAdmin();
        _;
    }

    modifier cuandoActivo() {
        if (pausado()) revert EnPausa();
        _;
    }

    constructor(address admin_) {
        if (admin_ == address(0)) revert DireccionCero();
        admin = admin_;
    }

    function pausado() public view returns (bool) {
        return block.timestamp < pausaFin;
    }

    function pausar() public virtual soloAdmin {
        if (pausado()) revert EnPausa();
        if (pausaFin != 0 && block.timestamp < pausaFin + ENFRIAMIENTO_PAUSA) revert EnEnfriamiento();
        pausaFin = block.timestamp + DURACION_MAX_PAUSA;
        emit Pausado(pausaFin);
    }

    function reanudar() external soloAdmin {
        if (!pausado()) revert NoPausado();
        pausaFin = block.timestamp;
        emit Reanudado(block.timestamp);
    }
}
