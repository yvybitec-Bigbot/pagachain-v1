// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./IERC20.sol";
import {IPagaLote} from "./IPagaLote.sol";
import {IAvisoApertura} from "./IAvisoApertura.sol";

/// @title Operador — acredita PAGA a cambio de pagos recibidos fuera de la L3
/// @notice Un relayer autorizado informa al contrato de un pago (stables o
///         DOGE) recibido en otra cadena. Si cumple el mínimo, se entrega PAGA
///         desde el lote del Operador y se registra la cartera. Las primeras
///         369 carteras distintas quedan como fundadoras. Al completarse el
///         cupo, la fundadora 369 puede confirmar (firma EIP-712 o una
///         transacción directa). Tras esa confirmación se puede entregar, en
///         tandas, una cantidad complementaria desde un segundo lote.
/// @dev Los pagos reales ocurren fuera de Pagachain; este contrato no custodia
///      stables ni DOGE. El 70 % de cada entrada de stables se anuncia en un
///      evento para que un servicio externo lo convierta a DOGE.
///      Precio: 0,10 USD durante los dos primeros años desde el inicio de
///      ventas, o hasta que se agote el lote de adopción (el que ocurra
///      antes); 0,20 USD a partir de entonces, para siempre. Nunca vende más
///      barato. El inventario llega de un lote de prueba de 500 PAGA
///      (fondeado desde el despliegue, sacado del 10 % restante) y, a
///      partir del 6 dic 2026, de PagaLotes (cinco lotes inmutables).
///      El inicio de ventas es el instante del despliegue. Este contrato
///      no puede crear PAGA.
contract Operador is IAvisoApertura {
    uint256 public constant CUPO_FUNDADORAS = 369;
    uint256 public constant UMBRAL_AVISO = 300;
    uint256 public constant DECIMALES_USD = 6;
    /// @notice Precio inicial: 0,10 USD por PAGA, con 6 decimales (100_000).
    uint256 public constant PRECIO_USD = 100_000;
    /// @notice Precio a partir del tercer año o al agotarse la adopción: 0,20 USD.
    uint256 public constant PRECIO_POSTERIOR_USD = 200_000;
    /// @notice Duración del precio inicial, a contar desde el inicio de ventas.
    uint256 public constant DURACION_PRECIO_INICIAL = 2 * 365 days;
    /// @notice Ventana de ventas; el remanente se bloquea o se quema después.
    uint256 public constant DURACION_VENTAS = 6 * 365 days;
    /// @notice Tamaño del lote de adopción (lote 0 de los cinco, 15 %).
    uint256 public constant CANTIDAD_ADOPCION = 281_021_238 * 10 ** 6;
    /// @notice Lote de prueba: 500 PAGA (50 USD a 0,10), del 10 % restante,
    ///         fondeado directamente en el lote del Operador desde el despliegue.
    ///         Agotarlo no dispara el paso a 0,20 (eso es el lote de adopción).
    uint256 public constant LOTE_PRUEBA = 500 * 10 ** 6;
    uint256 public constant AGOTADO_SI_MENOS_DE = 1 * 10 ** 6;
    /// @notice Destino de quema: PAGA rechaza address(0), se usa el sumidero habitual.
    address public constant SUMIDERO_QUEMA = 0x000000000000000000000000000000000000dEaD;
    /// @notice Mínimo para acreditar y contar como fundadora: 1,00 USD.
    uint256 public constant MINIMO_USD = 1_000_000;
    /// @notice Parte de cada entrada de stables que se destina a conversión.
    uint256 public constant BPT_CONVERSION = 70;
    uint256 public constant BPT_BASE = 100;

    bytes32 public constant CONFIRMAR_TYPEHASH = keccak256("Confirmar(address cartera,uint256 nonce)");
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    IERC20 public immutable paga;
    IPagaLote public immutable loteOperador;
    IPagaLote public immutable loteComplementario;

    bytes32 private immutable hashedName;
    bytes32 private immutable hashedVersion;
    uint256 private immutable cachedChainId;
    bytes32 private immutable cachedDomainSeparator;

    address public admin;
    address public pendienteAdmin;
    address public relayer;
    bool public pausado;

    /// @notice PAGA acreditado a lo largo del tiempo (6 decimales), por cartera.
    mapping(address => uint256) public obtenido;
    /// @notice USD efectivo acreditado (6 decimales), por cartera.
    mapping(address => uint256) public usdRecibido;
    /// @notice Identificadores de origen ya usados (anti-duplicado).
    mapping(bytes32 => bool) public origenUsado;
    /// @notice Nonce EIP-712 por cartera.
    mapping(address => uint256) public nonces;

    address[] private _fundadoras;
    /// @notice Índice 1-based de fundadora; 0 si no lo es.
    mapping(address => uint256) public indiceFundadora;

    /// @dev Base congelada al confirmar; deja de actualizarse a partir de entonces.
    mapping(address => uint256) private _baseCierre;
    mapping(address => bool) public complementarioPagado;
    uint256 public siguienteIndice;
    bool public confirmacionHecha;
    address public carteraDestacada;
    uint256 public totalComplementario;
    /// @dev Suma de _baseCierre; deja de crecer al confirmar.
    uint256 private _totalBase;

    enum TratamientoRemanente {
        Pendiente,
        Bloqueo,
        Quema
    }

    address public pagaLotes;
    uint256 public inicioVentas;
    uint256 public pagaVendido;
    bool public loteAdopcionAbierto;
    bool public adopcionAgotada;
    TratamientoRemanente public tratamientoRemanente;
    address public bloqueoPermanente;
    bool public remanenteCerrado;
    uint256 public remanenteCerradoTotal;

    uint256 private locked = 1;

    event Acreditado(
        address indexed destino,
        uint256 usd,
        uint256 pagaCantidad,
        bytes32 indexed idOrigen,
        string cadena,
        string activo,
        bool esEstable,
        bool nuevaFundadora,
        uint256 numeroFundadoras
    );
    event UmbralAlcanzado(uint256 indexed numero, address indexed cartera);
    event CupoCompleto(address indexed cartera, uint256 numero);
    event ConversionPendiente(bytes32 indexed idOrigen, uint256 importeUsd, string cadena, string activo);
    event ReservaOperativa(bytes32 indexed idOrigen, uint256 importeUsd);
    event ConfirmacionRegistrada(address indexed cartera, uint256 fundadoras, uint256 pendienteTotal);
    /// @notice Emitido en cada entrega de la distribución posterior a la
    ///         confirmación. La app puede filtrar este evento para etiquetar
    ///         el movimiento en la cartera destinataria.
    event EntregaComplementaria(address indexed cartera, uint256 importe, uint256 indexed indice);
    event DistribucionCompletada(uint256 totalEntregado, uint256 carteras);
    event RelayerFijado(address indexed relayer);
    event AdminPropuesto(address indexed pendiente);
    event AdminAceptado(address indexed admin);
    event Pausa(bool pausado);
    event PagaLotesFijado(address indexed pagaLotes);
    event InicioVentas(uint256 cuando);
    event AdopcionAgotada(uint256 pagaVendido, uint256 quedan, uint256 cuando);
    event AperturaRegistrada(
        uint256 indexed lote, uint256 cantidad, uint256 quedanEnDestino, uint256 precioUsd, uint256 inicioVentas
    );
    event AperturaAplazada(uint256 indexed lote, uint256 nuevoIntento, uint256 quedanEnDestino, uint256 precioUsd);
    event TratamientoRemanenteElegido(TratamientoRemanente tratamiento, address bloqueo);
    event RemanenteCerrado(address indexed destino, uint256 cantidad, TratamientoRemanente tratamiento);

    modifier soloAdmin() {
        require(msg.sender == admin, "Solo admin");
        _;
    }

    modifier soloRelayer() {
        require(msg.sender == relayer, "Solo relayer");
        _;
    }

    modifier cuandoActivo() {
        require(!pausado, "Pausado");
        _;
    }

    modifier noReentrada() {
        require(locked == 1, "Reentrada");
        locked = 2;
        _;
        locked = 1;
    }

    /// @param admin_ Administrador configurable (en Pagachain: tesorería).
    /// @param relayer_ Servicio vigilante autorizado a acreditar pagos externos.
    /// @param paga_ Token PAGA de esta cadena.
    /// @param loteOperador_ Lote del que sale el PAGA de las acreditaciones.
    /// @param loteComplementario_ Lote del que sale la entrega posterior al cupo.
    constructor(address admin_, address relayer_, address paga_, address loteOperador_, address loteComplementario_) {
        require(admin_ != address(0) && relayer_ != address(0), "Cero");
        require(paga_ != address(0) && loteOperador_ != address(0) && loteComplementario_ != address(0), "Cero");
        require(loteOperador_ != loteComplementario_, "Lotes iguales");

        admin = admin_;
        relayer = relayer_;
        paga = IERC20(paga_);
        loteOperador = IPagaLote(loteOperador_);
        loteComplementario = IPagaLote(loteComplementario_);

        require(address(loteOperador.paga()) == paga_, "Lote operador token");
        require(address(loteComplementario.paga()) == paga_, "Lote complemento token");

        hashedName = keccak256(bytes("Operador"));
        hashedVersion = keccak256(bytes("1"));
        cachedChainId = block.chainid;
        cachedDomainSeparator = _buildDomainSeparator(block.chainid);

        // Inicio de ventas = despliegue (lote de prueba disponible).
        inicioVentas = block.timestamp;
        emit RelayerFijado(relayer_);
        emit InicioVentas(inicioVentas);
    }

    // -------------------------------------------------------------------------
    // Acreditación
    // -------------------------------------------------------------------------

    /// @notice Acredita PAGA a `destino` por un pago externo ya recibido.
    /// @param destino Cartera Paga que recibirá los tokens.
    /// @param usd Importe efectivo en USD, 6 decimales. Mínimo 1,00 USD.
    /// @param idOrigen Identificador único del pago (p. ej. keccak256 de
    ///                 cadena + activo + hash de la transacción de origen).
    /// @param cadena Red de origen (ethereum, solana, tron, base, bnb, dogecoin…).
    /// @param activo Activo recibido (USDC, USDT, DOGE…).
    /// @param esEstable True si el pago fue en stables (emite conversión al 70 %).
    function acreditar(
        address destino,
        uint256 usd,
        bytes32 idOrigen,
        string calldata cadena,
        string calldata activo,
        bool esEstable
    ) external soloRelayer cuandoActivo noReentrada {
        require(destino != address(0) && destino != address(this), "Destino");
        require(destino != address(loteOperador) && destino != address(loteComplementario), "Destino");
        require(usd >= MINIMO_USD, "Por debajo del minimo");
        require(idOrigen != bytes32(0), "Origen vacio");
        require(!origenUsado[idOrigen], "Origen ya usado");
        require(bytes(cadena).length != 0 && bytes(activo).length != 0, "Falta origen");
        require(!ventasCerradas(), "Ventas cerradas");

        origenUsado[idOrigen] = true;

        if (inicioVentas == 0) {
            inicioVentas = block.timestamp;
            emit InicioVentas(inicioVentas);
        }

        uint256 cantidad = _pagaPorUsd(usd);
        require(cantidad > 0, "Cantidad");

        bool primera = obtenido[destino] == 0;
        bool nuevaFundadora = false;
        if (primera && _fundadoras.length < CUPO_FUNDADORAS) {
            _fundadoras.push(destino);
            uint256 numero = _fundadoras.length;
            indiceFundadora[destino] = numero;
            nuevaFundadora = true;
            if (numero == UMBRAL_AVISO) {
                emit UmbralAlcanzado(numero, destino);
            } else if (numero == CUPO_FUNDADORAS) {
                emit CupoCompleto(destino, numero);
            }
        }

        obtenido[destino] += cantidad;
        usdRecibido[destino] += usd;
        if (!confirmacionHecha && indiceFundadora[destino] != 0) {
            _baseCierre[destino] += cantidad;
            _totalBase += cantidad;
        }

        if (esEstable) {
            uint256 paraConversion = (usd * BPT_CONVERSION) / BPT_BASE;
            emit ConversionPendiente(idOrigen, paraConversion, cadena, activo);
            emit ReservaOperativa(idOrigen, usd - paraConversion);
        }

        require(loteOperador.entregar(destino, cantidad), "Entrega lote");

        pagaVendido += cantidad;
        _actualizarAdopcion();

        emit Acreditado(destino, usd, cantidad, idOrigen, cadena, activo, esEstable, nuevaFundadora, _fundadoras.length);
    }

    // -------------------------------------------------------------------------
    // Confirmación de la fundadora que completa el cupo
    // -------------------------------------------------------------------------

    /// @notice Confirmación directa por la fundadora que completó el cupo.
    ///         Pensada para una transacción de un clic (el gas puede
    ///         patrocinarse fuera del contrato).
    function confirmar() external cuandoActivo noReentrada {
        _confirmar(msg.sender);
    }

    /// @notice Confirmación con firma EIP-712, enviada por cualquier relé.
    ///         La firmante debe ser la fundadora que completó el cupo.
    function confirmarConFirma(address cartera, uint256 nonce, bytes calldata firma) external cuandoActivo noReentrada {
        require(nonce == nonces[cartera], "Nonce");
        nonces[cartera] = nonce + 1;
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(CONFIRMAR_TYPEHASH, cartera, nonce)));
        address firmante = _recover(digest, firma);
        require(firmante == cartera, "Firma");
        _confirmar(cartera);
    }

    function _confirmar(address cartera) private {
        require(!confirmacionHecha, "Ya confirmado");
        require(_fundadoras.length == CUPO_FUNDADORAS, "Cupo incompleto");
        require(cartera == _fundadoras[CUPO_FUNDADORAS - 1], "No corresponde");

        confirmacionHecha = true;
        carteraDestacada = cartera;
        uint256 pendiente = _totalBase;
        totalComplementario = pendiente;

        emit ConfirmacionRegistrada(cartera, _fundadoras.length, pendiente);
    }

    // -------------------------------------------------------------------------
    // Distribución en tandas
    // -------------------------------------------------------------------------

    /// @notice Entrega la cantidad complementaria a las fundadoras, en tandas.
    ///         Puede llamarla cualquiera una vez confirmado el cupo.
    /// @param max Número máximo de fundadoras a procesar en esta llamada.
    function entregarTanda(uint256 max) external noReentrada {
        require(confirmacionHecha, "No confirmado");
        require(max > 0, "Max");
        uint256 n = _fundadoras.length;
        uint256 i = siguienteIndice;
        require(i < n, "Completado");

        uint256 fin = i + max;
        if (fin > n) fin = n;

        for (; i < fin;) {
            address w = _fundadoras[i];
            uint256 amt = _baseCierre[w];
            if (amt > 0 && !complementarioPagado[w]) {
                complementarioPagado[w] = true;
                require(loteComplementario.entregar(w, amt), "Entrega lote");
                emit EntregaComplementaria(w, amt, i);
            }
            unchecked {
                ++i;
            }
        }
        siguienteIndice = i;
        if (i == n) {
            emit DistribucionCompletada(totalComplementario, n);
        }
    }

    /// @notice Una fundadora puede reclamar su propia entrega complementaria
    ///         si las tandas aún no la han cubierto.
    function reclamar() external noReentrada {
        require(confirmacionHecha, "No confirmado");
        address w = msg.sender;
        uint256 idx = indiceFundadora[w];
        require(idx != 0, "No fundadora");
        uint256 amt = _baseCierre[w];
        require(amt > 0 && !complementarioPagado[w], "Nada que reclamar");
        complementarioPagado[w] = true;
        require(loteComplementario.entregar(w, amt), "Entrega lote");
        emit EntregaComplementaria(w, amt, idx - 1);
    }

    // -------------------------------------------------------------------------
    // Consultas
    // -------------------------------------------------------------------------

    function numeroFundadoras() external view returns (uint256) {
        return _fundadoras.length;
    }

    function fundadoraEn(uint256 indice0) external view returns (address) {
        require(indice0 < _fundadoras.length, "Indice");
        return _fundadoras[indice0];
    }

    function esFundadora(address w) external view returns (bool) {
        return indiceFundadora[w] != 0;
    }

    /// @notice True solo después de la confirmación y solo para la cartera
    ///         que completó el cupo. La app puede usarlo para una marca visual.
    function esDestacada(address w) external view returns (bool) {
        return confirmacionHecha && w == carteraDestacada;
    }

    /// @notice Importe complementario que corresponde a `w` según el cierre.
    ///         Devuelve 0 hasta que haya confirmación.
    function complementoDe(address w) public view returns (uint256) {
        if (!confirmacionHecha) return 0;
        return _baseCierre[w];
    }

    function complementoPendiente(address w) external view returns (uint256) {
        if (!confirmacionHecha || complementarioPagado[w]) return 0;
        return _baseCierre[w];
    }

    function distribucionCompleta() external view returns (bool) {
        return confirmacionHecha && siguienteIndice == _fundadoras.length;
    }

    function hashConfirmar(address cartera, uint256 nonce) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(CONFIRMAR_TYPEHASH, cartera, nonce)));
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == cachedChainId ? cachedDomainSeparator : _buildDomainSeparator(block.chainid);
    }

    function pagarPorUsd(uint256 usd) public view returns (uint256) {
        return _pagaPorUsd(usd);
    }

    function datosCartera(address w)
        external
        view
        returns (
            uint256 obtenido_,
            uint256 usdRecibido_,
            bool esFundadora_,
            uint256 indice_,
            bool esDestacada_,
            uint256 complemento_,
            bool complementarioPagado_
        )
    {
        obtenido_ = obtenido[w];
        usdRecibido_ = usdRecibido[w];
        indice_ = indiceFundadora[w];
        esFundadora_ = indice_ != 0;
        esDestacada_ = confirmacionHecha && w == carteraDestacada;
        complemento_ = confirmacionHecha ? _baseCierre[w] : 0;
        complementarioPagado_ = complementarioPagado[w];
    }

    // -------------------------------------------------------------------------
    // Precio, apertura de lotes y remanente
    // -------------------------------------------------------------------------

    /// @notice Precio vigente en USD con 6 decimales: 100_000 (0,10) o 200_000 (0,20).
    function precioUsd() public view returns (uint256) {
        if (_precioPosterior()) return PRECIO_POSTERIOR_USD;
        return PRECIO_USD;
    }

    function ventasCerradas() public view returns (bool) {
        return inicioVentas != 0 && block.timestamp >= inicioVentas + DURACION_VENTAS;
    }

    function fijarPagaLotes(address l) external soloAdmin {
        require(l != address(0), "Cero");
        require(pagaLotes == address(0), "Ya fijado");
        pagaLotes = l;
        emit PagaLotesFijado(l);
    }

    /// @notice Aviso de PagaLotes en cada apertura o intento aplazado.
    ///         Sirve para la revisión off-chain de la garantía.
    function onAperturaLote(
        uint256 indice,
        uint256 cantidad,
        uint256 quedanEnDestino,
        bool abierto,
        uint256 nuevoIntento
    ) external {
        require(msg.sender == pagaLotes, "Solo lotes");
        if (abierto) {
            if (indice == 0) loteAdopcionAbierto = true;
            if (inicioVentas == 0) {
                inicioVentas = block.timestamp;
                emit InicioVentas(inicioVentas);
            }
            emit AperturaRegistrada(indice, cantidad, quedanEnDestino, precioUsd(), inicioVentas);
            _actualizarAdopcion();
        } else {
            emit AperturaAplazada(indice, nuevoIntento, quedanEnDestino, precioUsd());
        }
    }

    /// @notice El admin elige, cuando se decida, si el remanente de 6
    ///         años se bloquea o se quema. Se puede cambiar mientras no se haya
    ///         ejecutado el cierre. Nunca se vende más barato.
    function elegirTratamientoRemanente(TratamientoRemanente t, address bloqueo) external soloAdmin {
        require(!remanenteCerrado, "Ya cerrado");
        require(t == TratamientoRemanente.Bloqueo || t == TratamientoRemanente.Quema, "Decision");
        if (t == TratamientoRemanente.Bloqueo) {
            require(bloqueo != address(0) && bloqueo != address(this), "Bloqueo");
            require(bloqueo != address(loteOperador) && bloqueo != address(loteComplementario), "Bloqueo");
            bloqueoPermanente = bloqueo;
        } else {
            bloqueoPermanente = address(0);
        }
        tratamientoRemanente = t;
        emit TratamientoRemanenteElegido(t, bloqueoPermanente);
    }

    /// @notice Tras 6 años desde el inicio de ventas, envía el PAGA sin vender
    ///         del lote del Operador al bloqueo permanente o al sumidero de
    ///         quema, según la decisión previa. Puede llamarla cualquiera.
    ///         Si más adelante llega otro lote, se puede volver a llamar.
    function cerrarRemanente() external noReentrada {
        require(ventasCerradas(), "Aun no");
        require(
            tratamientoRemanente == TratamientoRemanente.Bloqueo || tratamientoRemanente == TratamientoRemanente.Quema,
            "Falta decision"
        );
        uint256 quedan = loteOperador.disponible();
        require(quedan > 0, "Nada que cerrar");
        address destino_ = tratamientoRemanente == TratamientoRemanente.Quema ? SUMIDERO_QUEMA : bloqueoPermanente;
        require(loteOperador.entregar(destino_, quedan), "Entrega lote");
        remanenteCerrado = true;
        remanenteCerradoTotal += quedan;
        emit RemanenteCerrado(destino_, quedan, tratamientoRemanente);
    }

    // -------------------------------------------------------------------------
    // Administración
    // -------------------------------------------------------------------------

    function fijarRelayer(address r) external soloAdmin {
        require(r != address(0), "Cero");
        relayer = r;
        emit RelayerFijado(r);
    }

    function proponerAdmin(address a) external soloAdmin {
        require(a != address(0), "Cero");
        pendienteAdmin = a;
        emit AdminPropuesto(a);
    }

    function aceptarAdmin() external {
        require(msg.sender == pendienteAdmin, "No propuesto");
        admin = msg.sender;
        pendienteAdmin = address(0);
        emit AdminAceptado(msg.sender);
    }

    function pausar() external soloAdmin {
        pausado = true;
        emit Pausa(true);
    }

    function reanudar() external soloAdmin {
        pausado = false;
        emit Pausa(false);
    }

    /// @notice Recupera tokens o el gas nativo enviados por error a este
    ///         contrato. No puede sacar PAGA de los lotes (viven en otro
    ///         contrato). Tampoco retira el PAGA de acreditación, que nunca
    ///         debería quedar aquí.
    function rescatar(address token, address destino, uint256 cantidad) external soloAdmin noReentrada {
        require(destino != address(0), "Destino");
        require(token != address(loteOperador) && token != address(loteComplementario), "Lote");
        if (token == address(0)) {
            (bool enviado,) = destino.call{value: cantidad}("");
            require(enviado, "Envio nativo");
            return;
        }
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, destino, cantidad));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "Transferencia fallida");
    }

    receive() external payable {}

    // -------------------------------------------------------------------------
    // Internos
    // -------------------------------------------------------------------------

    function _precioPosterior() private view returns (bool) {
        if (adopcionAgotada) return true;
        if (inicioVentas != 0 && block.timestamp >= inicioVentas + DURACION_PRECIO_INICIAL) return true;
        return false;
    }

    function _actualizarAdopcion() private {
        if (adopcionAgotada) return;
        if (
            pagaVendido >= CANTIDAD_ADOPCION || (loteAdopcionAbierto && loteOperador.disponible() < AGOTADO_SI_MENOS_DE)
        ) {
            adopcionAgotada = true;
            emit AdopcionAgotada(pagaVendido, loteOperador.disponible(), block.timestamp);
        }
    }

    function _pagaPorUsd(uint256 usd) private view returns (uint256) {
        return (usd * (10 ** DECIMALES_USD)) / precioUsd();
    }

    function _buildDomainSeparator(uint256 chainId) private view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, hashedName, hashedVersion, chainId, address(this)));
    }

    function _hashTypedDataV4(bytes32 structHash) private view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _recover(bytes32 digest, bytes calldata firma) private pure returns (address) {
        require(firma.length == 65, "Firma larga");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(firma.offset)
            s := calldataload(add(firma.offset, 32))
            v := byte(0, calldataload(add(firma.offset, 64)))
        }
        if (v < 27) v += 27;
        require(v == 27 || v == 28, "V");
        // EIP-2: s en la mitad inferior del orden de secp256k1.
        require(uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0, "S");
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "Recover");
        return signer;
    }
}
