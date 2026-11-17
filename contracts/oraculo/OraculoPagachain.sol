// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title OraculoPagachain
/// @notice Publica el precio DOGE/USD en Pagachain (8 decimales) para dar
///         actividad on-chain transparente. Solo el publicador puede escribir
///         precios; el dueño gestiona el publicador y puede anular el tope
///         de desviación del 50 %.
contract OraculoPagachain {
    struct Precio {
        uint256 price;
        uint64 timestamp;
        uint80 round;
    }

    address public owner;
    address public publisher;

    Precio private _latest;

    string public constant SOURCE = "DOGE/USD";
    uint8 public constant DECIMALS = 8;

    event PrecioPublicado(uint80 indexed round, uint256 price, uint64 timestamp, string source);
    event PublisherUpdated(address indexed previousPublisher, address indexed newPublisher);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error OnlyOwner();
    error OnlyPublisher();
    error ZeroAddress();
    error InvalidPrice();
    error StaleTimestamp();
    error FutureTimestamp();
    error PriceDeviationTooHigh();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyPublisher() {
        if (msg.sender != publisher) revert OnlyPublisher();
        _;
    }

    /// @param owner_ Dirección dueña (en Pagachain: el admin que firma en Remix).
    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    function setPublisher(address publisher_) external onlyOwner {
        if (publisher_ == address(0)) revert ZeroAddress();
        address previous = publisher;
        publisher = publisher_;
        emit PublisherUpdated(previous, publisher_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address previous = owner;
        owner = newOwner;
        emit OwnershipTransferred(previous, newOwner);
    }

    /// @notice Publica un precio. Rechaza un cambio mayor al 50 % respecto
    ///         al último, marcas de tiempo antiguas o más de 5 minutos en el futuro.
    function publicar(uint256 price, uint64 timestamp) external onlyPublisher {
        _publicar(price, timestamp, false);
    }

    /// @notice Igual que publicar, pero el dueño puede saltarse el tope del 50 %.
    function publicarConOverride(uint256 price, uint64 timestamp) external onlyOwner {
        _publicar(price, timestamp, true);
    }

    function latest() external view returns (uint256 price, uint64 timestamp, uint80 round) {
        Precio memory p = _latest;
        return (p.price, p.timestamp, p.round);
    }

    /// @notice Compatible con AggregatorV3Interface de Chainlink.
    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    function description() external pure returns (string memory) {
        return SOURCE;
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        Precio memory p = _latest;
        // price is rejected in _publicar if it does not fit in int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (p.round, int256(p.price), uint256(p.timestamp), uint256(p.timestamp), p.round);
    }

    function _publicar(uint256 price, uint64 timestamp, bool overrideDeviation) internal {
        if (price == 0 || price > uint256(type(int256).max)) revert InvalidPrice();
        if (timestamp > block.timestamp + 5 minutes) revert FutureTimestamp();

        Precio memory last = _latest;
        if (last.round != 0 && timestamp <= last.timestamp) revert StaleTimestamp();

        if (last.round != 0 && !overrideDeviation) {
            uint256 lastPrice = last.price;
            uint256 diff = price > lastPrice ? price - lastPrice : lastPrice - price;
            // Rechaza un cambio estrictamente mayor al 50 %.
            if (diff * 2 > lastPrice) revert PriceDeviationTooHigh();
        }

        uint80 round = last.round + 1;
        _latest = Precio({price: price, timestamp: timestamp, round: round});
        emit PrecioPublicado(round, price, timestamp, SOURCE);
    }
}
