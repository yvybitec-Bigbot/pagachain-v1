// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./IERC20.sol";
import {TransferenciaSegura} from "./TransferenciaSegura.sol";
import {PagaTiempo} from "./PagaTiempo.sol";
import {PausaLimitada} from "./PausaLimitada.sol";
import {Guardia} from "./Guardia.sol";
import {IPagaLote, IPagaLoteImplementacion, IPagaDispensador, IPagaFundadoras, IPagaBloqueo} from "./Interfaces.sol";

/// @title PagaOperador (v2) — intercambio de PAGA a precio fijo
/// @notice Precio por PAGA: 0,10 USD hasta `inicio + 730 días` (exclusivo) y 0,20 USD desde ese segundo para
///         siempre, por tiempo bruto. 1 CENT (nativo, 18 decimales) = 0,01 USD fijo: 10 CENT por PAGA y luego
///         20 CENT. Antes de `inicio` no hay ningún intercambio.
///
///         Fuentes de PAGA: antes del día 730, la cartera de Adopción mediante la autorización limitada
///         (approve) que su titular da a este contrato. Desde el día 730, solo un lote abierto (Implementación
///         y luego Final); si no hay ninguno abierto, los intercambios revierten (el Operador descansa).
///         Las acreditaciones de bots salen solo del dispensador (parte bots).
///
///         - Intercambio con CENT: solo desde el cierre de la cuenta de fundadoras (antes revierte); después,
///           sin tope y sin aprobación. Si la fuente no alcanza se entrega lo que haya y
///           se devuelve el CENT sobrante (también el resto por redondeo). El CENT cobrado se envía con
///           `barrerCent` (cualquiera) solo a la tesorería inmutable.
///         - Acreditación del relayer (valor de fuera): cantidad = mín(pagado, cupo libre de la cartera
///           200.000 PAGA/día, cubo global). La clave keccak(cadena, txHash, índiceLog) se consume aunque la
///           acreditación sea parcial; el exceso se pierde.
///         - Cubo global: 3.000.000 PAGA/día con recarga continua. Sube un 50 % al empezar el trimestre siguiente
///           a uno en el que se vació (medido con PAGA acreditado), con techo de 20.000.000/día. Nunca baja.
///         - Fundadoras: registros propios (sin llamadas a otros contratos), solo desde acreditaciones del relayer:
///           valor de fuera y bots (el CENT no se intercambia hasta el cierre). Primeras 369 carteras; compras computables hasta 200.000
///           PAGA por cartera; recompensa 2×. La cuenta se cierra al entrar la 369 o al alcanzar el día 730.
///           Excluidas: admin, tesorería, Operador, lotes, fundadoras, dispensador, bloqueo, relayer (activo
///           o propuesto) y Adopción.
///
///         Poderes del admin (lista cerrada): `pausar`, `reanudar`, `revocarRelayer`, `proponerRelayer`.
contract PagaOperador is PausaLimitada, Guardia {
    using TransferenciaSegura for IERC20;

    uint256 public constant CUPO_FUNDADORAS = 369;
    uint256 public constant MAX_COMPRAS_FUNDADORA = 200_000 * 1e6;
    uint256 public constant CUPO_CARTERA_DIARIO = 200_000 * 1e6;
    uint256 public constant CUPO_GLOBAL_INICIAL = 3_000_000 * 1e6;
    uint256 public constant CUPO_GLOBAL_TECHO = 20_000_000 * 1e6;
    uint256 public constant TRIMESTRE = 365 days / 4;
    uint256 public constant DEMORA_RELAYER = 48 hours;
    /// @notice Precios en USD con 6 decimales.
    uint256 public constant PRECIO_INICIAL_USD = 100_000;
    uint256 public constant PRECIO_POSTERIOR_USD = 200_000;
    /// @notice wei de CENT por unidad mínima de PAGA (1e-6 PAGA): 10 CENT/PAGA y 20 CENT/PAGA.
    uint256 public constant WEI_POR_UNIDAD_INICIAL = 10 * 1e18 / 1e6;
    uint256 public constant WEI_POR_UNIDAD_POSTERIOR = 20 * 1e18 / 1e6;

    enum Fuente {
        LoteImplementacion,
        LoteFinal,
        Adopcion,
        DispensadorBots
    }

    struct Uso {
        uint128 consumido;
        uint64 ultimo;
    }

    IERC20 public immutable paga;
    uint256 public immutable inicio;
    address public immutable adopcion;
    address public immutable tesoreria;
    address public immutable fundadoras;
    address public immutable bloqueo;
    IPagaLote public immutable loteImplementacion;
    IPagaLote public immutable loteFinal;
    IPagaDispensador public immutable dispensador;

    address private _relayer;
    address public relayerPropuesto;
    uint256 public relayerPropuestoDesde;

    uint256 public capacidadGlobal;
    uint256 private _consumidoGlobal;
    uint256 private _ultimoGlobal;
    /// @notice Trimestre (índice + 1) a partir del cual se aplica la siguiente subida; 0 = ninguna pendiente.
    uint256 public subidaPendienteDesde;
    mapping(address => Uso) private _usoCartera;
    mapping(bytes32 => bool) public claveUsada;

    uint256 public numFundadoras;
    mapping(address => uint256) public indiceFundadora;
    mapping(address => uint256) public comprasFundadora;
    uint256 public totalComprasFundadoras;

    event IntercambioCent(
        address indexed pagador, address indexed destino, uint256 centCobrado, uint256 paga, Fuente fuente
    );
    event Acreditado(
        address indexed destino,
        bytes32 indexed clave,
        uint256 cadenaOrigen,
        bytes32 txHash,
        uint256 indiceLog,
        uint256 usd,
        uint256 paga,
        Fuente fuente
    );
    event FundadoraRegistrada(address indexed cartera, uint256 indexed indice);
    event CuentaFundadorasCerrada(uint256 cuando, uint256 totalRecompensas);
    event CupoGlobalSubido(uint256 nuevaCapacidad, uint256 trimestre);
    event TopeGlobalAlcanzado(uint256 trimestre);
    event CentBarrido(address indexed tesoreria, uint256 cantidad);
    event RelayerRevocado();
    event RelayerPropuesto(address indexed relayer, uint256 efectivoDesde);
    event RelayerActivado(address indexed relayer);

    error NoIniciado();
    error CentAntesDelCierre();
    error CantidadCero();
    error SinFuente();
    error SinCupo();
    error ClaveUsada();
    error SoloRelayer();
    error DevolucionFallida();
    error EnvioTesoreriaFallido();
    error ConfiguracionInvalida();

    modifier soloRelayer() {
        _consolidarRelayer();
        if (_relayer == address(0) || msg.sender != _relayer) revert SoloRelayer();
        _;
    }

    modifier iniciado() {
        if (block.timestamp < inicio) revert NoIniciado();
        _;
    }

    /// @notice Direcciones fijadas al desplegar. admin = multisig 2 de 3; relayer = inicial (efectivo desde el
    ///         despliegue); adopcion = cartera del fundador (da approve limitado); tesoreria = destino del CENT.
    ///         Lotes, dispensador y fundadoras son direcciones previstas (CREATE2/nonce) que se comprueban con
    ///         `verificarConfiguracion` antes de fondear.
    struct Direcciones {
        address admin;
        address relayer;
        address paga;
        address adopcion;
        address tesoreria;
        address loteImplementacion;
        address loteFinal;
        address dispensador;
        address fundadoras;
        address bloqueo;
    }

    /// @param d Direcciones fijas (ver `Direcciones`).
    /// @param inicio_ START: argumento único compartido por todos los contratos.
    constructor(Direcciones memory d, uint256 inicio_) PausaLimitada(d.admin) {
        if (
            d.relayer == address(0) || d.paga == address(0) || d.adopcion == address(0) || d.tesoreria == address(0)
                || d.loteImplementacion == address(0) || d.loteFinal == address(0) || d.dispensador == address(0)
                || d.fundadoras == address(0) || d.bloqueo == address(0)
        ) revert DireccionCero();
        if (inicio_ == 0) revert ConfiguracionInvalida();
        _relayer = d.relayer;
        paga = IERC20(d.paga);
        inicio = inicio_;
        adopcion = d.adopcion;
        tesoreria = d.tesoreria;
        loteImplementacion = IPagaLote(d.loteImplementacion);
        loteFinal = IPagaLote(d.loteFinal);
        dispensador = IPagaDispensador(d.dispensador);
        fundadoras = d.fundadoras;
        bloqueo = d.bloqueo;
        capacidadGlobal = CUPO_GLOBAL_INICIAL;
        emit RelayerActivado(d.relayer);
    }

    // ================================================================ vistas

    function precioUsd() public view returns (uint256) {
        return PagaTiempo.alcanzado(inicio, PagaTiempo.DIA_730) ? PRECIO_POSTERIOR_USD : PRECIO_INICIAL_USD;
    }

    function weiPorUnidad() public view returns (uint256) {
        return PagaTiempo.alcanzado(inicio, PagaTiempo.DIA_730) ? WEI_POR_UNIDAD_POSTERIOR : WEI_POR_UNIDAD_INICIAL;
    }

    function relayer() public view returns (address) {
        if (relayerPropuesto != address(0) && block.timestamp >= relayerPropuestoDesde) return relayerPropuesto;
        return _relayer;
    }

    function trimestreActual() public view returns (uint256) {
        return block.timestamp < inicio ? 0 : (block.timestamp - inicio) / TRIMESTRE;
    }

    function cupoGlobalDisponible() external view returns (uint256) {
        (uint256 cap, uint256 consumido,) = _estadoGlobal();
        return cap - consumido;
    }

    function cupoCarteraDisponible(address cartera) external view returns (uint256) {
        return CUPO_CARTERA_DIARIO - _consumidoCartera(cartera);
    }

    /// @notice Cerrada al entrar la cartera 369 o al alcanzar el día 730 (regla de PagaTiempo).
    function cuentaCerrada() public view returns (bool) {
        return numFundadoras == CUPO_FUNDADORAS || PagaTiempo.alcanzado(inicio, PagaTiempo.DIA_730);
    }

    function recompensa(address cartera) external view returns (uint256) {
        return 2 * comprasFundadora[cartera];
    }

    /// @notice Total debido a las fundadoras. Fijo una vez cerrada la cuenta; máximo 147.600.000 PAGA.
    function totalRecompensas() external view returns (uint256) {
        return 2 * totalComprasFundadoras;
    }

    /// @notice Comprobación previa al fondeo: todas las direcciones previstas están desplegadas y enlazadas.
    function verificarConfiguracion() external view returns (bool) {
        address yo = address(this);
        address p = address(paga);
        IPagaLote[2] memory lotes = [loteImplementacion, loteFinal];
        address bloq = bloqueo;
        for (uint256 i; i < 2; ++i) {
            IPagaLote l = lotes[i];
            if (address(l).code.length == 0) revert ConfiguracionInvalida();
            if (l.operador() != yo || l.paga() != p || l.inicio() != inicio) revert ConfiguracionInvalida();
            if (l.bloqueo() != bloq) revert ConfiguracionInvalida();
        }
        if (IPagaBloqueo(bloq).paga() != p) revert ConfiguracionInvalida();
        if (address(dispensador).code.length == 0) revert ConfiguracionInvalida();
        if (dispensador.operador() != yo || dispensador.paga() != p || dispensador.inicio() != inicio) {
            revert ConfiguracionInvalida();
        }
        if (IPagaLoteImplementacion(address(loteImplementacion)).fundadoras() != fundadoras) {
            revert ConfiguracionInvalida();
        }
        IPagaFundadoras f = IPagaFundadoras(fundadoras);
        if (f.operador() != yo || f.paga() != p || f.bloqueo() != bloq) revert ConfiguracionInvalida();
        return true;
    }

    // ============================================================ intercambios

    /// @notice Intercambia CENT por PAGA a precio fijo. Devuelve el CENT no usado al pagador.
    ///         Solo desde el cierre de la cuenta de fundadoras (cartera 369 o día 730, lo que llegue antes).
    function intercambiarCent(address destino) external payable cuandoActivo iniciado noReentrada returns (uint256 n) {
        if (!cuentaCerrada()) revert CentAntesDelCierre();
        if (destino == address(0)) revert DireccionCero();
        uint256 wpu = weiPorUnidad();
        uint256 pedido = msg.value / wpu;
        if (pedido == 0) revert CantidadCero();
        (Fuente f, uint256 disp) = _fuenteGeneral();
        n = pedido < disp ? pedido : disp;
        if (n == 0) revert SinFuente();
        uint256 cobrado = n * wpu;
        emit IntercambioCent(msg.sender, destino, cobrado, n, f);
        _entregarDesde(f, destino, n);
        uint256 devolucion = msg.value - cobrado;
        if (devolucion != 0) {
            (bool ok,) = msg.sender.call{value: devolucion}("");
            if (!ok) revert DevolucionFallida();
        }
    }

    /// @notice El relayer acredita un pago externo (USDT/USDC Tron/Ethereum, DOGE...). `usd` con 6 decimales.
    function acreditarExterno(address destino, uint256 usd, uint256 cadenaOrigen, bytes32 txHash, uint256 indiceLog)
        external
        soloRelayer
        cuandoActivo
        iniciado
        noReentrada
        returns (uint256)
    {
        return _acreditar(destino, usd, cadenaOrigen, txHash, indiceLog, false);
    }

    /// @notice El relayer acredita PLS pagados por un bot fuera de Pagachain; sale de la parte bots del dispensador.
    function acreditarBots(address destino, uint256 usd, uint256 cadenaOrigen, bytes32 txHash, uint256 indiceLog)
        external
        soloRelayer
        cuandoActivo
        iniciado
        noReentrada
        returns (uint256)
    {
        return _acreditar(destino, usd, cadenaOrigen, txHash, indiceLog, true);
    }

    /// @notice 0,5 PAGA una vez por cartera nueva (lo comprueba el dispensador, con su tope diario).
    function darFaucet(address cartera) external soloRelayer cuandoActivo iniciado noReentrada {
        dispensador.entregarFaucet(cartera);
    }

    /// @notice Cualquiera envía el CENT cobrado a la tesorería inmutable. Funciona en pausa.
    function barrerCent() external noReentrada {
        uint256 b = address(this).balance;
        if (b == 0) revert CantidadCero();
        emit CentBarrido(tesoreria, b);
        (bool ok,) = tesoreria.call{value: b}("");
        if (!ok) revert EnvioTesoreriaFallido();
    }

    // ================================================================== admin

    /// @notice Revoca al instante el relayer activo y cualquier propuesta pendiente.
    function revocarRelayer() external soloAdmin {
        _relayer = address(0);
        relayerPropuesto = address(0);
        relayerPropuestoDesde = 0;
        emit RelayerRevocado();
    }

    /// @notice Propone un relayer nuevo; entra en vigor tras DEMORA_RELAYER (48 h).
    function proponerRelayer(address nuevo) external soloAdmin {
        if (nuevo == address(0)) revert DireccionCero();
        relayerPropuesto = nuevo;
        relayerPropuestoDesde = block.timestamp + DEMORA_RELAYER;
        emit RelayerPropuesto(nuevo, relayerPropuestoDesde);
    }

    // ============================================================== internos

    function _acreditar(address destino, uint256 usd, uint256 cadenaOrigen, bytes32 txHash, uint256 indiceLog, bool bots)
        private
        returns (uint256 n)
    {
        if (destino == address(0)) revert DireccionCero();
        bytes32 clave = keccak256(abi.encode(cadenaOrigen, txHash, indiceLog));
        if (claveUsada[clave]) revert ClaveUsada();
        uint256 pedido = usd * 1e6 / precioUsd();
        if (pedido == 0) revert CantidadCero();

        (Fuente f, uint256 disp) = bots ? (Fuente.DispensadorBots, dispensador.disponibleBots()) : _fuenteGeneral();
        n = _consumirCupos(destino, pedido < disp ? pedido : disp);
        claveUsada[clave] = true;

        _entregarDesde(f, destino, n);
        _registrarFundadora(destino, n);
        emit Acreditado(destino, clave, cadenaOrigen, txHash, indiceLog, usd, n, f);
    }

    /// @dev Aplica la subida pendiente, recorta por cubo global y cupo de cartera, y consume ambos.
    function _consumirCupos(address destino, uint256 maximo) private returns (uint256 n) {
        (uint256 cap, uint256 consumidoG, bool subir) = _estadoGlobal();
        if (subir) {
            capacidadGlobal = cap;
            subidaPendienteDesde = 0;
            emit CupoGlobalSubido(cap, trimestreActual());
        }
        uint256 consumidoC = _consumidoCartera(destino);
        n = maximo;
        if (cap - consumidoG < n) n = cap - consumidoG;
        if (CUPO_CARTERA_DIARIO - consumidoC < n) n = CUPO_CARTERA_DIARIO - consumidoC;
        if (n == 0) revert SinCupo();

        consumidoG += n;
        _consumidoGlobal = consumidoG;
        _ultimoGlobal = block.timestamp;
        if (consumidoG == cap && cap < CUPO_GLOBAL_TECHO) {
            uint256 q = trimestreActual();
            subidaPendienteDesde = q + 1;
            emit TopeGlobalAlcanzado(q);
        }
        _usoCartera[destino] = Uso(uint128(consumidoC + n), uint64(block.timestamp));
    }

    /// @dev Capacidad y consumo del cubo global a día de hoy (recarga continua y subida pendiente aplicada).
    function _estadoGlobal() private view returns (uint256 cap, uint256 consumido, bool subir) {
        cap = capacidadGlobal;
        uint256 recarga = (block.timestamp - _ultimoGlobal) * cap / 1 days;
        consumido = _consumidoGlobal > recarga ? _consumidoGlobal - recarga : 0;
        uint256 p = subidaPendienteDesde;
        if (p != 0 && trimestreActual() >= p) {
            subir = true;
            cap = cap * 3 / 2;
            if (cap > CUPO_GLOBAL_TECHO) cap = CUPO_GLOBAL_TECHO;
        }
    }

    function _consumidoCartera(address cartera) private view returns (uint256) {
        Uso memory u = _usoCartera[cartera];
        uint256 recarga = (block.timestamp - u.ultimo) * CUPO_CARTERA_DIARIO / 1 days;
        return u.consumido > recarga ? u.consumido - recarga : 0;
    }

    /// @dev Antes del día 730: Adopción. Desde el día 730: lote abierto o nada (devuelve 0 → revierte).
    function _fuenteGeneral() private view returns (Fuente, uint256) {
        if (PagaTiempo.alcanzado(inicio, PagaTiempo.DIA_730)) {
            uint256 d = loteImplementacion.disponibleIntercambio();
            if (d != 0) return (Fuente.LoteImplementacion, d);
            return (Fuente.LoteFinal, loteFinal.disponibleIntercambio());
        }
        uint256 permitido = paga.allowance(adopcion, address(this));
        uint256 saldo = paga.balanceOf(adopcion);
        return (Fuente.Adopcion, permitido < saldo ? permitido : saldo);
    }

    function _entregarDesde(Fuente f, address destino, uint256 n) private {
        if (f == Fuente.LoteImplementacion) loteImplementacion.entregar(destino, n);
        else if (f == Fuente.LoteFinal) loteFinal.entregar(destino, n);
        else if (f == Fuente.Adopcion) paga.enviarDesde(adopcion, destino, n);
        else dispensador.entregarBots(destino, n);
    }

    /// @notice Direcciones del equipo y de los contratos, que nunca cuentan como fundadoras.
    function esExcluida(address a) public view returns (bool) {
        return a == admin || a == tesoreria || a == address(this) || a == address(loteImplementacion)
            || a == address(loteFinal) || a == fundadoras || a == address(dispensador) || a == bloqueo
            || a == adopcion || a == _relayer || a == relayerPropuesto;
    }

    /// @dev Solo lee y escribe almacenamiento propio: nunca puede revertir un intercambio.
    function _registrarFundadora(address cartera, uint256 n) private {
        if (cuentaCerrada() || esExcluida(cartera)) return;
        uint256 idx = indiceFundadora[cartera];
        if (idx == 0) {
            idx = ++numFundadoras;
            indiceFundadora[cartera] = idx;
            emit FundadoraRegistrada(cartera, idx);
        }
        uint256 previo = comprasFundadora[cartera];
        uint256 margen = MAX_COMPRAS_FUNDADORA - previo;
        uint256 suma = n < margen ? n : margen;
        if (suma != 0) {
            comprasFundadora[cartera] = previo + suma;
            totalComprasFundadoras += suma;
        }
        if (idx == CUPO_FUNDADORAS) emit CuentaFundadorasCerrada(block.timestamp, 2 * totalComprasFundadoras);
    }

    function _consolidarRelayer() private {
        address p = relayerPropuesto;
        if (p != address(0) && block.timestamp >= relayerPropuestoDesde) {
            _relayer = p;
            relayerPropuesto = address(0);
            relayerPropuestoDesde = 0;
            emit RelayerActivado(p);
        }
    }
}
