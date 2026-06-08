# Guía de configuración: Impresión PDF desde Odoo 19 vía CUPS (WSL2)

## Contexto y alcance

### CUPS local vs  IoT Box

Usar uno u otro depende de **dónde corre Odoo**:

| Escenario | Solución |
|-----------|----------|
| Odoo en la nube (SaaS, hosting externo) | **IoT Box** — puente entre la nube y la impresora local |
| Odoo local (Docker, WSL2, servidor propio) | **CUPS directo** — Odoo se conecta a CUPS por red sin intermediarios |

La IoT Box es un hardware (o VM) que hace de puente: Odoo nube → IoT Box → CUPS → impresora. Si Odoo ya está en tu máquina, el puente sobra: Odoo → CUPS → impresora.

### Alcance

**Objetivo final: imprimir en hardware real.** El flujo con impresora virtual PDF es un paso intermedio para validar que todo funciona antes de conectar la impresora física.

1. **Validar el flujo completo** (Odoo → módulo → CUPS → archivo PDF) sin depender de hardware
2. **Confirmar que la infraestructura funciona** (red Docker, permisos, pycups, parches Odoo 19)
3. **Conectar la impresora real** y enviar trabajos de impresión

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
- **Flujo**: Odoo → módulo OCA → CUPS → impresora (PDF o física)
- **Configuración**: `Ajustes → Técnico → Impresión → Servidores/Impresoras/Reportes`
-  **Sí pasa por CUPS**

La distinción es clave:

| Módulo | ¿Usa IoT? | ¿Usa CUPS? | Tecnología |
|--------|-----------|------------|------------|
| POS / Punto de Venta |  Sí |  No | IoT Box, ESC/POS, WebUSB |
| Facturación |  No |  Sí | `ir.actions.report` → CUPS |
| Empleados (badges) |  No |  Sí | `ir.actions.report` → CUPS |
| Pedidos/Albaranes |  No |  Sí | `ir.actions.report` → CUPS |

Esta guía se enfoca en **impresión vía servidor (backend)**, específicamente:

-  Reportes de empleados (badges/insignias)
-  Facturas, albaranes, pedidos (cualquier `ir.actions.report`)
-  Flujo completo: Odoo → `base_report_to_printer` → CUPS → PDF/impresora física

El mapeo de "qué reporte va a qué impresora" se configura en el paso **10g** de la UI: ahí vinculas cada reporte (`Print Badge`, `Factura`, etc.) a una impresora CUPS específica (`PDF_FILTRADO`, `EPSON_L3150`, etc.).

### (PENDIENTE DE IMPLEMENTAR)
-  Impresión desde POS (usa IoT Box/ESC/POS, es un setup diferente)
-  Configuración de IoT Box

---

## Resumen del flujo

