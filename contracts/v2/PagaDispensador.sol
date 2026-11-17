// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./IERC20.sol";
import {TransferenciaSegura} from "./TransferenciaSegura.sol";
import {IPagaOperadorVista} from "./Interfaces.sol";

/// @title PagaDispensador — 708.173.520 PAGA en dos partes separadas
/// @notice - Faucet: 1.000.000 PAGA. 0,5 PAGA una sola vez por cartera nueva, con tope diario propio
///           (días contados desde `inicio`). No cuenta en el cupo del relayer.
///         - Bots: 707.173.520 PAGA. Se entregan por intercambio cuando el relayer acredita PLS pagados
///           fuera de Pagachain; cuentan en el cupo global del relayer (lo aplica el Operador).
///         Solo el Operador inmutable puede llamar. Sin admin; la pausa del Operador detiene ambas salidas.
contract PagaDispensador {
    using TransferenciaSegura for IERC20;

    uint256 public constant ASIGNACION_FAUCET = 1_000_000 * 1e6;
    uint256 public constant ASIGNACION_BOTS = 707_173_520 * 1e6;
    uint256 public constant FAUCET_POR_CARTERA = 500_000; // 0,5 PAGA
    /// @notice Tope diario de la faucet: 5.000 PAGA (10.000 carteras nuevas al día).
    uint256 public constant FAUCET_DIARIO = 5_000 * 1e6;

    IERC20 public immutable paga;
    uint256 public immutable inicio;
    address public immutable operador;

    uint256 public entregadoFaucet;
    uint256 public entregadoBots;
    mapping(address => bool) public recibioFaucet;
    mapping(uint256 => uint256) public faucetPorDia;

    event Faucet(address indexed cartera, uint256 cantidad);
    event EntregaBots(address indexed destino, uint256 cantidad);

    error DireccionCero();
    error ConfiguracionInvalida();
    error SoloOperador();
    error YaRecibio();
    error TopeDiarioFaucet();
    error FaucetAgotada();
    error SinDisponible();

    modifier soloOperador() {
        if (msg.sender != operador) revert SoloOperador();
        _;
    }

    constructor(address paga_, uint256 inicio_, address operador_) {
        if (paga_ == address(0) || operador_ == address(0)) revert DireccionCero();
        if (IPagaOperadorVista(operador_).inicio() != inicio_) revert ConfiguracionInvalida();
        if (IPagaOperadorVista(operador_).paga() != paga_) revert ConfiguracionInvalida();
        paga = IERC20(paga_);
        inicio = inicio_;
        operador = operador_;
    }

    function diaActual() public view returns (uint256) {
        return (block.timestamp - inicio) / 1 days;
    }

    /// @notice PAGA de bots entregable ahora: no invade lo que queda de la faucet. Nunca revierte.
    function disponibleBots() public view returns (uint256) {
        uint256 restante = ASIGNACION_BOTS - entregadoBots;
        uint256 saldo = paga.balanceOf(address(this));
        uint256 faucetRestante = ASIGNACION_FAUCET - entregadoFaucet;
        uint256 libre = saldo > faucetRestante ? saldo - faucetRestante : 0;
        return restante < libre ? restante : libre;
    }

    function entregarFaucet(address cartera) external soloOperador {
        if (cartera == address(0)) revert DireccionCero();
        if (recibioFaucet[cartera]) revert YaRecibio();
        if (entregadoFaucet + FAUCET_POR_CARTERA > ASIGNACION_FAUCET) revert FaucetAgotada();
        uint256 dia = diaActual();
        if (faucetPorDia[dia] + FAUCET_POR_CARTERA > FAUCET_DIARIO) revert TopeDiarioFaucet();
        recibioFaucet[cartera] = true;
        faucetPorDia[dia] += FAUCET_POR_CARTERA;
        entregadoFaucet += FAUCET_POR_CARTERA;
        paga.enviar(cartera, FAUCET_POR_CARTERA);
        emit Faucet(cartera, FAUCET_POR_CARTERA);
    }

    function entregarBots(address destino, uint256 cantidad) external soloOperador {
        if (cantidad == 0 || cantidad > disponibleBots()) revert SinDisponible();
        entregadoBots += cantidad;
        paga.enviar(destino, cantidad);
        emit EntregaBots(destino, cantidad);
    }
}
