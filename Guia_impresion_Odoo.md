# Guía de configuración: Impresión PDF desde Odoo 19 vía CUPS (WSL2)

### Mapeo de módulos e impresión

Odoo tiene **dos modelos de impresión** que usan tecnologías distintas:

#### 1. Impresión directa desde POS (usa IoT Box o drivers del navegador)
- **POS (Punto de Venta)**: Tickets de venta, recibos
- **Tecnología**: IoT Box (ESC/POS) o drivers del navegador (`IoTHubPrinter`, WebUSB)
- **Flujo**: Odoo → IoT Box → impresora térmica (ESC/POS)
- **Configuración**: `Configuración → Punto de Venta → Impresoras de tickets`
-  **No pasa por CUPS** en este flujo

#### 2. Impresión vía servidor/backend (usa CUPS)
- **Facturación**: Facturas, albaranes, pedidos
- **Empleados**: Insignias/badges
- **Cualquier reporte** que use `ir.actions.report`
- **Tecnología**: `base_report_to_printer` → CUPS 
- **Configuración**: `Ajustes → Técnico → Impresión → Servidores/Impresoras/Reportes`
-  **Sí pasa por CUPS**



Esta guía se enfoca en **impresión vía servidor (backend)**, específicamente:

-  Reportes de empleados (badges/insignias)
-  Facturas, albaranes, pedidos (cualquier `ir.actions.report`)
-  Flujo completo: Odoo → `base_report_to_printer` → CUPS → PDF/impresora física

El mapeo de "qué reporte va a qué impresora" se configura en el paso **9f** en la UI: ahí vinculas cada reporte (`Print Badge`, `Factura`, etc.) a una impresora CUPS específica (`PDF_FILTRADO`, `EPSON_L3150`, etc.).

### (PENDIENTE DE IMPLEMENTAR)
-  Impresión desde POS (usa IoT Box/ESC/POS, es un setup diferente)
-  Configuración de IoT Box

---

## Resumen del flujo  
```text
======================================================================================
 DIAGRAMA DE FLUJO: ODOO (DOCKER) ──> CUPS (WSL2) ──> IMPRESORA USB (WINDOWS HOST)
======================================================================================

 ┌──────────────────────────────────────────────────────────────────────────────────┐
 │ 1. ENTORNO DOCKER (Red Aislada: impresora_global)                                │
 │                                                                                  │
 │   ┌──────────────────────────────────────────────────────────────────────────┐   │
 │   │ Contenedor: odoo19-server-dev_lunes                                      │   │
 │   │                                                                          │   │
 │   │  [ Odoo UI Backend ] ──> [ Módulo OCA: base_report_to_printer ]          │   │
 │   │                                            │                             │   │
 │   │                                            ▼ (Llamada IPP vía pycups)    │   │
 │   │                                      [ Socket: 172.30.0.1:631 ]          │   │
 │   └────────────────────────────────────────────┬─────────────────────────────┘   │
 └────────────────────────────────────────────────┼─────────────────────────────────┘
                                                  │
                                                  ▼ (Tráfico cruza por la Gateway)
 ┌──────────────────────────────────────────────────────────────────────────────────┐
 │ 2. ENTORNO WSL2 (Host Linux Ubuntu)            │                                 │
 │                                                ▼                                 │
 │   ┌──────────────────────────────────────────────────────────────────────────┐   │
 │   │ Demonio CUPS (cupsd) ── [ Escucha activa en 0.0.0.0:631 ]                │   │
 │   │   - Recibe la petición IPP entrante desde la red de Docker.              │   │
 │   │   - Administra la cola de impresión (Spooler).                           │   │
 │   │   - Renderiza el archivo usando el driver PPD de la impresora.           │   │
 │   └────────────────────────────────────────────┬─────────────────────────────┘   │
 │                                                │                                 │
 │                                                ▼ (Inyección al bus USB virtual)  │
 │   ┌──────────────────────────────────────────────────────────────────────────┐   │
 │   │ Subsistema USB Linux ── [ /dev/bus/usb/... ]                             │   │
 │   │   - Nodo de hardware mapeado dinámicamente mediante USBIPD.              │   │
 │   └────────────────────────────────────────────▲─────────────────────────────┘   │
 └────────────────────────────────────────────────┼─────────────────────────────────┘
                                                  │
                                                  ▲ (Passthrough de datos raw)
 ┌────────────────────────────────────────────────┼─────────────────────────────────┘
 │ 3. WINDOWS HOST (Sistema Operativo Base)       │                                 │
 │                                                │                                 │
 │   ┌────────────────────────────────────────────┴─────────────────────────────┐   │
 │   │ Servicio USBIPD (usbipd-win)                                             │   │
 │   │   - Intercepta el dispositivo físico mediante el BUSID (ej. 2-4).        │   │
 │   │   - Bloquea temporalmente el spooler de Windows (Spooler Stopped).       │   │
 │   │   - Sostiene el puente de comunicación directo hacia el kernel de WSL.   │   │
 │   └────────────────────────────────────────────┬─────────────────────────────┘   │
 │                                                │                                 │
 │                                                ▼ (Ejecución física del hardware) │
 │   ┌──────────────────────────────────────────────────────────────────────────┐   │
 │   │ Impresora Física (Ej: EPSON L3150 / Zebra / PDF)                         │   │
 │   └──────────────────────────────────────────────────────────────────────────┘   │
 └──────────────────────────────────────────────────────────────────────────────────┘ 
```
----