```
Odoo (Docker) → módulo base_report_to_printer → CUPS (WSL2) → cups-pdf (PDF_FILTRADO) → archivo PDF
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

### 0 — Clonar y configurar variables de entorno

```bash
cp .env.impresora.example .env
nano .env          # edita DB, contenedor, puertos y rutas
echo ".env" >> .gitignore
```

---

### 0.5 — Configuración global de CUPS-PDF  Solo una vez por máquina 
**Solo para el caso de impresora virtual**
.La impresora fisica no usa **cups-pdf** , usa su propio driver (gutenprint,generico,etc)

> Por defecto `cups-pdf` escribe en `${HOME}/PDF` → bajo WSL es `/root/PDF/`, inaccesible. Este paso lo redirige al spool correcto.

```bash
sudo nano /etc/cups/cups-pdf.conf
```

Busca la directiva `Out` y déjala así:

```
Out /var/spool/cups-pdf/ANONYMOUS
```

Guarda (`Ctrl+O`, `Enter`, `Ctrl+X`) y reinicia:

```bash
sudo service cups restart
```

---

### 1 — Levantar CUPS

```bash
make cups-start
```

---

### 2 — Levantar los contenedores

```bash
make up
```

---

### 3 — Descargar el módulo de la OCA

```bash
make odoo-download-mod
```

---

### 4 — Instalar CUPS con filtros reales
**Solo para el caso de impresora virtual**
> La versión estándar de `cups-pdf` no incluye los filtros de conversión (Ghostscript) necesarios para procesar el formato que envía Odoo. Sin `cups-filters` el PDF sale vacío . Sin `cups-filters` el PDF sale vacío (`0.pdf` de ~2KB).

```bash
make cups-install
```

---

### 5 — Registrar la impresora virtual `PDF_FILTRADO`
**Solo para el caso de impresora virtual**

```bash
make cups-printer
```

Verificación:
```bash
lpstat -p -d
# printer PDF_FILTRADO is idle ... / system default destination: PDF_FILTRADO
```

---

### 6 — Corregir permisos del spool
**Solo para el caso de impresora virtual**
> La carpeta donde CUPS escribe los PDFs generados (`/var/spool/cups-pdf/ANONYMOUS/`) pertenece al usuario `lp`. Sin los permisos correctos, el backend no puede escribir el archivo resultante

```bash
make cups-perms
```

---

### 7 — Instalar dependencias Python en el contenedor
>  El módulo `base_report_to_printer` usa `pycups` para comunicarse con CUPS. Esta librería no viene en la imagen Docker de Odoo y requiere cabeceras de desarrollo para compilarse
```bash
make odoo-deps
```

> **Nota sobre `--break-system-packages`:** En Python 3.12 (PEP 668), pip no permite instalar paquetes globalmente sin esta bandera cuando el entorno está marcado como "externally managed". Es seguro usarla en este contenedor de desarrollo.
---

### 8 — Aplicar parches de compatibilidad con Odoo 19
El módulo base_report_to_printer fue diseñado para Odoo 16/17. Requiere correcciones para funcionar en Odoo 19
```bash
make odoo-fix-manifest   # versión 19.0.1.3.0
make odoo-fix-registry   # models/ir_actions_report.py importación de registry movida en Odoo 19
make odoo-fix-views      # res_users.xml incompatible <group name="preferences"> a XPath sobre //notebook
make odoo-fix-data       # ir.property eliminado en Odoo 19
make odoo-fix-tags       # <tree> → <list>
make odoo-fix-actions    # view_mode="tree" → view_mode="list"
```

o el pipeline para fix
```bash
make odoo-patch-all
```

---

### 9 — Instalar el módulo en Odoo

```bash
make odoo-force-deps   # asegura pycups antes de instalar
make odoo-update
```

### 10 - Configuracion de una impresora FISICA 
Siguiendo el flujo anterior o si es solo una nueva sesion
```bash
make start-all
```

Luego  de levantado los servicios , se procede a la "exposicion de servicio mediante red" o "redireccion de dispositivo a nivel de bus" de la impresora, este caso una EPSON L3150  (totalmente arbitrario)

Ir a https://latin.epson.com/soporte y descargar el driver , seguir los pasos para la instalacion.Escoger el tipo de conexion (wifi o usb)

Ver el tipo de conexion **panel de control** → **dispositivos e impresora** → **IMPRESORA**  → **propiedades de la impresora** → **Puertos** →  se identifica si usa WSD usb o TCP/ip.

Si la conexion es mediante usb , es necesario configuracion windows para quitarle al driver de windows la exclusividad del puerto USB.

En **administrador de dispositivos** → **deshabilitamos la impresora**

En **powershell modo administrador** 
La instalacion se puede realizar una sola vez, pero la detencion del servicio en windows se realiza cada inicio de sesion.Es posible que se requiera ejecutar el forzado varias veces, windows tiende a recuperar el control si el usb se desconecta.
```bash
winget install --interactive --exact dorssel.usbipd-win

usbipd list

Stop-Service -Name Spooler -Force 

usbipd unbind --busid 2-4

usbipd bind --busid 2-4

