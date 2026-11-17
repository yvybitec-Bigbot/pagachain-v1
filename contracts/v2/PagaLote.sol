// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./IERC20.sol";
import {TransferenciaSegura} from "./TransferenciaSegura.sol";
import {PagaTiempo} from "./PagaTiempo.sol";
import {PausaLimitada} from "./PausaLimitada.sol";
import {Guardia} from "./Guardia.sol";
import {IPagaOperadorVista, IPagaBloqueo} from "./Interfaces.sol";

/// @title PagaLote — lote de PAGA con ventana de intercambio fija (base)
/// @notice Reglas:
///         - Se abre SOLO por tiempo, dentro de su ventana [diaApertura, diaCierre + extensión por pausa), y
///           solo si está fondeado: saldo + salidas ya contabilizadas >= asignación (nunca igualdad exacta).
///           Las salidas propias no lo "desfondean"; una donación de polvo no lo bloquea.
///         - Solo el Operador (inmutable) retira PAGA, y como máximo el límite de intercambio.
///         - Tras la ventana, cualquiera puede `barrer`: el sobrante (incluido cualquier exceso donado) va solo
///           a PagaBloqueoPermanente (inmutable). Funciona aunque haya pausa.
///         - La pausa (máx. 5 días) solo alarga la ventana por el tiempo de pausa que cae dentro de ella.
///         - Admin (inmutable): solo `pausar` y `reanudar`. No hay rescate ni cambio de direcciones.
abstract contract PagaLote is PausaLimitada, Guardia {
    using TransferenciaSegura for IERC20;

    IERC20 public immutable paga;
    uint256 public immutable inicio;
    address public immutable operador;
    address public immutable bloqueo;
    uint256 public immutable asignacion;
    uint256 public immutable diaApertura;
    uint256 public immutable diaCierre;

    /// @notice PAGA entregado por intercambios a través del Operador.
    uint256 public intercambiado;
    /// @notice PAGA enviado a PagaBloqueoPermanente por `barrer`.
    uint256 public barrido;
    /// @notice Segundos de pausa ya contabilizados que alargan la ventana.
    uint256 public extensionAcumulada;
    /// @dev Desde cuándo cuenta la última pausa para la extensión (0 = no cuenta).
    uint256 private _cuentaDesde;

    event EntregaIntercambio(address indexed destino, uint256 cantidad);
    event Barrido(uint256 cantidad);

    error FueraDeVentana();
    error NoFondeado();
    error SoloOperador();
    error SinLimite();
    error CantidadCero();
    error VentanaNoTerminada();
    error NadaQueBarrer();
    error ConfiguracionInvalida();

    constructor(
        address admin_,
        address paga_,
        uint256 inicio_,
        address operador_,
        address bloqueo_,
        uint256 asignacion_,
        uint256 diaApertura_,
        uint256 diaCierre_
    ) PausaLimitada(admin_) {
        if (paga_ == address(0) || operador_ == address(0) || bloqueo_ == address(0)) revert DireccionCero();
        if (IPagaOperadorVista(operador_).inicio() != inicio_) revert ConfiguracionInvalida();
        if (IPagaOperadorVista(operador_).paga() != paga_) revert ConfiguracionInvalida();
        if (IPagaBloqueo(bloqueo_).paga() != paga_) revert ConfiguracionInvalida();
        paga = IERC20(paga_);
        inicio = inicio_;
        operador = operador_;
        bloqueo = bloqueo_;
        asignacion = asignacion_;
        diaApertura = diaApertura_;
        diaCierre = diaCierre_;
    }

    // ------------------------------------------------------------------ vistas

    function aperturaVentana() public view returns (uint256) {
        return PagaTiempo.momento(inicio, diaApertura);
    }

    /// @notice Final (exclusivo) de la ventana, incluida la extensión por pausas dentro de ella.
    function finVentana() public view returns (uint256) {
        return PagaTiempo.momento(inicio, diaCierre) + extensionAcumulada + _solapeUltimaPausa();
    }

    function enVentana() public view returns (bool) {
        return block.timestamp >= aperturaVentana() && block.timestamp < finVentana();
    }

    /// @notice Saldo + salidas contabilizadas >= asignación. También sirve de consulta antes de fondear.
    function fondeado() public view returns (bool) {
        return paga.balanceOf(address(this)) + _salidas() >= asignacion;
    }

    /// @notice Máximo total que este lote puede entregar por intercambio.
    function limiteIntercambio() public view returns (uint256) {
        return _limiteIntercambio();
    }

    /// @notice PAGA que el Operador puede retirar ahora mismo. Nunca revierte.
    function disponibleIntercambio() external view returns (uint256) {
        if (pausado() || !enVentana() || !fondeado()) return 0;
        return _limiteIntercambio() - intercambiado;
    }

    // --------------------------------------------------------------- acciones

    /// @notice Entrega PAGA de intercambio. Solo el Operador inmutable.
    function entregar(address destino, uint256 cantidad) external cuandoActivo noReentrada {
        if (msg.sender != operador) revert SoloOperador();
        if (!enVentana()) revert FueraDeVentana();
        if (cantidad == 0) revert CantidadCero();
        if (!fondeado()) revert NoFondeado();
        if (intercambiado + cantidad > _limiteIntercambio()) revert SinLimite();
        intercambiado += cantidad;
        paga.enviar(destino, cantidad);
        emit EntregaIntercambio(destino, cantidad);
    }

    /// @notice Tras la ventana, cualquiera envía el sobrante (salvo lo retenido) a PagaBloqueoPermanente.
    ///         Funciona aunque haya pausa. Se puede repetir si llegan más donaciones.
    function barrer() external noReentrada {
        if (block.timestamp < finVentana()) revert VentanaNoTerminada();
        uint256 saldo = paga.balanceOf(address(this));
        uint256 retenido = _retenido();
        if (saldo <= retenido) revert NadaQueBarrer();
        uint256 cantidad = saldo - retenido;
        barrido += cantidad;
        paga.enviar(bloqueo, cantidad);
        emit Barrido(cantidad);
    }

    /// @notice Pausa: antes contabiliza la pausa anterior y, si la ventana no ha terminado, marca desde
    ///         cuándo cuenta esta (desde ahora o desde la apertura, lo que sea posterior).
    function pausar() public override {
        extensionAcumulada += _solapeUltimaPausa();
        _cuentaDesde = 0;
        super.pausar();
        if (block.timestamp < finVentana()) {
            uint256 ap = aperturaVentana();
            _cuentaDesde = block.timestamp > ap ? block.timestamp : ap;
        }
    }

    // -------------------------------------------------------------- internos

    function _solapeUltimaPausa() private view returns (uint256) {
        uint256 desde = _cuentaDesde;
        if (desde == 0) return 0;
        uint256 hasta = pausaFin < block.timestamp ? pausaFin : block.timestamp;
        return hasta > desde ? hasta - desde : 0;
    }

    /// @dev PAGA que ya salió del lote por sus vías propias.
    function _salidas() internal view virtual returns (uint256) {
        return intercambiado + barrido;
    }

    /// @dev PAGA que `barrer` no puede tocar.
    function _retenido() internal view virtual returns (uint256) {
        return 0;
    }

    /// @dev Total intercambiable.
    function _limiteIntercambio() internal view virtual returns (uint256) {
        return asignacion;
    }
}