```text
==================================================================================================
 DIAGRAMA ARQUITECTÓNICO DE SEPARACIÓN DE FLUJOS Y TRAZABILIDAD DE TARGETS (MAKEFILE / ODOO / CUPS)
==================================================================================================

 [ ACCIÓN DE IMPRESIÓN DESDE LA INTERFAZ DE ODOO (UI) ]
                          │
        ┌─────────────────┴─────────────────┐
        ▼                                   ▼
┌──────────────────────────┐   ┌──────────────────────────────────────────────────────────────┐
│ 1. FLUJO PUNTO DE VENTA  │   │ 2. FLUJO BACKEND / REPORTES (Facturas, Albaranes, Badges)    │
│    (Fuera de CUPS)       │   │    (Pasa por infraestructura Docker ──> WSL2 ──> CUPS)       │
└──────────┬───────────────┘   └──────────────────────────────┬───────────────────────────────┘
           │                                                  │
           ▼ (Conectividad Directa)                           ▼ [make odoo-download-modulo] (Descarga inicial)
┌──────────────────────────┐   ┌──────────────────────────────────────────────────────────────┐
│ IoT Box / Navegador Web  │   │ ENTORNO DOCKER (Red Aislada: impresora_global)               │
│ Protocolo ESC/POS        │   │ Contenedor: odoo19-server-dev_lunes                          │
│ Conexión WebUSB directa  │   │                                                              │
└──────────┬───────────────┘   │   [ CONFIGURACIÓN DE LA UI ]                                 │
           │                   │   [9a] Modo Dev ──▶ [9b] Instalar Módulo ──▶ [9c/d] Servidor │
           ▼                   │                                                 │            │
┌──────────────────────────┐   │                                                 ▼ [9f Config]│
│ IMPRESORA TÉRMICA        │   │   [9g DISPARO UX] Operador hace click ◀─────────┘            │
│ (Ticketera de cocina/POS)│   │             │     en botón "Imprimir"                        │
└──────────────────────────┘   │             ▼                                                │
                               │   [ Módulo OCA: base_report_to_printer ]                     │
                               │             │                                                │
                               │             ▼ [make odoo-force-deps] (Compila pycups)        │
                               │      (Librería pycups)                                       │
                               │             │                                                │
                               │             ▼ [make odoo-update] (Inyecta modulo a Odoo)     │
                               │   [ Socket IPP: 172.30.0.1:631 ]                             │
                               └──────────────────────────┬───────────────────────────────────┘
                                                          │
                                                          ▼ (El tráfico cruza la Gateway Virtual)
                               ┌──────────────────────────────────────────────────────────────┐
                               │ ENTORNO WSL2 (Host Linux Ubuntu / Backend de Impresión)       │
                               │                                                              │
 ┌─────────────────────────┐   │   ┌──────────────────────────────────────────────────────┐   │
 │ MITIGACIÓN DE ERRORES   │   │   │ SERVIDOR CUPS (cupsd) [Escucha en 0.0.0.0:631]       │   │
 │                         │   │   │ [make cups-install] (Instalación base)               │   │
 │ ¿Timeout de conexión?   │   │   │ [make cups-start] / [make start-all] (Despertar daemon)│  │
 │ ──▶ [make reparar-imp]  ├───┼──▶│                                                      │   │
 │                         │   │   │ - Administra Spooler & Colas de Trabajo.             │   │
 │ ¿Bloqueo de Caché DB?   │   │   │ - Renderiza binarios usando archivos de marcas PPD.  │   │
 │ ──▶ [make borrar-db]    │   │   └──────────────────────────┬───────────────────────────┘   │
 └─────────────────────────┘   │                              │                               │
                               │                              ▼                               │
                               │               ¿Qué tipo de impresora procesa?                │
                               │               ┌──────────────┴──────────────┐                │
                               │               ▼                             ▼                │
                               │     ┌──────────────────┐          ┌──────────────────┐       │
                               │     │ IMP. VIRTUAL     │          │ IMP. FÍSICA      │       │
                               │     │ (PDF_FILTRADO)   │          │ (EPSON_L3150)    │       │
                               │     └─────────┬────────┘          └─────────┬────────┘       │
                               │               │                             │                │
                               │               ▼ [make spool-perms]          ▼ [make preparar-impresora]
                               │     ┌──────────────────┐          (Instala usbutils/gutenprint)
                               │     │ Directorio Spool │                    │                │
                               │     │ /var/spool/      │                    ▼                │
                               │     │ cups-pdf/        │          ¿Cuál es el canal de i/o?  │
                               │     └─────────┬────────┘          ┌─────────┴────────┐       │
                               │               │                   ▼                  ▼       │
                               │               ▼ [make clean]    ┌────┐            ┌────┐     │
                               └─────────────────────────────────│USB │            │WiFi│─────┘
                                                                 └────┘            └────┘
                                                                   │                  │
                               ┌───────────────────────────────────┘                  ▼ [make registrar-impresora-wifi]
                               ▼ (Túnel USBIPD Passthrough)                        ┌───────────────────────────┐
 ┌────────────────────────────────────────────────────────────────┐                │ IMPRESIÓN FÍSICA VÍA WIFI │
 │ 3. WINDOWS HOST (Capa del Hardware del Sistema Base)           │                │ Protocolo: AppSocket      │
 │                                                                │                │ Enrutamiento: Puerto 9100 │
 │   [ PowerShell en Modo Administrador ]                         │                └───────────────────────────┘
 │   1. Stop-Service -Name Spooler -Force (Desactiva spool nativo)│
 │   2. usbipd unbind --busid <BID> ──▶ bind --busid <BID>        │
 │   3. usbipd attach --wsl --busid <BID>                         │
 └─────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼ (Re-inyección del bus al Kernel de Linux)
 ┌────────────────────────────────────────────────────────────────┐
 │ 4. RE-ENTRADA A WSL2 (Montaje y Consumo del Dispositivo)       │
 │                                                                │
 │   [ /dev/bus/usb/ ] ──▶ [make desbloquear-usb] (Chmod del Nodo)│
 │                            │                                   │
 │                            ▼ [make registrar-impresora]        │
 │                          Vincula el puerto dev al driver PPD   │
 └─────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼ [make prueba-impresora] (Testeo operacional)
 ┌────────────────────────────────────────────────────────────────┐
 │ 5. CONTROL, SEGUIMIENTO Y DEPURACIÓN                           │
 │                                                                │
 │   - [make monitoreo-impresora]           (Verificar logs/cola) │
 │   - [make actualizar-limpiar-impresora]  (Purgar atascos)     │
 └────────────────────────────────────────────────────────────────┘
```