usbipd attach --wsl --busid 2-4
```

Se instala la utilidad para gestionar el puerto usb, listamos los dispositivos usb, hacemos que windows deje de monitorear el puerto usb, desvinculamos de windows, hacemos que esté disponible y adjuntamos a wsl respectivamente.

Si usa TCP/ip (conexion via wifi) no es necesaria la configuracion anterior.

Ahora en wsl (ubuntu)

```bash
make dependencias-impresora-real
make configuracion-impresora-real
make prueba-impresora-real
```


Luego ir a `localhost:ODOO_PORT` e ingresar credenciales de `config/odoo.conf`.


### 11 — Configuración manual en la UI 

**11a — Activar modo desarrollador**
`Ajustes → Activar el modo desarrollador`

**11b — Instalar el módulo desde Apps**
`Apps → Buscar "base_report_to_printer" → Instalar`

**11c — Registrar el servidor CUPS (impresora virtual)**
`Ajustes → Técnico → Impresión → Servidores → Nuevo`

| Campo | Valor |
|-------|-------|
| Nombre | CUPS Local |
| Dirección IP | `172.30.0.1` |
| Puerto | `631` |

> `172.30.0.1` es la gateway fija definida en `docker-compose.yml`. Verificar con:
> ```bash
> docker network ls --filter name=impresora_net
> docker network inspect <nombre_red> | grep Gateway
> ```
el nombre de la red esta definido en el docker-compose.yml

**11d — Registrar la impresora : para el caso de la impresora fisica solo Update**


`(fisica)Ajustes → Técnico → Impresión → Impresoras → Update Printers from CUPS`


`(virtual)Ajustes → Técnico → Impresión → Impresoras → Nueva`
 
| Campo | Valor |
|-------|-------|
| Display name | PDF_FILTRADO |
| System Name (cups-printer: sudo lpadmin -p PDF_FILTRADO ) | PDF_FILTRADO |
| Servidor | CUPS Local |

Clic en **Actualizar impresoras** → debe quedar en verde.

**11e — Impresora predeterminada por usuario** *(opcional)*
`Ajustes → Usuarios → [usuario] → pestaña "Impresión"`

**11f — Activar en modulo Employee** 
`Apps → Employees (ACTIVAR)`

**11g — Configurar reporte de insignia**  
`Ajustes → Printing → Reports → Print Badge`:
- Default Behaviour: create , 
    - name: imprimir 
    - type: `Send to Printer`
- Default Printer(nombre de la impresora): `IMPRESORA`

---
**11h - ver resultados**

Para ver los resultados ejecutar
```bash
make monitoreo-impresora-real
```
Se listan las impresoras, las estadisticas de la impresora de interes y sus trabajos concluidos.

**limitaciones**
En lugar de cancell jobs en la ui se usa

```bash
sudo cancel -a EPSON_L3150
ó
make actualizar-limpiar-impresora-real
```
Para devolver el control a windows y probar otro tipo de comunicacion, en poweshell modo administrador
```bash
Start-Service -Name Spooler
```


---



### 12 — Preparar carpeta de salida
**Solo para el caso de la impresora virtual**
```bash
make traer-pdf      # crea ~/carpeta de proyecto/impresiones_badge
make bashrc-fn      # agrega la función traer_pdf al .bashrc
source ~/.bashrc
```
La función `traer_pdf` copia los PDFs del spool de CUPS (que pertenece a root/lp) a tu carpeta de trabajo con permisos de tu usuario.

Flujo de prueba

1. `Empleados → [empleado] → Imprimir insignia`
2. En WSL2:
```bash
ls -l /var/spool/cups-pdf/ANONYMOUS/
traer_pdf
ls -l $OUTPUT_DIR
ls -l /home/usuario/OUT_DIR/impresiones_badge
# Badge_-_NombreEmpleado.pdf (~48 KB)
```

Acceso desde Windows:
```
\\wsl.localhost\Ubuntu\home\<usuario>\<proyecto>\impresiones_badge
```

---

 
##  INICIO DE SESIÓN NORMAL
## (flujo ya instalado, nueva sesión WSL)
 
```bash
make start-all   # cups-start + up
```

Listo. Odoo disponible en `localhost:ODOO_PORT`.

---
 
##  CUANDO SE RECREA EL CONTENEDOR (impresora virtual)
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

## Limitaciones conocidas

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

### Impresora virtual (PDF_FILTRADO)

```bash
# Ver si Odoo envía el trabajo
docker logs -f ${ODOO_CTR}

# Log de cups-pdf — el más útil para diagnosticar
sudo tail -20 /var/log/cups/cups-pdf-PDF_FILTRADO_log

# Log de acceso IPP — muestra si CUPS recibe o rechaza el trabajo
sudo tail -f /var/log/cups/access_log

# Log de errores de CUPS
sudo tail -f /var/log/cups/error_log

# Limpiar cola si Odoo se bloquea en "Printing"
sudo cancel -a PDF_FILTRADO

# Trabajos pendientes
lpstat -o

# CUPS escuchando en todas las interfaces
sudo ss -tulnp | grep 631

# Conectividad desde el contenedor hacia CUPS
docker exec ${ODOO_CTR} curl -s http://172.30.0.1:631/printers/ | grep -o 'PDF[^<]*'

# IP real del gateway de la red Docker
docker network ls --filter name=impresora_net
docker network inspect <nombre_red> | grep Gateway
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
| `make all` | Flujo completo de instalación (primera vez) |
| `make odoo-download-mod` | Descargar módulo desde OCA |
| `make cups-install` | Instalar CUPS y filtros PDF |
| `make cups-printer` | Registrar impresora `PDF_FILTRADO` |
| `make cups-printer-fix` | Restaurar PPD si se cambió a Raw |
| `make cups-perms` | Corregir permisos del spool (`nobody:lp`) |
| `make odoo-deps` | Instalar `pycups` (primera vez) |
| `make odoo-force-deps` | Reinstalar `pycups` tras recrear contenedor |
| `make odoo-fix-manifest` | Parchear versión en `__manifest__.py` |
| `make odoo-fix-registry` | Parchear importación de `registry` |
| `make odoo-fix-views` | Reemplazar `res_users.xml` |
| `make odoo-fix-data` | Eliminar datos incompatibles (`ir.property`) |
| `make odoo-fix-tags` | Migrar `<tree>` → `<list>` |
| `make odoo-fix-actions` | Sanear `view_mode` a `list` |
| `make odoo-update` | Instalar/actualizar módulo en Odoo |
| `make traer-pdf` | Crear carpeta de salida |
| `make bashrc-fn` | Configurar función `traer_pdf` en `.bashrc` |
| `make status` | Estado de servicios y archivos |
| `make clean` | Limpiar PDFs del spool y carpeta de salida |
| `make dependencias-impresora-real` | Instalar `usbutils`, `gutenprint`, `avahi` |
| `make configuracion-impresora-real` | Detectar USB/IPP y registrar en CUPS |
| `make prueba-impresora-real` | Enviar texto de prueba |
| `make actualizar-limpiar-impresora-real` | Cancelar trabajos en cola |
| `make monitoreo-impresora-real` | Estado y trabajos completados |