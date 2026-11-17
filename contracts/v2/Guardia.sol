// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Guardia — protección contra reentrada.
abstract contract Guardia {
    uint256 private _estado = 1;

    error Reentrada();

    modifier noReentrada() {
        if (_estado != 1) revert Reentrada();
        _estado = 2;
        _;
        _estado = 1;
    }
}
