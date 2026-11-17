# Biblioteca de contratos

Catálogo reutilizable de los contratos escritos para Pagachain v1. Un cliente puede tomar una pieza, cambiar los parámetros (token, precio, rango, fechas, tamaño del lote) y montar su propia L3 o un módulo suelto, sin tener que reescribir la lógica de cero.

En esta biblioteca se habla de *intercambio*, nunca de otra figura. Pagos Labs no es un banco ni pretende serlo.

**Aviso:** Billeteras de autocustodia: úsalas bajo tu propio riesgo. Lee las reglas antes de intercambiar.

Los fuentes están en `contracts/`. Aquí solo se describe el caso de uso y el estado. Las cantidades y direcciones son las que aparecen en esos fuentes y en las notas de despliegue; no se inventan cifras.

## Cómo leer el estado

- **En cadena y en uso:** desplegado y operando con inventario o servicio real.
- **En cadena, inventario pendiente:** el contrato existe en Pagachain, pero el inventario principal no se ha transferido.
- **Solo local:** compilado y probado con Foundry; no está desplegado.
- **Borrador histórico:** quedó sustituido por una versión posterior; se conserva para no perder el trabajo.

---

## 1. Token y gas

### 1.1 `Paga` — token de la cadena

- **Fuente:** `contracts/paga/Paga.sol`
- **Dirección en Pagachain:** `0xbfE1D53cb99f5873E3d62EfaAc4F7d0cC2f94b9A`
- **Estado:** en cadena (desplegado el 8 nov 2026).
- **Caso de uso:** ERC-20 simple con nombre `Paga`, símbolo `PAGA` y 6 decimales. El suministro se acuña una sola vez en el constructor, al desplegador. No hay mint posterior, ni propietario, ni pausa, ni confiscación, ni bloqueo de usuarios. Rechaza envíos a la dirección cero.
- **Suministro:** `1.873.474.920` PAGA. En el propio fuente queda la base de cálculo: `2.628.000.000` DOGE × `0,071289` USD / `0,10` USD (precio del 8 nov 2026, 16:22, Europe/London).
- **Para reutilizar:** cambiar nombre, símbolo, decimales y la cifra del constructor. Mantener la emisión única si se quiere un suministro fijo e inmutable.

El gas nativo de Pagachain no es PAGA: es **CENT** (18 decimales). El predespliegue habitual de OP Stack `0x4200000000000000000000000000000000000006` es Wrapped Cent (WCENT). Un cliente puede cubrir el gas de sus usuarios con un servicio de recarga que envía una cantidad pequeña de gas a carteras que ya tienen el token de la aplicación, para que la app no tenga que mostrar el token de gas.

### 1.2 `OraculoPagachain` — precio DOGE/USD

- **Fuente:** `contracts/oraculo/OraculoPagachain.sol`
- **Dirección en Pagachain:** `0xc4E8c11dCe3D664AA8Aef6b14E0CA2910e3B3Dc4`
- **Estado:** en cadena y en uso.
- **Caso de uso:** publica el precio DOGE/USD con 8 decimales. El propietario fija un publicador. El publicador llama a `publicar(precio, timestamp)`. Se guarda `{price, timestamp, round}` y se emite `PrecioPublicado`. La lectura es `latest()` y también `latestRoundData()` (compatible con `AggregatorV3Interface`). Si el precio se mueve más de un 50 % respecto al último, la transacción revierte, salvo que el propietario use `publicarConOverride`.
- **Publicación:** al menos tres veces al día. El servicio toma la mediana de al menos dos de estas fuentes: Coinbase, Kraken y CoinGecko. Temporizador: 00:00, 08:00 y 16:00 UTC.
- **Para reutilizar:** el mismo contrato sirve para otro par (cambiando la etiqueta y las fuentes del publicador). El recargo de data de OP Stack, leído del predespliegue `GasPriceOracle`, es irrelevante frente al coste de gas nativo (unas `0,00000341` CENT al mes a tres publicaciones diarias, según la medición del 15 nov 2026).

