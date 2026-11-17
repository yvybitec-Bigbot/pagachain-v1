// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AVISO (10 nov 2026): este archivo quedó sustituido, en el trabajo local, por
// operador/src/PagaLotes.sol. Los cinco lotes van al lote del Operador (destino
// inmutable). Fechas adelantadas a 6 dic 2026–2030. No se ha desplegado
// ninguna de las dos versiones.

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @title PagaLotes - bloqueo de los lotes de PAGA en la L3 Paga (chain 3690369)
/// @notice Guarda los 5 lotes futuros de PAGA (1.686.127.428 PAGA).
///  - Cada lote se puede abrir a partir del 6 de diciembre de su año (00:00 UTC).
///  - El lote 2028 se abre solo por fecha.
///  - Los lotes 2029 a 2032 además exigen que el lote anterior esté agotado, es decir,
///    que al contrato de venta le quede menos de 1 PAGA. Si no está agotado, el intento
///    queda registrado y el siguiente intento es 300 días después, y así sucesivamente.
///  - Los lotes van siempre al contrato de venta, cuya dirección la tesorería fija una
///    sola vez. Después nadie puede cambiarla.
///  - No hay forma de sacar tokens fuera de estas reglas, ni de cambiar fechas o cantidades.
///  - Abrir un lote requiere que alguien llame a liberar(i); puede hacerlo cualquiera.
contract PagaLotes {
    IERC20 public constant PAGA = IERC20(0xbfE1D53cb99f5873E3d62EfaAc4F7d0cC2f94b9A);
    address public constant TESORERIA = 0xF34F8d4eF363858cA5979eA41DF1b3580bb765ED;

    uint256 public constant NUM_LOTES = 5;
    uint256 public constant TOTAL_BLOQUEADO = 1_686_127_428 * 10 ** 6;
    uint256 public constant ESPERA = 300 days;
    uint256 public constant AGOTADO_SI_MENOS_DE = 1 * 10 ** 6; // 1 PAGA

    address public ventas; // contrato de venta, se fija una sola vez
    mapping(uint256 => bool) public liberado;
    mapping(uint256 => uint256) private reintento; // 0 = usar la fecha original

    event VentasFijado(address ventas);
    event LoteLiberado(uint256 indexed lote, uint256 cantidad, address destino);
    event LoteAplazado(uint256 indexed lote, uint256 nuevoIntento, uint256 quedanEnVenta);

    /// @notice Lote 0 = 2028 (15%), 1 = 2029 (15%), 2 = 2030 (20%), 3 = 2031 (20%), 4 = final 2032 (20%)
    function lote(uint256 i) public pure returns (uint256 fecha, uint256 cantidad) {
        if (i == 0) return (1859673600, 281_021_238 * 10 ** 6); // 6 dic 2028
        if (i == 1) return (1891209600, 281_021_238 * 10 ** 6); // 6 dic 2029
        if (i == 2) return (1922745600, 374_694_984 * 10 ** 6); // 6 dic 2030
        if (i == 3) return (1954281600, 374_694_984 * 10 ** 6); // 6 dic 2031
        if (i == 4) return (1985904000, 374_694_984 * 10 ** 6); // 6 dic 2032
        revert("Lote inexistente");
    }

    /// @notice Fecha a partir de la cual se puede intentar abrir el lote i
    function proximoIntento(uint256 i) public view returns (uint256) {
        (uint256 fecha, ) = lote(i);
        uint256 r = reintento[i];
        return r == 0 ? fecha : r;
    }

    /// @notice La tesorería fija una única vez la dirección del contrato de venta
    function fijarVentas(address v) external {
        require(msg.sender == TESORERIA, "Solo la tesoreria");
        require(ventas == address(0), "Ventas ya fijado");
        require(v != address(0), "Direccion cero");
        ventas = v;
        emit VentasFijado(v);
    }

    function liberar(uint256 i) external {
        (, uint256 cantidad) = lote(i);
        require(ventas != address(0), "Falta contrato de venta");
        require(!liberado[i], "Lote ya liberado");
        uint256 cuando = proximoIntento(i);
        require(block.timestamp >= cuando, "Lote todavia bloqueado");

        if (i > 0) {
            require(liberado[i - 1], "Falta abrir el lote anterior");
            uint256 quedan = PAGA.balanceOf(ventas);
            if (quedan >= AGOTADO_SI_MENOS_DE) {
                // Lote anterior sin agotar: siguiente intento 300 dias despues
                uint256 siguiente = cuando + ESPERA;
                while (siguiente <= block.timestamp) siguiente += ESPERA;
                reintento[i] = siguiente;
                emit LoteAplazado(i, siguiente, quedan);
                return;
            }
        }

        liberado[i] = true;
        require(PAGA.transfer(ventas, cantidad), "Transferencia fallida");
        emit LoteLiberado(i, cantidad, ventas);
    }
}
