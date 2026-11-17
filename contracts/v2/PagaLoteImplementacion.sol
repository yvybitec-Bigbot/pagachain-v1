// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./IERC20.sol";
import {TransferenciaSegura} from "./TransferenciaSegura.sol";
import {PagaTiempo} from "./PagaTiempo.sol";
import {PagaLote} from "./PagaLote.sol";
import {IPagaOperadorVista, IPagaFundadoras} from "./Interfaces.sol";

/// @title PagaLoteImplementacion — 674.450.971 PAGA, ventana día 730 – día 1030
/// @notice Reserva 147.600.000 PAGA para las fundadoras desde el despliegue: intercambiable =
///         674.450.971 − 147.600.000 = 526.850.971 PAGA. Tercera salida, una sola vez, llamable por cualquiera
///         desde el día 730: envía exactamente lo debido (valor fijado al cierre de la cuenta en el Operador,
///         máx. 147.600.000) al contrato de fundadoras inmutable. Lo no usado de la reserva pasa a ser
///         intercambiable a través del Operador. `barrer` no toca la reserva mientras el pago esté pendiente.
///         Invariante: intercambiado + enviadoFundadoras + barrido = asignación (+ exceso donado, al bloqueo).
contract PagaLoteImplementacion is PagaLote {
    using TransferenciaSegura for IERC20;

    uint256 public constant ASIGNACION_IMPLEMENTACION = 674_450_971 * 1e6;
    uint256 public constant RESERVA_FUNDADORAS = 147_600_000 * 1e6;

    address public immutable fundadoras;

    bool public pagoFundadorasHecho;
    uint256 public enviadoFundadoras;

    event PagoFundadoras(uint256 cantidad, uint256 reservaLiberada);

    error PagoYaHecho();
    error CuentaAbierta();
    error SaldoInsuficiente();

    constructor(address admin_, address paga_, uint256 inicio_, address operador_, address bloqueo_, address fundadoras_)
        PagaLote(admin_, paga_, inicio_, operador_, bloqueo_, ASIGNACION_IMPLEMENTACION, PagaTiempo.DIA_730, 1030)
    {
        if (fundadoras_ == address(0)) revert DireccionCero();
        if (IPagaFundadoras(fundadoras_).operador() != operador_) revert ConfiguracionInvalida();
        if (IPagaFundadoras(fundadoras_).paga() != paga_) revert ConfiguracionInvalida();
        if (IPagaFundadoras(fundadoras_).bloqueo() != bloqueo_) revert ConfiguracionInvalida();
        fundadoras = fundadoras_;
    }

    /// @notice Paga a las fundadoras. Una sola vez, cualquiera, desde el día 730, también en pausa.
    ///         Total cero: se marca como hecho sin revertir. Después intenta activar los reclamos sin
    ///         bloquear nada si esa llamada falla.
    function pagarFundadoras() external noReentrada {
        if (pagoFundadorasHecho) revert PagoYaHecho();
        if (!PagaTiempo.alcanzado(inicio, PagaTiempo.DIA_730)) revert FueraDeVentana();
        IPagaOperadorVista op = IPagaOperadorVista(operador);
        if (!op.cuentaCerrada()) revert CuentaAbierta();
        uint256 debido = op.totalRecompensas();
        if (debido > RESERVA_FUNDADORAS) debido = RESERVA_FUNDADORAS;
        if (paga.balanceOf(address(this)) < debido) revert SaldoInsuficiente();

        pagoFundadorasHecho = true;
        enviadoFundadoras = debido;
        if (debido > 0) paga.enviar(fundadoras, debido);
        emit PagoFundadoras(debido, RESERVA_FUNDADORAS - debido);

        try IPagaFundadoras(fundadoras).activar() {} catch {}
    }

    function _salidas() internal view override returns (uint256) {
        return intercambiado + barrido + enviadoFundadoras;
    }

    function _retenido() internal view override returns (uint256) {
        return pagoFundadorasHecho ? 0 : RESERVA_FUNDADORAS;
    }

    function _limiteIntercambio() internal view override returns (uint256) {
        uint256 base = ASIGNACION_IMPLEMENTACION - RESERVA_FUNDADORAS;
        return pagoFundadorasHecho ? base + (RESERVA_FUNDADORAS - enviadoFundadoras) : base;
    }
}
