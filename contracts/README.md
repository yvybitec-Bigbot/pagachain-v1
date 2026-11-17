# Fuentes de contratos (Pagachain v1)

Copia de los fuentes públicos incluidos en esta versión inicial. No hay scripts de despliegue, ni claves, ni archivos de entorno.

Cada contrato se explica en [docs/biblioteca-de-contratos.md](../docs/biblioteca-de-contratos.md): para qué sirve, en qué estado está y cuándo reutilizarlo.

| Carpeta | Qué contiene | Estado |
|---|---|---|
| `paga/` | Token PAGA (ERC-20, 6 decimales, emisión única) | En cadena |
| `oraculo/` | Oráculo DOGE/USD (8 decimales) | En cadena |
| `dispensador-doge/` | Lote 1 del dispensador DOGE→PAGA | En cadena y en uso |
| `dispensador-doge-lote2/` | Lote 2 (mismo precio fijo, otro rango de apertura) | Solo local; no desplegado |
| `operador/` | Lote reutilizable, calendario de lotes, Operador y bloqueo permanente | Contratos en cadena; el inventario principal no se ha fondeado |
| `v2/` | Rediseño posterior a la revisión externa (15 nov 2026) | Solo pruebas locales; no sustituye a lo desplegado |
| `memorial/` | Contrato de solo lectura que recuerda la primera transacción fundadora | Fuente lista para Remix |
| `historico/` | Borrador inicial de `PagaLotes`, sustituido por `operador/PagaLotes.sol` | No usar en un despliegue nuevo |

Compilador de referencia: Solidity 0.8.24, EVM cancun, optimizador activado, 200 runs (el token PAGA se compiló en 0.8.34, EVM cancun).