---

## Archivos del proyecto

```
.
├── Makefile
├── docker-compose.yml
├── .env                  
├── .env.impresora.example           
├── .gitignore
└── config/
    └── odoo.conf
```

---
 
##  PRIMERA VEZ EN UNA MÁQUINA NUEVA 

### 1 — Clonar y configurar     variables de entorno

```bash
cp .env.impresora.example .env
nano .env          # edita DB, contenedor, puertos y rutas
echo ".env" >> .gitignore
```
Pasos 2 → 7 **make setup**

---
### 2 — Instalar y Levantar CUPS

```bash
make cups-install
```

---

### 3 — Levantar los contenedores
Si se ejecuta el proyecto por primera vez o si es que se hizo una migracion de las versiones de OCA y se tuvo que borrar las bases de datos(make borrar-db), se busca reconstruir los contenedores.

Si se está en desarrollo y usando un solo host, es recomendable apagar los otros contenedores(ahorra mucha ira) en este caso: **docker stop odoo19-server-test odoo19-db-test odoo19-server-dev odoo19-db-dev**
```bash
make up
```

---

### 4 — Descargar el módulo de la OCA

```bash
make odoo-download-modulo
```
 
### 5 — Permisos
```bash
make spool-perms 
```

### 6 — Instalar dependencias Python en el contenedor
El módulo `base_report_to_printer` usa `pycups` para comunicarse con CUPS. Esta librería no viene en la imagen Docker de Odoo y requiere cabeceras de desarrollo para compilarse
```bash
make odoo-force-deps
```

