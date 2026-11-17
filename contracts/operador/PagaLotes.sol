// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./IERC20.sol";
import {IAvisoApertura} from "./IAvisoApertura.sol";

/// @title PagaLotes — los cinco lotes de PAGA que alimentan al Operador
/// @notice Custodia 1.686.127.428 PAGA (90 % del suministro) en cinco lotes
///         inmutables. Las fechas (6 de diciembre 00:00 UTC), las cantidades
///         y el destino, una vez fijado, no se pueden cambiar.
///         - El lote 0 (adopción, 6 dic 2026, 15 %) se abre solo por fecha.
///         - Los lotes 1 a 4 solo se abren si el anterior ya se liberó y al
///           destino (lote del Operador) le queda menos de 1 PAGA. Si no, el
///           intento queda registrado y se reintenta 300 días después, y así
///           sucesivamente.
///         - `liberar(i)` puede llamarla cualquiera.
///         - El destino es el lote del Operador; el Operador nunca crea PAGA.
///         - Un lote de prueba de 500 PAGA (del 10 % restante, no de estos
///           cinco) se fondea en el mismo destino, desde el despliegue.
/// @dev Cantidades tomadas del contrato existente contracts/PagaLotes.sol,
///      que ya usaba 15/15/20/20/20 sobre el suministro real de
///      1.873.474.920 PAGA.
contract PagaLotes {
    uint256 public constant NUM_LOTES = 5;
    uint256 public constant TOTAL_BLOQUEADO = 1_686_127_428 * 10 ** 6;
    uint256 public constant ESPERA = 300 days;
    uint256 public constant AGOTADO_SI_MENOS_DE = 1 * 10 ** 6;

    IERC20 public immutable paga;
    address public immutable tesoreria;

    address public destino;
    address public operador;
    mapping(uint256 => bool) public liberado;
    mapping(uint256 => uint256) private reintento; // 0 = fecha original

    event DestinoFijado(address destino);
    event OperadorFijado(address operador);
    event LoteLiberado(
        uint256 indexed lote, uint256 cantidad, address destino, uint256 quedanEnDestino, uint256 cuando
    );
    event LoteAplazado(uint256 indexed lote, uint256 nuevoIntento, uint256 quedanEnDestino, uint256 cuando);

    constructor(address paga_, address tesoreria_) {
        require(paga_ != address(0), "Token cero");
        require(tesoreria_ != address(0), "Tesoreria cero");
        paga = IERC20(paga_);
        tesoreria = tesoreria_;
    }

    /// @notice Lote 0 = 2026 adopción (15 %), 1 = 2027 (15 %),
    ///         2 = 2028 (20 %), 3 = 2029 (20 %), 4 = 2030 (20 %).
    function lote(uint256 i) public pure returns (uint256 fecha, uint256 cantidad) {
        if (i == 0) return (1796515200, 281_021_238 * 10 ** 6); // 6 dic 2026 00:00 UTC
        if (i == 1) return (1828051200, 281_021_238 * 10 ** 6); // 6 dic 2027
        if (i == 2) return (1859673600, 374_694_984 * 10 ** 6); // 6 dic 2028
        if (i == 3) return (1891209600, 374_694_984 * 10 ** 6); // 6 dic 2029
        if (i == 4) return (1922745600, 374_694_984 * 10 ** 6); // 6 dic 2030
        revert("Lote inexistente");
    }

    function proximoIntento(uint256 i) public view returns (uint256) {
        (uint256 fecha,) = lote(i);
        uint256 r = reintento[i];
        return r == 0 ? fecha : r;
    }

    /// @notice La tesorería fija una sola vez el destino (lote del Operador).
    function fijarDestino(address d) external {
        require(msg.sender == tesoreria, "Solo la tesoreria");
        require(destino == address(0), "Destino ya fijado");
        require(d != address(0), "Direccion cero");
        destino = d;
        emit DestinoFijado(d);
    }

    /// @notice La tesorería fija una sola vez el Operador que recibe el aviso
    ///         de apertura o aplazamiento (para la revisión de garantía).
    function fijarOperador(address o) external {
        require(msg.sender == tesoreria, "Solo la tesoreria");
        require(operador == address(0), "Operador ya fijado");
        require(o != address(0), "Direccion cero");
        operador = o;
        emit OperadorFijado(o);
    }

    function liberar(uint256 i) external {
        (, uint256 cantidad) = lote(i);
        require(destino != address(0), "Falta destino");
        require(!liberado[i], "Lote ya liberado");
        uint256 cuando = proximoIntento(i);
        require(block.timestamp >= cuando, "Lote todavia bloqueado");

        if (i > 0) {
            require(liberado[i - 1], "Falta abrir el lote anterior");
            uint256 quedan = paga.balanceOf(destino);
            if (quedan >= AGOTADO_SI_MENOS_DE) {
                uint256 siguiente = cuando + ESPERA;
                while (siguiente <= block.timestamp) siguiente += ESPERA;
                reintento[i] = siguiente;
                emit LoteAplazado(i, siguiente, quedan, block.timestamp);
                _avisar(i, 0, quedan, false, siguiente);
                return;
            }
        }

        liberado[i] = true;
        require(paga.transfer(destino, cantidad), "Transferencia fallida");
        uint256 quedanDestino = paga.balanceOf(destino);
        emit LoteLiberado(i, cantidad, destino, quedanDestino, block.timestamp);
        _avisar(i, cantidad, quedanDestino, true, 0);
    }

    function _avisar(uint256 i, uint256 cantidad, uint256 quedan, bool abierto, uint256 nuevoIntento) private {
        address o = operador;
        if (o == address(0)) return;
        IAvisoApertura(o).onAperturaLote(i, cantidad, quedan, abierto, nuevoIntento);
    }
}
