// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title PagaTiempo — regla de frontera única para todos los contratos PAGA v2
/// @notice Todos los plazos se cuentan en días de 86.400 s desde un único `inicio` (START), argumento
///         inmutable idéntico en todos los contratos. Regla exacta: el día N está "alcanzado" si y solo si
///         `block.timestamp >= inicio + N * 1 days`. Un evento en el segundo exacto `inicio + N días`
///         ya pertenece al periodo posterior.
library PagaTiempo {
    /// @notice Día 730: cambio de precio (0,10 → 0,20 USD) y cierre de la cuenta de fundadoras.
    uint256 internal constant DIA_730 = 730;

    function momento(uint256 inicio, uint256 dia) internal pure returns (uint256) {
        return inicio + dia * 1 days;
    }

    function alcanzado(uint256 inicio, uint256 dia) internal view returns (bool) {
        return block.timestamp >= momento(inicio, dia);
    }
}