---

## 2. Dispensador automático por rango de precio

Piezas pensadas para un lote cerrado de tokens, sin recarga y sin retirada, que se intercambia por un activo externo (aquí, DOGE nativo) solo mientras el oráculo está en un rango. El inventario queda bloqueado en el contrato: ni el administrador puede sacarlo. El administrador solo puede cambiar el relayer y pausar o reanudar.

Fórmula, en ambos lotes, con PAGA fijo a `0,10` USD:

`PAGA = DOGE × precioDOGE / 0,10` (se trunca hacia abajo, 6 decimales).

Ejemplo del diseño del lote 1: `1.000` DOGE a `0,057` USD → `570` PAGA. En el lote 2, con el DOGE a `0,15` USD, `1.000` DOGE dan `1.500` PAGA.

`idOrigen` es `keccak256` del txid de Dogecoin (32 bytes) y no se puede repetir.

### 2.1 `LoteDispensadorDoge` (lote 1)

- **Fuente:** `contracts/dispensador-doge/LoteDispensadorDoge.sol`
- **Dirección:** `0xc0be31904869A9d2cF147B16C9A60C36b4896f6f`
- **Relayer:** `0x6EDb9882E502DC75c67eb6752148e6a0282dF3E4`
- **Administrador (constructor):** `0xF34F8d4eF363858cA5979eA41DF1b3580bb765ED`
- **Estado:** en cadena y en uso desde el 17 nov 2026. Tamaño: `3.690.369` PAGA. Sin recarga y sin retirada.
- **Apertura:** solo si el oráculo está fresco y el precio del DOGE es **menor que** `0,10` USD (`precio < 10_000_000` en 8 decimales; último tick abierto: `9.999.999` = `0,09999999` USD). En `0,10` o más, se cierra solo.
- **Frescura:** en el contrato, `maxEdadOraculo = 93.600` segundos (26 horas). El servicio del relayer es más estricto: 9 horas, porque el oráculo publica cada 8 horas. Se admite una holgura de 5 minutos si la marca de tiempo del oráculo va un poco por delante del bloque.
- **Tope por transacción:** `0` (sin tope aparte del restante).
- **Caso de uso:** intercambiar cuando el activo externo cotiza por debajo del precio fijo del token de la L3. El DOGE recibido permanece en la cartera de garantía pública `DKZayo26HFgFhttAWQSqMUBxmNLQR7irJd`. No se reparte ni se intercambia por otra cosa. La transacción fundadora de esa cartera (13 nov 2026, `369,0369` DOGE, txid `340489ba34a3d4295bb7b5c5f794d5421fe8f904a50868c11f9b3d8f4cf818dd`) se ignora a propósito.
- **Pruebas:** 24 pruebas locales con Foundry. El 17 nov 2026, dos intercambios reales acreditaron exactamente lo cotizado tras 6 confirmaciones de Dogecoin (unos 15 minutos de punta a punta).
- **Widget (pie del explorador, no en la web de Pagos Labs):** botones por cantidad de PAGA que recibe la persona (`10`, `30`, `50`, `100`, `300`, `600`, `3.000`, `10.000`). El widget calcula el DOGE exacto a enviar y muestra un QR. No hay que teclear el importe a mano. Cotización con etiqueta de 4 decimales y caducidad de 60 minutos. Un solo recuadro «⚠️ Aviso» cubre tres casos: enviar otra cantidad, enviar desde un exchange (descuentan comisión) o tardar más de 60 minutos. Texto de cabecera: *«Cuando 1 PAGA vale más que 1 DOGE, fortalece nuestras garantías intercambiando aquí.»*

### 2.2 `LoteDispensadorDoge` (lote 2)

