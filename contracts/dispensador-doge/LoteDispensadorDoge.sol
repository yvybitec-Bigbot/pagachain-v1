// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title LoteDispensadorDoge — lote aparte de 3.690.369 PAGA para el dispensador DOGE
/// @notice Intercambia PAGA a $0,10 fijo por DOGE recibido en la cartera de garantía
///         (`DKZayo26HFgFhttAWQSqMUBxmNLQR7irJd`), solo mientras el oráculo
///         marque el DOGE por debajo de $0,10. El PAGA queda bloqueado para siempre:
///         no hay retirada ni rescate, ni siquiera para el admin. El admin solo puede
///         cambiar la dirección del relayer y pausar. Quien llama a `dispensar` es el
///         relayer autorizado, que vigila ingresos reales de DOGE. Este contrato no
///         se mezcla con la adopción ni con `Operador.acreditar`.
///         Archivo autónomo (sin imports) para poder pegarlo en Remix.

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IOraculoPagachain {
    function latest() external view returns (uint256 price, uint64 timestamp, uint80 round);
    function decimals() external view returns (uint8);
}

/// @notice safeTransfer: acepta tokens que devuelven `true` o nada; revierte en cualquier otro caso.
library TransferenciaSegura {
    error TransferenciaFallida();

    function enviar(IERC20 token, address to, uint256 value) internal {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, value)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool))) || address(token).code.length == 0) {
            revert TransferenciaFallida();
        }
    }
}