> **Nota sobre `--break-system-packages`:** En Python 3.12 (PEP 668), pip no permite instalar paquetes globalmente sin esta bandera cuando el entorno está marcado como "externally managed". Es seguro usarla en este contenedor de desarrollo.
---

### 7 — Instalar el módulo en Odoo
Creamos la base de datos (si no existe) e instalamos los modulos de report-print-send
```bash
make odoo-update
```

### 8 - Configuracion de una impresora FISICA 
Siguiendo el flujo anterior o si es solo una nueva sesion **make start-all**



Luego  de levantado los servicios , se procede a la "exposicion de servicio mediante red" o "redireccion de dispositivo a nivel de bus" de la impresora, este caso una EPSON L3150  (totalmente arbitrario)

Ir a https://latin.epson.com/soporte y descargar el driver , seguir los pasos para la instalacion.Escoger el tipo de conexion (wifi o usb)

Ver el tipo de conexion **panel de control** → **dispositivos e impresora** → **IMPRESORA**  → **propiedades de la impresora** → **Puertos** →  se identifica si usa WSD usb o TCP/ip.

**CONEXION VIA USB**<br>
Es necesario quitar al driver de windows la exclusividad del puerto USB.

En **administrador de dispositivos** → **deshabilitamos la impresora**

En **powershell modo administrador** 
La instalacion se puede realizar una sola vez, pero la detencion del servicio en windows se realiza cada inicio de sesion.Es posible que se requiera ejecutar el forzado varias veces (cada inicio de sesion), windows tiende a recuperar el control si el usb se desconecta.
```bash
winget install --interactive --exact dorssel.usbipd-win

usbipd list               # la primera columna da los valores BUSID

Stop-Service -Name Spooler -Force 

usbipd unbind --busid 2-4   # usbipd unbind --busind <BUSID>

usbipd bind --busid 2-4

usbipd attach --wsl --busid 2-4
```
 
Comprobar en el terminal  **lsusb** si la impesora no aparece ,en powershell modo administrador , adjuntar nuevamente
mediante **usbipd attach --wsl --busid 2-4**

Se instala la utilidad para gestionar el puerto usb, listamos los dispositivos usb, hacemos que windows deje de monitorear el puerto usb, desvinculamos de windows, hacemos que esté disponible y adjuntamos a wsl respectivamente.

Ahora en wsl (ubuntu)

```bash
make preparar-impresora
make desbloquear-usb
make registrar-impresora   
make prueba-impresora
```
**CONEXION VIA WIFI(IPP AppSpcket/JetDirect) NO PROBADO**<br>

En teoria solo haria falta 
```bash
make preparar-impresora
make registrar-impresora-wifi
make prueba-impresora
```

Luego ir a `localhost:ODOO_PORT` e ingresar credenciales de `config/odoo.conf`.


### 9 — Configuración manual en la UI 

**9a — Activar modo desarrollador**
`Ajustes → Activar el modo desarrollador`

**9b — Instalar el módulo desde Apps** (make odoo-update realiza esto)
`Apps → Buscar "base_report_to_printer" → Instalar`

