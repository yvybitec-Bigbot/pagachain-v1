// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./IERC20.sol";
import {TransferenciaSegura} from "./TransferenciaSegura.sol";
import {Guardia} from "./Guardia.sol";
import {IPagaOperadorVista, IPagaBloqueo} from "./Interfaces.sol";

/// @title PagaFundadoras — recompensa de las 369 carteras fundadoras
/// @notice Los registros (quién es fundadora y cuánto cuenta) los guarda el Operador; aquí solo se leen.
///         - `activar`: cualquiera, cuando la cuenta está cerrada y el saldo es >= total debido (nunca igualdad
///           exacta). Fija el total y el momento del fondeo; el plazo de reclamo es de 1 año desde ahí.
///         - `reclamar`: cada cartera reclama SU parte (2 × compras con tope de 200.000 PAGA), una sola vez,
///           dentro de [fondeo, fondeo + 365 días).
///         - `barrer`: cualquiera, desde fondeo + 365 días, envía todo lo que quede a PagaBloqueoPermanente.
///         Sin admin y sin pausa: reclamos y barrido funcionan siempre.
contract PagaFundadoras is Guardia {
    using TransferenciaSegura for IERC20;

    uint256 public constant PLAZO_RECLAMO = 365 days;

    IERC20 public immutable paga;
    address public immutable operador;
    address public immutable bloqueo;

    bool public activo;
    uint256 public fondeadoEn;
    uint256 public totalFijado;
    uint256 public totalReclamado;
    mapping(address => bool) public reclamado;

    event ReclamosActivados(uint256 total, uint256 cuando);
    event Reclamado(address indexed cartera, uint256 cantidad);
    event Barrido(uint256 cantidad);

    error DireccionCero();
    error ConfiguracionInvalida();
    error YaActivo();
    error CuentaAbierta();
    error SinFondos();
    error PlazoCerrado();
    error PlazoAbierto();
    error YaReclamado();
    error SinRecompensa();
    error NoActivo();
    error NadaQueBarrer();

    constructor(address paga_, address operador_, address bloqueo_) {
        if (paga_ == address(0) || operador_ == address(0) || bloqueo_ == address(0)) revert DireccionCero();
        if (IPagaOperadorVista(operador_).paga() != paga_) revert ConfiguracionInvalida();
        if (IPagaBloqueo(bloqueo_).paga() != paga_) revert ConfiguracionInvalida();
        paga = IERC20(paga_);
        operador = operador_;
        bloqueo = bloqueo_;
    }

    function activar() external noReentrada {
        _activar();
    }

    function reclamar() external noReentrada returns (uint256 cantidad) {
        if (!activo) _activar();
        if (block.timestamp >= fondeadoEn + PLAZO_RECLAMO) revert PlazoCerrado();
        if (reclamado[msg.sender]) revert YaReclamado();
        cantidad = IPagaOperadorVista(operador).recompensa(msg.sender);
        if (cantidad == 0) revert SinRecompensa();
        reclamado[msg.sender] = true;
        totalReclamado += cantidad;
        paga.enviar(msg.sender, cantidad);
        emit Reclamado(msg.sender, cantidad);
    }

    function barrer() external noReentrada {
        if (!activo) revert NoActivo();
        if (block.timestamp < fondeadoEn + PLAZO_RECLAMO) revert PlazoAbierto();
        uint256 saldo = paga.balanceOf(address(this));
        if (saldo == 0) revert NadaQueBarrer();
        paga.enviar(bloqueo, saldo);
        emit Barrido(saldo);
    }

    function _activar() private {
        if (activo) revert YaActivo();
        IPagaOperadorVista op = IPagaOperadorVista(operador);
        if (!op.cuentaCerrada()) revert CuentaAbierta();
        uint256 total = op.totalRecompensas();
        if (paga.balanceOf(address(this)) < total) revert SinFondos();
        activo = true;
        fondeadoEn = block.timestamp;
        totalFijado = total;
        emit ReclamosActivados(total, block.timestamp);
    }
}
