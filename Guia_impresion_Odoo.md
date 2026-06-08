# Guía de configuración: Impresión PDF desde Odoo 19 vía CUPS (WSL2)

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

## ══════════════════════════════════════
##  PRIMERA VEZ EN UNA MÁQUINA NUEVA
## ══════════════════════════════════════

### 0 — Clonar y configurar variables de entorno

```bash
cp .env.impresora.example .env
nano .env          # edita DB, contenedor, puertos y rutas
echo ".env" >> .gitignore
```

---

### 0.5 — Configuración global de CUPS-PDF  Solo una vez por máquina

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

> Sin `cups-filters` el PDF sale vacío (`0.pdf` de ~2KB).

```bash
make cups-install
```

---

### 5 — Registrar la impresora `PDF_FILTRADO`

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

> `cups-pdf` corre como `nobody`. Si la carpeta pertenece a `lp`, los archivos se generan pero se descartan silenciosamente.

```bash
make cups-perms
```

---

### 7 — Instalar dependencias Python en el contenedor

```bash
make odoo-deps
```

---

### 8 — Aplicar parches de compatibilidad con Odoo 19

```bash
make odoo-fix-manifest   # versión 19.0.1.3.0
make odoo-fix-registry   # importación de registry movida en Odoo 19
make odoo-fix-views      # res_users.xml incompatible
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

Luego ir a `localhost:ODOO_PORT` e ingresar credenciales de `config/odoo.conf`.

---

### 10 — Configuración manual en la UI *(no automatizable)*

**10a — Activar modo desarrollador**
`Ajustes → Activar el modo desarrollador`

**10b — Instalar el módulo desde Apps**
`Apps → Buscar "base_report_to_printer" → Instalar`

**10c — Registrar el servidor CUPS**
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

**10d — Registrar la impresora**
`Ajustes → Técnico → Impresión → Impresoras → Nueva`

| Campo | Valor |
|-------|-------|
| Display name | PDF_FILTRADO |
| System Name (cups-printer: sudo lpadmin -p PDF_FILTRADO ) | PDF_FILTRADO |
| Servidor | CUPS Local |

Clic en **Actualizar impresoras** → debe quedar en verde.

**10e — Impresora predeterminada por usuario** *(opcional)*
`Ajustes → Usuarios → [usuario] → pestaña "Impresión"`

**10f — Activar en modulo Employee** 
`Apps → Employees (ACTIVAR)`

**10g — Configurar reporte de insignia**
`Ajustes → Printing → Reports → Print Badge`:
- Default Behaviour: create , 
    - name: imprimir 
    - type: `Send to Printer`
- Default Printer(nombre de la impresora): `PDF_FILTRADO`

---

### 11 — Preparar carpeta de salida

```bash
make traer-pdf
make bashrc-fn
source ~/.bashrc
```

---

###  Flujo de prueba

1. `Empleados → [empleado] → Imprimir insignia`
2. En WSL2:
```bash
ls -l /var/spool/cups-pdf/ANONYMOUS/
traer_pdf
ls -l $OUTPUT_DIR
ls -l /home/esau/OUT_DIR/impresiones_badge
# Badge_-_NombreEmpleado.pdf (~48 KB)
```

Acceso desde Windows:
```
\\wsl.localhost\Ubuntu\home\<usuario>\<proyecto>\impresiones_badge
```

---

## ══════════════════════════════════════
##  INICIO DE SESIÓN NORMAL
## (flujo ya instalado, nueva sesión WSL)
## ══════════════════════════════════════

```bash
make start-all   # cups-start + up
```

Listo. Odoo disponible en `localhost:ODOO_PORT`.

---

## ══════════════════════════════════════
##  CUANDO SE RECREA EL CONTENEDOR
## (después de make restart-net, make down && make up, o Docker Desktop reiniciado)
## ══════════════════════════════════════

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
sudo cancel -a PDF_FILTRADO
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

## Configuracion de una impresora FISICA 
En este caso una EPSON L3150 
Ir a https://latin.epson.com/soporte y descargar el driver , seguir los pasos para la instalacion.

Ver el tipo de conexion **panel de control** → **dispositivos e impresora** → **IMPRESORA**  → **propiedades de la impresora** → **Puertos** →  se identifica si usa WSD usb o TCP/ip.

Si la conexion es mediante usb , es necesario configuracion windows para quitarle al driver de windows la exclusividad del puerto USB.

En **administrador de dispositivos** → **deshabilitamos la impresora**

En **powershell modo administrador** 
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

- En la ui de ODOO ,actualizar la impresora , vincularle un server y registrarle como predeterminado.

- Asimismo en ajustes → printers → reports vincular el el "modulo" a la impresora de interes(en este caso EPSON L3150)

- Enviar el badge a imprimir (el mismo ejemplo que en el caso de la impresora virtual)

Para ver los resultados ejecutar
```bash
make monitoreo-impresora-real
```
Se listan las impresoras, las estadisticas de la impresora de interes y sus trabajos concluidos.

De nuevo en lugar de cancell jobs en la ui se usa

```bash
sudo cancel -a EPSON_L3150
ó
make actualizar-impresora-real
```

### Consolidación de los targets

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