- **Fuente:** `contracts/dispensador-doge-lote2/LoteDispensadorDoge.sol`
- **Estado:** solo local; no está desplegado ni fondeado. 21 pruebas locales.
- **Caso de uso:** el mismo contrato, con el rango de precio parametrizado en el constructor. El PAGA sigue fijo a `0,10` USD. Abierto cuando `10_000_000 <= precio <= 19_000_000` (DOGE entre `0,10` y `0,19` USD, ambos inclusive). En `19_000_001` (`0,19000001`) o más, se cierra. Si el precio vuelve al rango, se reabre solo, hasta que se agote el lote.
- **Relación con el lote 1:** no se solapan y no hay hueco. En `0,10` USD exacto el lote 1 está cerrado y el 2 abierto. Nunca están abiertos los dos a la vez.
- **Tamaño previsto:** `3.690.369` PAGA, sin retirada y sin recarga, igual que el lote 1.
- **Widget (borrador, no publicado):** *«Aprovecha: obtén PAGA con descuento intercambiando aquí.»* La frase «intercambiando aquí» es el botón y abre el mismo flujo de botones y QR. Endpoints previstos, distintos de los del lote 1: `/api/dispensador-lote2/estado` y `/api/dispensador-lote2/cotizar`. El relayer debe guardar el lote de cada cotización: si el precio se cruza entre cotizar y las 6 confirmaciones, no se acredita en el otro lote.
- **Pendiente al desplegar:** si se reutiliza el mismo relayer `0x6EDb9882E502DC75c67eb6752148e6a0282dF3E4` o se usa uno nuevo.

### 2.3 Lógica pública del relayer DOGE

No es un contrato; es el servicio que vigila la cartera de garantía (solo lectura: no tiene su clave), casa cada ingreso con una cotización y llama a `dispensar(destino, dogeAmount, idOrigen)`.

1. La persona pide una cotización con su cartera Pagachain y el importe. Si el lote está cerrado, se rechaza. Si está abierto, recibe un importe exacto con 4 decimales y una caducidad (60 minutos).
2. El servicio consulta APIs públicas de Dogecoin y espera 6 confirmaciones.
3. Casa por importe exacto, creado antes del ingreso y aún no caducado. Sin cotización, varias coincidencias, o lote cerrado al casar: se anota para revisión; el DOGE no se mueve.
4. Calcula el PAGA con el precio del oráculo **en el momento de acreditar**, simula la llamada y, si está autorizado a enviar, llama a `dispensar`.

Este patrón (una sola dirección de cobro + importe etiquetado + confirmaciones + `idOrigen` único) evita crear una dirección de depósito por cliente.

---

## 3. Operador, lotes de adopción y bloqueo (versión desplegada)

Estas piezas forman el sistema de lotes calendarios y de acreditación por un relayer cuando el pago ocurre **fuera** de Pagachain (estables u otros activos en otras cadenas). El Operador no crea PAGA: solo lo saca de un lote que se le ha fondeado.

### 3.1 `PagaLote` — lote bloqueado reutilizable

- **Fuente:** `contracts/operador/PagaLote.sol`
- **Desplegado (12 nov 2026):**
  - Lote del Operador: `0xbA525fa741cd8B1fa359Ba48D251AA729423bF87`
  - Lote complementario: `0x39dfF4bb8128A9b5f24BF3c1F7A6CE61Edd6cCDd`
- **Estado:** en cadena. El lote del Operador recibió solo un lote de prueba de `500` PAGA (`50` USD a `0,10`). El lote complementario está a cero. No se ha transferido el inventario de `1.686.127.428` PAGA.
- **Caso de uso:** caja estándar de un lote. Se crea de una en una. Se fondea enviando PAGA a su dirección (`disponible()` es el saldo; no hay tope fijo). Solo entrega a través del contrato autorizado. El administrador no puede retirar PAGA. Puede cambiar el contrato autorizado y pausar.
- **Para reutilizar:** es la pieza más genérica de la biblioteca. Sirve para cualquier inventario que deba salir solo por un contrato autorizado, sin vía de escape administrativa.

