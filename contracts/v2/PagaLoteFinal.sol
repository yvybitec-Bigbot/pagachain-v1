// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {PagaLote} from "./PagaLote.sol";

/// @title PagaLoteFinal — 303.502.937 PAGA, ventana día 2000 – día 2300.
contract PagaLoteFinal is PagaLote {
    uint256 public constant ASIGNACION_FINAL = 303_502_937 * 1e6;

    constructor(address admin_, address paga_, uint256 inicio_, address operador_, address bloqueo_)
        PagaLote(admin_, paga_, inicio_, operador_, bloqueo_, ASIGNACION_FINAL, 2000, 2300)
    {}
}
