// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./IERC20.sol";
import {IPagaLote} from "./IPagaLote.sol";

/// @title PagaLote — lote bloqueado de PAGA (estándar reutilizable para L3)
/// @notice Custodia PAGA que solo puede salir hacia el destino que indique el
///         contrato autorizado (por ejemplo el Operador). El administrador no
///         puede retirar PAGA directamente; solo puede cambiar el contrato
///         autorizado o pausar entregas. Cualquiera puede fondear o recargar
///         el lote enviando PAGA a esta dirección: no hay tope ni cantidad
///         fija; `disponible()` es el saldo actual. Si el lote se agota, se
///         vuelve a fondear con el importe que se calcule en ese momento,
///         desde otra fuente autorizada. La recarga no es automática.
/// @dev Pensado para crearse de uno en uno, a medida que se desarrolla cada uso.
contract PagaLote is IPagaLote {
    IERC20 public immutable override paga;

    address public admin;
    address public pendienteAdmin;
    address public override autorizado;
    bool public pausado;

    uint256 private locked = 1;

    event AutorizadoFijado(address indexed autorizado);
    event AdminPropuesto(address indexed pendiente);
    event AdminAceptado(address indexed admin);
    event Pausa(bool pausado);
    event Entrega(address indexed destino, uint256 cantidad);

    modifier soloAdmin() {
        require(msg.sender == admin, "Solo admin");
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

    /// @param admin_ Administrador (dirección pasada en el constructor).
    /// @param paga_  Token PAGA de esta cadena.
    /// @param autorizado_ Contrato que podrá llamar a entregar; puede ser
    ///                    address(0) y fijarse después, una vez desplegado el
    ///                    contrato que lo usará.
    constructor(address admin_, address paga_, address autorizado_) {
        require(admin_ != address(0), "Admin cero");
        require(paga_ != address(0), "Token cero");
        admin = admin_;
        paga = IERC20(paga_);
        autorizado = autorizado_;
        if (autorizado_ != address(0)) {
            emit AutorizadoFijado(autorizado_);
        }
    }

    function disponible() public view override returns (uint256) {
        return paga.balanceOf(address(this));
    }

    function fijarAutorizado(address a) external soloAdmin {
        require(a != address(0), "Cero");
        autorizado = a;
        emit AutorizadoFijado(a);
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

    /// @notice Entrega PAGA del lote al destino. Solo el contrato autorizado.
    function entregar(address destino, uint256 cantidad) external override cuandoActivo noReentrada returns (bool) {
        require(msg.sender == autorizado, "No autorizado");
        require(destino != address(0) && destino != address(this), "Destino");
        require(cantidad > 0, "Cantidad");
        require(paga.balanceOf(address(this)) >= cantidad, "Saldo insuficiente");
        _safeTransfer(destino, cantidad);
        emit Entrega(destino, cantidad);
        return true;
    }

    function _safeTransfer(address to, uint256 amount) private {
        (bool ok, bytes memory data) = address(paga).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "Transferencia fallida");
    }
}