### 3.2 `PagaLotes` — calendario de cinco lotes

- **Fuente:** `contracts/operador/PagaLotes.sol`
- **Dirección:** `0xe648A95248397C3c5Fc025C33C14214D5Fe110c0`
- **Estado:** en cadena, inventario principal sin fondear. Destino inmutable: el lote del Operador.
- **Caso de uso:** custodia programada de `1.686.127.428` PAGA (el 90 % del suministro). Fechas y cantidades inmutables. `liberar` puede llamarla cualquiera.

| Lote | Fecha (00:00 UTC) | Cantidad | Parte |
|---|---|---:|---|
| 0 (adopción) | 6 dic 2026 | 281.021.238 | 15 % |
| 1 | 6 dic 2027 | 281.021.238 | 15 % |
| 2 | 6 dic 2028 | 374.694.984 | 20 % |
| 3 | 6 dic 2029 | 374.694.984 | 20 % |
| 4 | 6 dic 2030 | 374.694.984 | 20 % |
| **Total** | | **1.686.127.428** | **90 %** |

El lote 0 se abre por fecha. Un lote siguiente solo se abre si al destino (el lote del Operador) le queda menos de 1 PAGA; si no, el intento se aplaza 300 días y se puede reintentar, sin límite de ciclos. El 10 % restante (`187.347.492` PAGA) quedó fuera de estos cinco lotes (promoción, gas y el lote de prueba de 500 PAGA, que se sacó de esa parte).

### 3.3 `Operador` — acreditación desde pagos externos

- **Fuente:** `contracts/operador/Operador.sol`
- **Dirección:** `0x31b6E4FC99a0A150DeA1E8f583A1A9b9b6b5aCe6`
- **Estado:** en cadena. Relayer inicial en el despliegue: la misma dirección de administración. Hay un relayer específico preparado (`0xa80159f5ec87E940F2B1F77B7eb36F4053ADE1B6`) para el servicio de USDT en Tron; el cambio on-chain y el envío automático quedaron pendientes de autorización.
- **Caso de uso:** un relayer autorizado informa de un pago recibido fuera de la L3 (`acreditar`: destino, importe en USD, cadena, activo, `idOrigen`). El PAGA sale del lote del Operador. Precio: `0,10` USD durante los dos primeros años desde el `block.timestamp` del constructor, o hasta agotar el lote de adopción de `281.021.238` PAGA (lo que ocurra antes); después, `0,20` USD para siempre. Mínimo `1,00` USD. A los 6 años se deja de acreditar; el remanente se puede bloquear o quemar (los dos caminos están en el código; la decisión quedó abierta). Las primeras 369 carteras distintas (a partir de 1 USD) quedan registradas como fundadoras. Hay un aviso al llegar a la 300. Quien cierra el cupo puede confirmar con transacción directa o con firma EIP-712 enviada por un relé. Tras confirmar, se puede entregar una cantidad complementaria desde el segundo lote.
- **Reparto operativo documentado en esta versión:** 70 % hacia DOGE (el contrato emite `ConversionPendiente`; la conversión ocurre fuera de la L3) y 30 % de reserva operativa. Si el pago ya es DOGE, no se emite conversión.
- **Seguridad incluida:** cambio de administrador en dos pasos; `idOrigen` de un solo uso; anti-reentrada en las salidas principales; destinos prohibidos (cero, el propio Operador y ambos lotes); `rescatar` no puede apuntar a los lotes.
- **Para reutilizar:** patrón «pago fuera de la cadena + relayer + acreditación on-chain con identificador único», útil en cualquier L3 que cobre en otras redes.

### 3.4 `PagaBloqueoPermanente` — sumidero sin salida

