// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Remix: compilador 0.8.24 | optimizer sí | 200 runs | EVM cancun
// SOLO Pagachain L3 (chain id 3690369).
// Desplegar DESPUÉS de acreditar, con la cuenta 0xF34F8d4eF363858cA5979eA41DF1b3580bb765ED.
// ENVIRONMENT: Injected Provider - MetaMask. Red: Paga (https://pagachain.com).
// No elijas Remix VM.
// Constructor (después de acreditar):
//   txAcreditar_  = hash de la transacción de acreditar (bytes32, con 0x)
//   fundadora_    = cartera de Santi Armor que recibió las PAGA
// Todo lo demás va fijo: no hay funciones de escritura y no se puede cambiar.

/// @title Memorial de la primera transacción fundadora de Pagachain.
/// @notice Solo lectura. Guarda el txid de Dogecoin, el mensaje de tres líneas
///         y el enlace a la transacción de acreditar. Se fija al desplegar.
contract MemorialFundadora {
    /// @notice Las tres líneas que están en el OP_RETURN de Dogecoin (80 bytes).
    string public constant MENSAJE =
        "1 Doge = 1 Doge y 1 Paga = 1 Paga\n1ra Transaccion. 3690369 Santi Armor\nPagachain";

    /// @notice txid de Dogecoin 340489ba34a3d4295bb7b5c5f794d5421fe8f904a50868c11f9b3d8f4cf818dd
    bytes32 public constant TXID_DOGECOIN =
        0x340489ba34a3d4295bb7b5c5f794d5421fe8f904a50868c11f9b3d8f4cf818dd;

    /// @notice Cadena y activo informados al Operador al acreditar.
    string public constant CADENA = "dogecoin";
    string public constant ACTIVO = "DOGE";

    /// @notice Operador que hizo el acreditar: 0x31b6E4FC99a0A150DeA1E8f583A1A9b9b6b5aCe6
    address public constant OPERADOR = 0x31b6E4FC99a0A150DeA1E8f583A1A9b9b6b5aCe6;

    /// @notice 24,5207 USD, con 6 decimales, tal como se pasa a acreditar.
    uint256 public constant USD = 24_520_700;

    /// @notice 245,207 PAGA, con 6 decimales (precio oficial 0,10 USD).
    uint256 public constant PAGA_ENTREGADA = 245_207_000;

    /// @notice Hash de la transacción de acreditar en Pagachain.
    bytes32 public immutable txAcreditar;

    /// @notice Cartera del equipo (Santi Armor) que recibió las PAGA, fundadora n. 1.
    address public immutable fundadora;

    constructor(bytes32 txAcreditar_, address fundadora_) {
        require(txAcreditar_ != bytes32(0), "Falta acreditar");
        require(fundadora_ != address(0), "Falta fundadora");
        txAcreditar = txAcreditar_;
        fundadora = fundadora_;
    }

    /// @notice Todo el registro, en una sola lectura.
    function datos()
        external
        view
        returns (
            string memory mensaje,
            bytes32 txidDogecoin,
            bytes32 txAcreditar_,
            address fundadora_,
            uint256 usd,
            uint256 pagaEntregada,
            string memory cadena,
            string memory activo,
            address operador
        )
    {
        return (
            MENSAJE,
            TXID_DOGECOIN,
            txAcreditar,
            fundadora,
            USD,
            PAGA_ENTREGADA,
            CADENA,
            ACTIVO,
            OPERADOR
        );
    }
}