contract LoteDispensadorDoge {
    using TransferenciaSegura for IERC20;

    /// @notice 3.690.369 PAGA, 6 decimales. Se carga más adelante; no es un tope
    ///         on-chain: `restante()` es el saldo real del contrato.
    uint256 public constant TAMANO_LOTE = 3_690_369 * 1e6;
    uint8 public constant PAGA_DECIMALES = 6;
    uint8 public constant ORACULO_DECIMALES = 8;
    uint8 public constant DOGE_DECIMALES = 8;
    /// @notice $0,10 con 8 decimales. El dispensador se cierra si el oráculo marca este
    ///         precio o más (queda abierto con 0,09999999 o menos).
    uint256 public constant PRECIO_CIERRE = 10_000_000;
    /// @notice `paga_6 = doge_8 * precio_8 / 1e9` porque 0,10 × 10^(8+8-6) = 10^9.
    uint256 public constant DENOMINADOR_CAMBIO = 1_000_000_000;
    /// @notice Holgura si la marca de tiempo del oráculo va un poco por delante del bloque.
    uint256 public constant HOLGURA_FUTURO = 5 minutes;

    IERC20 public immutable paga;
    IOraculoPagachain public immutable oraculo;
    address public immutable admin;
    /// @notice Edad máxima aceptable del dato del oráculo, fija en el despliegue.
    uint256 public immutable maxEdadOraculo;
    /// @notice Tope de PAGA (6 dec) por `dispensar`. 0 = sin tope aparte del restante.
    uint256 public immutable maxPorTx;

    address public relayer;
    bool public pausado;
    uint256 public entregado;
    mapping(bytes32 => bool) public origenUsado;

    event Dispensado(
        address indexed destino, uint256 dogeAmount, uint256 pagaAmount, uint256 precio, bytes32 indexed idOrigen
    );
    event RelayerActualizado(address indexed anterior, address indexed nuevo);
    event Pausado(address indexed quien);
    event Reanudado(address indexed quien);

    error DireccionCero();
    error ConfiguracionInvalida();
    error SoloAdmin();
    error SoloRelayer();
    error EnPausa();
    error NoPausado();
    error Cerrado();
    error OraculoViejo();
    error OraculoInvalido();
    error OrigenVacio();
    error OrigenUsado();
    error DestinoInvalido();
    error ImporteCero();
    error SinDisponible();
    error ExcedeMaximo();
    error NoSeAceptaNativo();

    modifier soloAdmin() {
        if (msg.sender != admin) revert SoloAdmin();
        _;
    }

    modifier soloRelayer() {
        if (msg.sender != relayer) revert SoloRelayer();
        _;
    }

    /// @param paga_ Token PAGA en Pagachain (6 decimales).
    /// @param oraculo_ OraculoPagachain DOGE/USD (8 decimales).
    /// @param admin_ Solo puede cambiar el relayer y pausar. Nunca saca PAGA.
    /// @param relayer_ Dirección autorizada a llamar `dispensar`.
    /// @param maxEdadOraculo_ Segundos de frescura del oráculo (p. ej. 26 horas).
    /// @param maxPorTx_ Tope de PAGA (6 dec) por transacción; 0 = sin tope.
    constructor(
        address paga_,
        address oraculo_,
        address admin_,
        address relayer_,
        uint256 maxEdadOraculo_,
        uint256 maxPorTx_
    ) {
        if (paga_ == address(0) || oraculo_ == address(0) || admin_ == address(0) || relayer_ == address(0)) {
            revert DireccionCero();
        }
        if (maxEdadOraculo_ == 0) revert ConfiguracionInvalida();
        if (IERC20(paga_).decimals() != PAGA_DECIMALES) revert ConfiguracionInvalida();
        if (IOraculoPagachain(oraculo_).decimals() != ORACULO_DECIMALES) revert ConfiguracionInvalida();
        paga = IERC20(paga_);
        oraculo = IOraculoPagachain(oraculo_);
        admin = admin_;
        relayer = relayer_;
        maxEdadOraculo = maxEdadOraculo_;
        maxPorTx = maxPorTx_;
        emit RelayerActualizado(address(0), relayer_);
    }

    receive() external payable {
        revert NoSeAceptaNativo();
    }

    fallback() external payable {
        revert NoSeAceptaNativo();
    }

    function setRelayer(address nuevo) external soloAdmin {
        if (nuevo == address(0)) revert DireccionCero();
        address anterior = relayer;
        relayer = nuevo;
        emit RelayerActualizado(anterior, nuevo);
    }

    function pausar() external soloAdmin {
        if (pausado) revert EnPausa();
        pausado = true;
        emit Pausado(msg.sender);
    }

    function reanudar() external soloAdmin {
        if (!pausado) revert NoPausado();
        pausado = false;
        emit Reanudado(msg.sender);
    }

    /// @notice Saldo de PAGA que queda en el lote (lo que hay en este contrato).
    function restante() public view returns (uint256) {
        return paga.balanceOf(address(this));
    }

    /// @notice Abierto si no está en pausa, queda PAGA, el oráculo está fresco y
    ///         el precio del DOGE es menor que $0,10.
    function abierto() public view returns (bool) {
        if (pausado || restante() == 0) return false;
        (bool ok, uint256 precio,) = _leerOraculo(false);
        return ok && precio < PRECIO_CIERRE;
    }

    /// @notice PAGA (6 dec) que saldrían por `dogeAmount` (8 dec, koinu) al precio
    ///         actual del oráculo. Revierte si el dato no es válido o está viejo.
    ///         No exige que el dispensador esté abierto (sirve para consultar).
    function cotizar(uint256 dogeAmount) public view returns (uint256) {
        (, uint256 precio,) = _leerOraculo(true);
        return _pagaPor(dogeAmount, precio);
    }

    function usado(bytes32 idOrigen) external view returns (bool) {
        return origenUsado[idOrigen];
    }

    /// @notice Acredita PAGA a `destino` por un ingreso de DOGE ya visto por el relayer.
    /// @param destino Cartera Pagachain que recibe el PAGA.
    /// @param dogeAmount Importe de DOGE en koinu (8 decimales).
    /// @param idOrigen `keccak256` del txid de Dogecoin (32 bytes). Impide repetirlo.
    function dispensar(address destino, uint256 dogeAmount, bytes32 idOrigen) external soloRelayer {
        if (pausado) revert EnPausa();
        if (destino == address(0) || destino == address(this) || destino == address(paga) || destino == relayer) {
            revert DestinoInvalido();
        }
        if (dogeAmount == 0) revert ImporteCero();
        if (idOrigen == bytes32(0)) revert OrigenVacio();
        if (origenUsado[idOrigen]) revert OrigenUsado();

        (, uint256 precio,) = _leerOraculo(true);
        if (precio >= PRECIO_CIERRE) revert Cerrado();

        uint256 cantidad = _pagaPor(dogeAmount, precio);
        if (cantidad == 0) revert ImporteCero();
        if (maxPorTx != 0 && cantidad > maxPorTx) revert ExcedeMaximo();
        if (cantidad > restante()) revert SinDisponible();

        origenUsado[idOrigen] = true;
        entregado += cantidad;
        paga.enviar(destino, cantidad);
        emit Dispensado(destino, dogeAmount, cantidad, precio, idOrigen);
    }

    function _pagaPor(uint256 dogeAmount, uint256 precio) internal pure returns (uint256) {
        if (dogeAmount == 0 || precio == 0) return 0;
        return (dogeAmount * precio) / DENOMINADOR_CAMBIO;
    }

    /// @dev Si `requerir` es true, revierte ante un dato inválido o viejo.
    ///      Si es false, devuelve ok=false y no revierte.
    function _leerOraculo(bool requerir) internal view returns (bool ok, uint256 precio, uint64 ts) {
        try oraculo.latest() returns (uint256 p, uint64 t, uint80 round) {
            if (p == 0 || t == 0 || round == 0) {
                if (requerir) revert OraculoInvalido();
                return (false, 0, 0);
            }
            if (t > block.timestamp) {
                if (t - uint64(block.timestamp) > HOLGURA_FUTURO) {
                    if (requerir) revert OraculoInvalido();
                    return (false, 0, 0);
                }
            } else if (block.timestamp - t > maxEdadOraculo) {
                if (requerir) revert OraculoViejo();
                return (false, p, t);
            }
            return (true, p, t);
        } catch {
            if (requerir) revert OraculoInvalido();
            return (false, 0, 0);
        }
    }
}