- **Fuente:** `contracts/operador/PagaBloqueoPermanente.sol` (hay una variante equivalente en `contracts/v2/`)
- **Estado:** fuente incluido; camino preparado para el remanente a 6 años si se elige bloquear en lugar de quemar. El token PAGA rechaza `address(0)`, por eso existe este contrato (o el sumidero `0x…dEaD`).
- **Caso de uso:** recibir PAGA y no tener ninguna función para sacarlo. Lo enviado aquí sale de circulación (no reduce por sí solo el `totalSupply`). Sirve como «quema lógica» cuando no se quiere, o no se puede, enviar a la dirección cero.

### 3.5 Lógica pública del relayer de estables (Tron / USDT, v1)

Servicio escrito y probado en local. Por defecto no envía nada a ninguna cadena: prepara los valores de `acreditar` para una firma en Remix. El envío automático existe, pero estaba apagado.

1. Antes de pagar se apunta un intento: cartera Pagachain de destino y cartera de origen en Tron (y, si se quiere, el importe exacto). El servicio nunca adivina el destino.
2. Llega USDT a la cartera de recepción. Se espera a que Tron dé el bloque por definitivo y, además, 20 bloques. El importe se lee del recibo, no de una lista.
3. Se casa el intento. Sin intento, ambiguo, menos de 1 USDT o más de 100 USDT (tope de seguridad de esta v1): no se acredita solo.
4. `usd` = USDT recibido (6 decimales; 1 USDT = 1 USD). Ejemplo: 1 USDT → `1.000.000` unidades → 10 PAGA a `0,10`.
5. `idOrigen = keccak256(abi.encode("tron", "USDT", txid))`.
6. Se simula `acreditar` y, si procede, se deja listo o se envía. El contrato rechaza un `idOrigen` repetido, así no se acredita dos veces el mismo pago.

Límites de esta v1: una cadena (Tron) y un activo (USDT). El mismo esquema se puede copiar a otras cadenas y otros estables.

---

## 4. Rediseño v2 (posterior a la revisión externa)

- **Fuentes:** `contracts/v2/`
- **Estado:** solo local. 78 pruebas (unitarias, fuzz e invariantes). No hay scripts de despliegue. **No sustituye ni toca** el Operador ni los `PagaLotes` ya desplegados.
- **Caso de uso:** recoger las correcciones de la revisión del 15 nov 2026 (ver [auditoria-y-seguridad.md](auditoria-y-seguridad.md)) y dejar un diseño cerrado, listo para que un cliente lo tome como base más conservadora.

Piezas:

| Contrato | Para qué |
|---|---|
| `PagaOperador` | Intercambio de CENT por PAGA a precio fijo, acreditaciones del relayer (externo y bots), faucet, cubo global con trinquete, registro de fundadoras, relayer con demora de 48 h (la revocación es inmediata) y pausa limitada. |
| `PagaLote` (base) | Lote con ventana de tiempo fija. Se abre solo por tiempo, y solo si está fondeado. Contabilidad interna de salidas. |
| `PagaLoteImplementacion` | `674.450.971` PAGA, ventana día 730–1030. Reserva `147.600.000` para fundadoras (intercambiable: `526.850.971`). Al abrir, una salida única hacia el contrato de fundadoras, llamable por cualquiera. |
| `PagaLoteFinal` | `303.502.937` PAGA, ventana día 2000–2300. |
| `PagaFundadoras` | Reclamo individual. Plazo de 1 año desde el fondeo. Lo no reclamado va al bloqueo. Tope computable de `200.000` PAGA por cartera; recompensa `2×`. |
| `PagaDispensador` | Dos partes separadas: faucet de `1.000.000` PAGA (`0,5` PAGA una vez por cartera, tope `5.000` PAGA/día = 10.000 carteras nuevas) y `707.173.520` PAGA para bots, acreditados por el relayer cuando se recibe PLS fuera de Pagachain. |
| `PagaBloqueoPermanente` | Sumidero sin salida, sin administrador. |
| `PagaTiempo`, `PausaLimitada`, `Guardia`, `TransferenciaSegura` | Regla de frontera temporal única (el segundo exacto pertenece al periodo nuevo), pausa con límite, anti-reentrada y `safeTransfer`. |

