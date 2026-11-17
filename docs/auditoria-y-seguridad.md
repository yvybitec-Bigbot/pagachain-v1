# Seguridad y revisión externa

## Principios que ya están en el código

- El token PAGA no tiene propietario, ni mint posterior, ni pausa, ni facultad para tocar saldos ajenos.
- Los lotes del dispensador no tienen `withdraw`, `rescue` ni `retirar`. El administrador no puede sacar PAGA.
- `PagaLote` (versión del Operador) tampoco permite una retirada administrativa del inventario; solo entrega el contrato autorizado.
- Cada pago externo se identifica con un `idOrigen` de un solo uso, para no acreditar dos veces el mismo origen.
- El dispensador y el Operador usan transferencias que no se fían de un `return` booleano a ciegas (en el dispensador, `TransferenciaSegura`; la revisión pidió unificar también `PagaLotes`).
- El oráculo rechaza un salto de precio mayor del 50 %, salvo una publicación explícita del propietario.
- Si el oráculo está viejo, vacío o caído, el dispensador se considera cerrado.
- El relayer de DOGE espera 6 confirmaciones. El relayer de USDT en Tron espera la solidificación y 20 bloques más.
- Paga Wallet es de autocustodia: la frase y la clave se crean y se cifran en el dispositivo y no se envían a un servidor.

Pagos Labs no es un banco ni pretende serlo. El precio de referencia no es un derecho de rescate garantizado.

**Aviso:** Billeteras de autocustodia: úsalas bajo tu propio riesgo. Lee las reglas antes de intercambiar.

## Revisión externa — 15 nov 2026

Revisión de los contratos del Operador y de los lotes (la versión que después se desplegó en Pagachain). El texto lo aportó el equipo tras una revisión de Claude (Anthropic), el 15 nov 2026.

**Veredicto de esa revisión:** no fondear todavía. Tras corregir los puntos críticos y altos: «sí con cambios».

Lo que la revisión dio por correcto en esa versión:

- Sin overflow ni reentrada en lo revisado.
- Los tramos suman `1.686.127.428` PAGA (el 90 % de `1.873.474.920`).
- Fechas 6 dic 2026–2030, 00:00 UTC.
- Precios `0,10` / `0,20` coherentes con el diseño de entonces.

### Críticos

1. `PagaLotes.liberar` decide por el saldo real del lote (menos de 1 PAGA). Una donación pequeña (1 a 4,99 PAGA) puede bloquear tramos y alargar los reintentos de 300 días. Propuesta: contabilidad interna, permitir intercambiar el remanente bajo el mínimo, o abrir por tiempo tras N reintentos.
2. Configuración irreversible y acoplada: un aviso puede revertir `liberar` si `Operador.pagaLotes` no está fijado; `fijarDestino` no validaba; la tesorería es inmutable. Propuesta: fijar en el constructor (CREATE2), `try/catch` en el aviso, validar el destino, tesorería con más de una firma.
3. `Operador.acreditar` confía en el relayer sin topes; el administrador puede cambiar el relayer con libertad. Propuesta: topes por transacción y por día, más de una firma o 2-de-N, demora al cambiar el relayer, e `idOrigen` calculado on-chain.

### Altos

4. `PagaLote.fijarAutorizado` se puede cambiar siempre: un administrador comprometido podría vaciar el lote a través de un autorizado nuevo. Propuesta: una sola vez, o demora + más de una firma.
5. Remanente: el administrador elige la dirección de bloqueo con libertad; no hay valor por defecto; la pausa es indefinida; enviar a `0xdEaD` no baja el `totalSupply`. Propuesta: solo `PagaBloqueoPermanente` verificado, valor por defecto y pausa limitada.
6. La fundadora 369 podría no confirmar nunca y dejar la recompensa bloqueada. Propuesta: congelar la base al llenar el cupo y permitir la confirmación por cualquiera o tras un plazo.
7. Recompensa de fundadoras sin tope, acaparable con 369 carteras; no se comprueba que el lote complementario tenga fondos. Propuesta: tope por cartera y exigir cobertura o prorrateo.

### Medios

8. Pausa sin límite en Operador y `PagaLote`.
9. La cifra de PAGA intercambiado cuenta los 500 del lote de prueba; el remanente no se puede tomar por partes; no hay tope por operación; el reloj empieza en el despliegue, no en la apertura pública.
10. Los pagos externos son de confianza en el relayer: hay que exigir confirmaciones y una demora en importes altos.
11. No hay verificación al fondear (cantidad exacta y autorizado). Conviene una función de comprobación previa.

### Bajos / informativos

- Unificar `require(transfer)` con `safeTransfer`.
- `rescatar` contra los lotes es inútil; hay código muerto; `confirmarConFirma` sin caducidad ni EIP-1271.
- Los contratos no coincidían con un estudio económico más antiguo (otras cifras de suministro y de reparto). Había que confirmar el plan vigente — y, de hecho, el suministro en cadena es `1.873.474.920`, no la cifra antigua.
- Para una auditoría completa faltaban entonces el token PAGA, el relayer, los scripts de despliegue y más pruebas.

## Qué se hizo después, y qué no

- **No se fondeó el inventario principal.** Tras el despliegue del 12 nov 2026 solo se enviaron `500` PAGA de prueba al lote del Operador. Quedó explícito no liberar lotes, no fondear el complementario y no transferir `1.686.127.428` PAGA hasta una autorización posterior.
- **Se escribió un rediseño v2** (`contracts/v2/`), solo local, con 78 pruebas. Incorpora, entre otras cosas: contabilidad interna y ventanas de tiempo, tope por cartera para fundadoras, demora de 48 h al cambiar el relayer (revocación inmediata), pausa limitada, bloqueo permanente como destino por defecto, poderes de administración en una lista cerrada, y un dispensador de faucet y bots separado. Ese árbol no se ha desplegado y no sustituye a los contratos que ya están en cadena.
- **El dispensador DOGE (lote 1)** es una pieza aparte, posterior, con inventario propio, sin retirada y con reglas de apertura on-chain. Se puso en uso el 17 nov 2026 tras pruebas locales y dos intercambios reales de comprobación.
- Esta documentación **no es una auditoría nueva**. Recoge la revisión del 15 nov 2026 y el estado posterior del código. Un cliente que reutilice estas piezas debería encargar su propia revisión, sobre el árbol que vaya a desplegar, e incluir también el token, los relayers y el procedimiento de despliegue.