**9c — Registrar el servidor CUPS (impresora virtual)**
`Ajustes → Técnico → Impresión → Servidores → Nuevo`


| Campo | Valor |
|-------|-------|
| Nombre | CUPS Local |
| Dirección IP | `172.30.0.1` |
| Puerto | `631` |

> `172.30.0.1` es la gateway fija definida en `docker-compose.yml`. Verificar con:
> ```bash
> docker network inspect <nombre_red> | grep Gateway
> ```
el nombre de la red esta definido en el docker-compose.yml

**9d — Registrar la impresora**
En ocasiones solo hace falta un update

`(fisica)Ajustes → Técnico → Impresión → Impresoras → Update Printers from CUPS` debido a make **registrar-impresora**

En otras se crea una nueva, en new ,escoger como BACKEND = CUPS :
El system name se detalla en **registrar-impresora**
| Campo | Valor |
|-------|-------|
| System Name (sudo lpadmin -p "$(NOMBRE_IMPRESORA))|  EPSON_L3150|
| Backend | CUPS |
| Server | el servidor creado |
**9e — Activar en modulo Employee** 
`Apps → Employees (ACTIVAR)`

**9f — Configurar reporte de insignia**  
`Ajustes → Printing → Reports → Print Badge`:
- Default Behaviour: 
    -  `Send to Printer`
- Default Printer(nombre de la impresora): `IMPRESORA`

---
**9g - ver resultados**

Para ver los resultados ejecutar
```bash
make monitoreo-impresora
```
Se listan las impresoras, las estadisticas de la impresora de interes y sus trabajos concluidos.

**limitaciones**<br>
En lugar de cancell jobs en la ui se usa

```bash
sudo cancel -a EPSON_L3150
```
**Fuerza Bruta pero "sabia"**<br>
Si pese a realizar la ejecucion ordenada de los targets y con las validaciones correctas, sin mensajes de errores dramaticos, si pese a eso no se logra imprimir :
- Desconectar el cable usb y reconectarlo
- Desenchufar la impresora y volver a enchufarlo

Luego probar nuevamente **make desbloquear-usb , make registrar-impresora , make prueba-impresora**


Una vez realizado las pruebas, para devolver el control a windows y probar otro tipo de comunicacion, en poweshell modo administrador
```bash
Start-Service -Name Spooler
```


---


---

 
##  INICIO DE SESIÓN NORMAL
## (flujo ya instalado, nueva sesión WSL)
 
```bash
make start-all   # cups-install + up
make desbloquear-usb
```

Listo. Odoo disponible en `localhost:ODOO_PORT`.

Si localhost:PUERTO presenta **ERR_CONNECTION_REFUSED** usar el ip otorgado por  **hostname -I** en el navegador IP:PUERTO

**Gestión de Red Virtualizada (WSL2 / Docker)**

Debido a la capa de abstracción de red nativa de WSL2 y la coexistencia de múltiples contenedores, pueden generarse colisiones de rutas en el puente virtual. Si tras iniciar el entorno Odoo arroja un error de conexión (`Timeout / Connection Refused`) al comunicarse con la interfaz de CUPS en la IP fija `172.30.0.1:631`, proceda con los siguientes niveles de mitigación:

- **Nivel 1 (Restablecimiento de Red):** Ejecute el comando `make reparar-impresion`. Esto forzará el reinicio del demonio `cupsd`, purgará los sockets colgados de Docker y recreará el puente de red aislado.

- **Nivel 2 (Purga de Persistencia en BD):** Si el error persiste, significa que el módulo `base_report_to_printer` ha guardado un estado de conexión corrupto o inaccesible en las tablas de la base de datos. Para solucionar este bloqueo por caché, ejecute de forma secuencial:

```bash
make borrar-db && make setup
```

Una vez reconstruido el esquema limpio de la base de datos, proceda directamente con el Paso 8 en adelante.

**Conectividad vía USB**

La conexión USB en WSL2 no es persistente: Windows mantiene el control nativo del bus USB y, al desconectarse el dispositivo o reiniciar sesión, recupera automáticamente el binding del puerto, revirtiendo el passthrough hacia WSL.

Por este motivo, en cada inicio de sesión es necesario repetir el ciclo completo:

1. **En PowerShell (modo administrador)** — forzar el redireccionamiento del bus hacia WSL:
```powershell
   Stop-Service -Name Spooler -Force
   usbipd unbind --busid <BUSID>
   usbipd bind --busid <BUSID>
   usbipd attach --wsl --busid <BUSID>
```

2. **En WSL** — liberar el dispositivo de cualquier driver residual y registrarlo en CUPS:
```bash
   make desbloquear-usb
```

Si tras `usbipd attach` el dispositivo no aparece en `lsusb`, repetir el `attach` (Windows puede tardar en soltar el puerto). En casos persistentes, puede ser necesario ejecutar `usbipd unbind`/`bind`/`attach` varias veces hasta que el binding se mantenga estable.

---
 
##  CUANDO SE RECREA EL CONTENEDOR (a discreción del administrador/caso impresora virtual)
### (después de make restart-net, make down && make up, o Docker Desktop reiniciado) 

> El contenedor pierde `pycups` al ser recreado porque es una instalación dentro de la imagen en tiempo de ejecución, no persistida en volúmenes.

```bash
make cups-start
make odoo-force-deps   # reinstala pycups en el nuevo contenedor
make odoo-update       # reinstala el módulo en la BD
```

Si CUPS también perdió la impresora:
```bash
make cups-printer
make cups-perms
```

---

## Limitaciones conocidas (caso virtual)

**"Cancel All Jobs" da error `Unauthorized`**
CUPS rechaza operaciones IPP administrativas desde Docker sin autenticación. Usar desde terminal:
```bash
sudo cancel -a PDF_FILTRADO(impresora virtual)
```

**La impresora NO debe configurarse en modo `Raw`**
Produce `0.pdf` vacío. Si ocurre accidentalmente:
```bash
make cups-printer-fix
```

## CUPS no persiste entre reinicios de WSL
Siempre ejecutar 
```bash
make cups-start 
ó
make start-all
```
Al inicio de cada sesión.

## `pycups` no persiste al recrear el contenedor
Siempre ejecutar
```bash
make odoo-force-deps
```
Después de recrear el contenedor.

 
---

---

## Monitoreo y depuración

### Impresora física

```bash
# Verificar que el dispositivo USB está conectado
lsusb
# Bus 001 Device 002: ID 04b8:1143 Seiko Epson Corp. L3150 Series

# Ver dispositivos disponibles para CUPS
lpinfo -v
# direct usb://EPSON/L3150%20Series?...
# network ipp://...

# Ver trabajos pendientes de la impresora real
lpstat -o EPSON_L3150

# Ver trabajos completados
lpstat -W completed -p EPSON_L3150

# Cancelar trabajos específicos
sudo cancel -a EPSON_L3150

# O usar el target ya existente
make monitoreo-impresora-real
```

---

## Referencia rápida de comandos Makefile

| Comando | Cuándo usarlo |
|---------|---------------|
| `make start-all` | **Inicio de sesión normal** — cups-start + up |
| `make cups-start` | Levantar solo CUPS |
| `make up` | Levantar solo los contenedores |
| `make down` | Detener y eliminar contenedores |
| `make restart-net` | Recrear contenedores con nueva configuración de red |
| `make setup` | Prepara el entorno (primera vez) |
| `make odoo-download-modulo` | Descargar módulo desde OCA |
| `make cups-install` | Instalar CUPS y filtros PDF |
| `make spool-perms` | Corregir permisos del spool (`nobody:lp`) |
| `make odoo-deps` | Instalar `pycups` (primera vez) |
| `make odoo-force-deps` | Reinstalar `pycups` tras recrear contenedor |
| `make odoo-update` | Instalar/actualizar módulo en Odoo | 
| `make status` | Estado de servicios y archivos |
| `make clean` | Limpiar PDFs del spool y carpeta de salida |
| `make preparar-impresora` | Instalar `usbutils`, `gutenprint`, `avahi` |
| `make configuracion-impresora` | Detectar USB/IPP y registrar en CUPS |
| `make prueba-impresora` | Enviar texto de prueba |
| `make actualizar-limpiar-impresora` | Cancelar trabajos en cola |
| `make monitoreo-impresora` | Estado y trabajos completados |