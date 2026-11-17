# Cómo construir tu propia L3

Guion práctico, basado en lo que se montó para Pagachain v1. No es un manual de un proveedor concreto ni una receta de servidores. Sirve para que un equipo vea las piezas y el orden, y reutilice la [biblioteca de contratos](biblioteca-de-contratos.md).

Pagos Labs construye infraestructura de cadena para que otros monten su propio ecosistema. Esta v1 es una implementación de referencia, no un producto bancario.

## 1. Acordar las reglas antes del código

- Qué token usa la cadena para gas (en Pagachain, CENT) y qué token de aplicación se emite (PAGA).
- Si el suministro es fijo y de una sola acuñación.
- Precio de referencia, si lo hay, y si es inmutable en cada lote.
- Qué parte del inventario queda para adopción, qué parte se intercambia de forma automática y qué parte, si hay, se reserva para operación.
- Qué activos externos se aceptan (una cripto nativa, un estable en otra cadena, el gas de otra red…).
- Qué puede hacer el administrador, y qué no podrá hacer nunca (en esta v1, no sacar el PAGA de un lote del dispensador).
- Escribir esas reglas en el contrato desde el día uno. Si un precio debe pasar de `0,10` a `0,20` a los dos años, la fecha o el recuento de días tienen que estar en el código, no en una decisión posterior.

## 2. Levantar la cadena (OP Stack)

Pagachain es una L3 compatible con EVM, construida con OP Stack.

Piezas habituales:

- **Cliente de ejecución** (en esta v1, `op-reth`): produce bloques y sirve el RPC.
- **op-node:** deriva el estado y, si corresponde, secuencia.
- **op-batcher:** publica los lotes de datos en la capa de asentamiento. Si esa capa no tiene blobs, se usa calldata.
- **op-proposer:** publica las propuestas de estado (juegos de disputa, según la versión de contratos).

Decisiones que hay que tomar, y dejar por escrito:

- Identificador de cadena. El de Pagachain es `3690369` (`0x384f81`). Hay que comprobar que esté libre antes de usarlo.
- Tiempo de bloque y límite de gas.
- Tipo de disponibilidad de datos (calldata u otro).
- Qué se publica en el RPC de cara al público (`https://pagachain.com` en esta v1) y qué queda solo en la red interna.
- Cómo se paga el gas del batcher y del proposer en la capa de asentamiento, sin mezclar esas reservas con el inventario del token de aplicación.

No hace falta inventar una máquina virtual: al ser EVM, cualquier cartera ya existente puede añadir la red (nombre, chain id, RPC, símbolo de gas, explorador).

## 3. RPC, explorador y límites reales

- Un RPC HTTPS público, con CORS si el explorador o la cartera van a llamarlo desde el navegador. Pagachain Explorer es una página estática: el navegador habla con `https://pagachain.com`. Hay un proxy `/rpc` por si eso cambia.
- Un explorador con rutas EIP-3091 (`/block/`, `/tx/`, `/address/`, `/token/`). El de esta v1 está en `https://explorer.pagachain.com`.
- Contar con los límites del cliente: `op-reth` limita `eth_getLogs` a **100.000 bloques** por consulta. El historial hay que paginarlo. Los clientes HTTP de esta v1 envían un `User-Agent` al hablar con el RPC.
- Los bloques que solo llevan la transacción de sistema de OP Stack se pueden ocultar por defecto, para que el explorador sea legible.

## 4. Desplegar el token y, si hace falta, el oráculo

1. Compilar y desplegar el token (emisión única, decimales acordados). En Pagachain se usó Remix, Solidity 0.8.34, EVM cancun, y la administración firmó fuera del repositorio.
2. Anunciar el suministro, la fuente del precio de cálculo si lo hubo, y la fecha.
3. Si algún contrato depende de un precio: desplegar el oráculo, fijar el publicador, darle gas nativo y publicar con varias fuentes y una mediana. Un oráculo viejo debe cerrar los intercambios, no dejarlos abiertos con un dato caducado.

## 5. Elegir los módulos de inventario

Ver la guía rápida al final de la [biblioteca](biblioteca-de-contratos.md). El patrón más simple de esta v1, y el que ya está en uso, es el lote del dispensador:

- Un contrato por lote, con reglas fijas y públicas (precio, rango, cantidad).
- Sin retirada y, si se desea, sin recarga.
- Un widget que muestra si está abierto o cerrado y no pide teclear el importe.
- Un relayer que espera confirmaciones y acredita con un `idOrigen` único.

El calendario `PagaLotes` + `Operador` sirve cuando el inventario se libera por fechas y el pago llega desde otras cadenas. El árbol `v2/` es la base más conservadora si se puede partir de cero después de la revisión externa.

## 6. Relayers (pagos que no caben en el EVM)

Dogecoin, Tron u otras redes no se «ven» solas desde la L3. Hace falta un servicio que:

- solo vigile una dirección de cobro (sin tener su clave);
- identifique al destinatario con una cotización o un intento previo, no adivinando;
- espere confirmaciones suficientes;
- simule la llamada on-chain y use un identificador único;
- deje un modo seco (preparar, no enviar) hasta que el equipo autorice el envío automático.

No mezclar la clave del relayer con la de la tesorería ni con la de la cartera de garantía.

## 7. Cartera y gas para el usuario

- Una cartera de autocustodia (en esta v1, Paga Wallet: Android, iOS y PWA). Las claves no salen del dispositivo.
- Añadir también la red a carteras EVM ya existentes (`wallet_addEthereumChain`).
- Si se quiere que el usuario no vea el token de gas, un servicio de recarga puede enviar una cantidad pequeña de gas a direcciones que ya tienen el token de aplicación, con topes por dirección, por IP y por día.
- Mostrar siempre el aviso: *«Billeteras de autocustodia: úsalas bajo tu propio riesgo. Lee las reglas antes de intercambiar.»*

## 8. Probar, revisar y solo entonces fondear

1. Pruebas locales con un oráculo de prueba, para abrir y cerrar en los límites sin tocar fondos reales.
2. Revisión externa del árbol que se vaya a desplegar (token, lotes, relayer y procedimiento).
3. Despliegue de contratos vacíos o con inventario mínimo de prueba.
4. Comprobaciones on-chain: administrador, relayer, `restante()`, `abierto()`, y que no existan funciones de retirada donde no deben existir.
5. Fondeo del inventario, en un paso separado y explícito.
6. Activación del relayer en modo de envío, solo después de lo anterior.

En esta v1, esa disciplina evitó fondear `1.686.127.428` PAGA en unos contratos que la revisión aún pedía cambiar. El dispensador, más pequeño y con reglas más cerradas, sí se fondeó y se puso en uso después de probarlo.

## 9. Lo que no debe ir nunca a un repositorio

Claves privadas, archivos de entorno con secretos, direcciones internas de servidores, ni indicaciones de quién guarda cada clave. Este paquete está preparado para mostrarse precisamente porque esas cosas no están aquí.
