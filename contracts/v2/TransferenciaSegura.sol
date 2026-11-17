// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./IERC20.sol";

/// @title TransferenciaSegura
/// @notice safeTransfer / safeTransferFrom: acepta tokens que devuelven `true` o nada; revierte en cualquier otro caso.
library TransferenciaSegura {
    error TransferenciaFallida();

    function enviar(IERC20 token, address to, uint256 value) internal {
        _llamar(token, abi.encodeCall(IERC20.transfer, (to, value)));
    }

    function enviarDesde(IERC20 token, address from, address to, uint256 value) internal {
        _llamar(token, abi.encodeCall(IERC20.transferFrom, (from, to, value)));
    }

    function _llamar(IERC20 token, bytes memory datos) private {
        (bool ok, bytes memory ret) = address(token).call(datos);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool))) || address(token).code.length == 0) {
            revert TransferenciaFallida();
        }
    }
}