Decisiones recogidas en este diseño (15 nov 2026):

- Antes del día 730, la fuente de PAGA es la adopción (autorización limitada). Desde el día 730, solo un lote abierto (Implementación y luego Final). Sin lote abierto, los intercambios revierten: el Operador descansa (días 1030–2000 y desde el 2300).
- Nadie intercambia CENT por PAGA hasta que se cierre la cuenta de fundadoras (entra la cartera 369 o se alcanza el día 730).
- El administrador tiene una lista cerrada de poderes, probada en tests: pausar y reanudar, revocar relayer y proponer relayer. Fundadoras, dispensador y bloqueo no tienen poderes de administración.
- El registro de fundadoras nunca bloquea una acreditación.

Regla de tiempo: el día N se alcanza cuando `block.timestamp >= START + N * 86400`.

---

## 5. Otras piezas

### 5.1 `MemorialFundadora`

- **Fuente:** `contracts/memorial/MemorialFundadora.sol`
- **Estado:** fuente listo para Remix; contrato de solo lectura.
- **Caso de uso:** deja en cadena un recuerdo de la primera transacción fundadora (mensaje de tres líneas, txid de Dogecoin y enlace a la acreditación). No tiene funciones de escritura. Útil como ejemplo de contrato conmemorativo, no como pieza de intercambio.

### 5.2 Borrador histórico de `PagaLotes`

- **Fuente:** `contracts/historico/PagaLotes-borrador-inicial.sol`
- **Estado:** sustituido, en el trabajo local, por `operador/PagaLotes.sol`. Se conserva para trazabilidad. No usarlo en un despliegue nuevo: las fechas de los rótulos y el destino difieren de la versión posterior, que es la que se desplegó.

### 5.3 Interfaces de apoyo

- `operador/IERC20.sol`, `IPagaLote.sol`, `IAvisoApertura.sol`
- `v2/IERC20.sol`, `Interfaces.sol`

---

## 6. Qué no está en esta biblioteca (a propósito)

- Scripts de despliegue, archivos de entorno o claves.
- El código fuente de Paga Wallet (aplicación de autocustodia; no forma parte de este paquete).
- Una implementación on-chain del cobro de DOGE nativo: Dogecoin no es EVM; el cobro lo hace el relayer y la garantía se queda en la cartera pública de Dogecoin.
- Los megalotes posteriores (un lote eterno por DOGE, otro por PLS y otro por estables, más una partida de adopción) eran una idea de simplificación posterior a esta v1. No hay contrato de esos megalotes en este paquete.

## 7. Guía rápida para un cliente

1. Si solo necesita un token fijo: tome `Paga`.
2. Si necesita un precio público: tome `OraculoPagachain` y un publicador con varias fuentes y una mediana.
3. Si quiere un lote que abre y cierra solo, según un rango de precio, sin que nadie pueda retirar el inventario: tome `LoteDispensadorDoge` (lote 1 o lote 2) y el patrón del relayer por importe etiquetado.
4. Si quiere un calendario de inventario a varios años: tome `PagaLotes` + `PagaLote`.
5. Si el pago llega desde otra cadena: tome `Operador` (v1) o `PagaOperador` (v2, con más topes y pausa limitada).
6. Si quiere sacar inventario de circulación sin mint inverso: tome `PagaBloqueoPermanente`.
7. Si parte de cero y puede elegir: el árbol `v2/` es la base más conservadora, porque ya incorpora la revisión externa. El árbol `operador/` es el que está en cadena en esta v1, con el inventario principal aún pendiente de fondear.
