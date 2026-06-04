# Guía de configuración: Impresión PDF desde Odoo 19 vía CUPS (WSL2)

## Resumen del flujo

```
Odoo (Docker) → módulo base_report_to_printer → CUPS (WSL2) → cups-pdf (PDF_FILTRADO) → archivo PDF
```

El objetivo es que al imprimir desde Odoo (p. ej. una insignia de empleado), el documento llegue como archivo PDF a una carpeta accesible desde Windows.

---

## Requisitos previos

| Requisito | Verificación |
|-----------|-------------|
| WSL2 con Ubuntu 22.04+ | `wsl --list --verbose` |
| Docker Desktop corriendo | `docker ps` |
| Contenedor Odoo activo | `docker ps --filter name=` |
| Módulo `base_report_to_printer` copiado en `addons_custom` | addons_custom/base_report_to_printer` |

---
## Clonar configurar las variables de entorno
Copia la plantilla de ejemplo y edítala con tus datos:

```bash   
cp .env.impresora.example .env.impresora

nano .env.impresora

echo ".env.impresora" >> .gitignore
   ```
---
## Paso -2 - levanta servicio de impresion de linux
De modo que el puerto 631 quede escuchando
```bash
make cups-start
```
---
## Paso -1 - levantar los contenedores
```bash
make up
```
Seguidamente en localhost:8071 usar las variables de entorno de odoo.conf : admin_pass = Master Password  , y como base de datos  ODOO_DB=NOMBRE_BD

## Paso 0 - Instalar modulo de la OCA
> **Por qué:**  El modulo no viene de forma nativa en Odoo, la OCA (ODOO community Association) agrupa los modulos relacionados con impresion , envios y reportes en ese repositorio

```bash
make odoo-download-mod
```
## Paso 0.5 — Configuración global de CUPS-PDF  Solo una vez por máquina

> **Por qué:** Por defecto, `cups-pdf` escribe los PDFs en `${HOME}/PDF`, que bajo WSL equivale a `/root/PDF/` — una carpeta inaccesible para tu usuario. Este paso redirige la salida al directorio estándar del spool (`/var/spool/cups-pdf/ANONYMOUS/`), que es donde el resto de la configuración espera encontrar los archivos.
>
> **Este paso solo se realiza una vez por máquina nueva.** No forma parte del `Makefile` porque es una configuración del sistema operativo, independiente del proyecto.

1. Abre el archivo de configuración:

```bash
sudo nano /etc/cups/cups-pdf.conf
```

2. Busca la directiva `Out` y asegúrate de que quede así:

```
### Key: Out
##  Out: Output directory.
Out /var/spool/cups-pdf/ANONYMOUS
```

3. Guarda el archivo (`Ctrl+O`, `Enter`, `Ctrl+X`) y reinicia CUPS:

```bash
sudo service cups restart
```

4. Verifica que el directorio de salida existe y tiene permisos correctos (esto lo aplica también `make cups-perms` más adelante):

```bash
sudo chmod 777 /var/spool/cups-pdf/ANONYMOUS
sudo ls -ld /var/spool/cups-pdf/ANONYMOUS
# Debe mostrar: drwxrwxrwx ... /var/spool/cups-pdf/ANONYMOUS
```

---

---
## Paso 1 — Instalar y levantar CUPS con filtros reales

> **Por qué:** La versión estándar de `cups-pdf` no incluye los filtros de conversión (Ghostscript) necesarios para procesar el formato que envía Odoo. Sin `cups-filters` el PDF sale vacío.

```bash
make cups-install
```

Lo que hace internamente:
```bash
sudo apt-get install -y cups cups-filters printer-driver-cups-pdf cups-pdf
sudo service cups start
sudo cupsctl --remote-any      # permite conexiones remotas (necesario para Docker)
sudo service cups restart
```

Verificación:
```bash
sudo service cups status
```

---

## Paso 2 — Registrar la impresora `PDF_FILTRADO`

> **Por qué:** Se crea una nueva cola de impresión ligada al PPD genérico que proveen los nuevos filtros. Esto es lo que diferencia esta impresora de la `PDF` que se creó inicialmente (que usaba el backend obsoleto sin driver).

```bash
make cups-printer
```

Lo que hace internamente:
```bash
sudo lpadmin -p PDF_FILTRADO -v cups-pdf:/ -m "drv:///sample.drv/generic.ppd" -E
sudo lpadmin -d PDF_FILTRADO   # la establece como predeterminada
```

Verificación:
```bash
lpstat -p -d
# Debe mostrar: printer PDF_FILTRADO is idle ... / system default destination: PDF_FILTRADO
```

---

## Paso 3 — Corregir permisos del spool

> **Por qué:** La carpeta donde CUPS escribe los PDFs generados (`/var/spool/cups-pdf/ANONYMOUS/`) pertenece al usuario `lp`. Sin los permisos correctos, el backend no puede escribir el archivo resultante.

```bash
make cups-perms
```

Lo que hace internamente:
```bash
sudo chown -R lp:lp /var/spool/cups-pdf/
sudo chmod 777 /var/spool/cups-pdf/ANONYMOUS/
```

---

## Paso 4 — Instalar dependencias Python en el contenedor Odoo

> **Por qué:** El módulo `base_report_to_printer` usa `pycups` para comunicarse con CUPS. Esta librería no viene en la imagen Docker de Odoo y requiere cabeceras de desarrollo para compilarse.

```bash
make odoo-deps
```

Lo que hace internamente:
```bash
docker exec -u root odoo19-server-dev apt-get install -y libcups2-dev python3-dev gcc
docker exec -u root odoo19-server-dev pip install pycups --break-system-packages
docker restart odoo19-server-dev
```

> **Nota sobre `--break-system-packages`:** En Python 3.12 (PEP 668), pip no permite instalar paquetes globalmente sin esta bandera cuando el entorno está marcado como "externally managed". Es seguro usarla en este contenedor de desarrollo.

---

## Paso 5 — Aplicar parches de compatibilidad con Odoo 19

El módulo `base_report_to_printer` fue diseñado para Odoo 16/17. Requiere dos correcciones para funcionar en Odoo 19.

### 5a — Versión del módulo

El archivo `__manifest__.py` original contiene una declaración de versión obsoleta (ej. `"version": "16.0.x.x.x"`). [cite_start]Para evitar que Odoo rechace el módulo por incompatibilidad, el script actualiza dinámicamente este valor a la versión `19.0.1.3.0`.

```bash
make odoo-fix-manifest
```

Cambia la línea:
```python
"version": "16.0.x.x.x",   # o la versión que tenga
```
Por:
```python
"version": "19.0.1.3.0",
```

### 5b — Importación de `registry` (Makefile lo aplica automáticamente)

En Odoo 19, `registry` fue movido. Aplica el parche:

```bash
make odoo-fix-registry
```

El archivo `models/ir_actions_report.py` debe quedar con estas importaciones:
```python
from odoo import _, api, exceptions, fields, models
from odoo.modules.registry import Registry as registry
from odoo.tools.safe_eval import safe_eval
```

### 5c — Vista `res_users.xml` (Makefile lo aplica automáticamente)

La vista original busca un elemento `<group name="preferences">` que no existe en Odoo 19. Se reemplaza por XPath sobre `//notebook`:

```bash
make odoo-fix-views
```

---
### 5d — Vista `ir.property` 
Esta eliminado de Odoo19 (Makefile lo aplica automáticamente)


```bash
make odoo-fix-data
```
---
### 5e — Vista `<tree>` 
Esta eliminado de Odoo19 (Makefile lo aplica automáticamente)


```bash
make odoo-fix-tags
```
---
### 5f — Vista `ir.actions.act_window` 
Como Odoo 19 eliminó la palabra tree de todo su ecosistema de tipos de vista, el cliente web de Odoo lee tree,form, se confunde por completo al no saber qué es un "tree" en el frontend y rompe la interfaz. Cambiarlo a list,form!(Makefile lo aplica automáticamente)


```bash
make odoo-fix-actions
```
---
## Paso 6 — Instalar el módulo en Odoo

```bash
make odoo-update
```

Lo que hace internamente:
```bash
docker exec odoo19-server-dev odoo -d odoo_aje -i base_report_to_printer --stop-after-init
docker restart odoo19-server-dev
```

Si el módulo ya estaba instalado y solo se actualizó código, usar `-u` en lugar de `-i`:
```bash
docker exec odoo19-server-dev odoo -d odoo_aje -u base_report_to_printer --stop-after-init
```

---

## Paso 7 — Configuración manual en la UI de Odoo

> Estos pasos no se pueden automatizar porque requieren interacción con la interfaz web.

### 7a — Activar modo desarrollador
`Ajustes → Activar el modo desarrollador`

### 7b — Instalar el módulo desde Apps
`Apps → Buscar "base_report_to_printer" → Ins   talar`

### 7c — Registrar el servidor CUPS
`Ajustes → Técnico → Impresión → Servidores → Nuevo`

| Campo | Valor |
|-------|-------|
| Nombre | CUPS Local |
| Dirección IP | `172.17.0.1` *(IP del bridge Docker, ver nota)* |
| Puerto | `631` |

> **Cómo obtener la IP del bridge Docker:**
> ```bash
> ip addr show docker0 | grep "inet "
> # inet 172.17.0.1/16 ...
> ```
> No usar `localhost` ni `host.docker.internal`: desde dentro del contenedor, `localhost` apunta al propio contenedor, no al host WSL.

### 7d — Registrar la impresora
`Ajustes → Técnico → Impresión → Impresoras → Nueva`

| Campo | Valor |
|-------|-------|
| Nombre | PDF_FILTRADO |
| Servidor | CUPS Local (el del paso anterior) |
| Nombre en CUPS | `PDF_FILTRADO` |

### 7e — Configurar impresora predeterminada por usuario *(opcional)*
`Ajustes → Usuarios → [usuario] → pestaña "Impresión"`
---
### 7f forzar inslacion de dependencias

```bash
make odoo-force-deps
```
En lugar de cancel all runnning jobs de la impresora de interes
```bash
sudo cancel -a PDF_FILTRADO  # corregir para el uso desde la ui
```

### 7g — Configurar el driver de la impresora para modo "Raw"
Esta configuración evita que Odoo se quede bloqueado en estado "Printing..." al eliminar la espera de confirmación de estado innecesaria.

1. Accede a la interfaz de administración de CUPS: `http://localhost:631/admin`.
2. Ve a la pestaña **Impresoras** y selecciona `PDF_FILTRADO`.
3. En el menú **Administración**, haz clic en **Modificar impresora**.
4. En la página de Marca, haz clic en el botón **"Seleccione otra marca/fabricante"**.
5. Selecciona **"Raw"** de la lista y haz clic en **Continuar**.
6. En Modelo, selecciona **"Raw Queue (en)"** y haz clic en **Modificar impresora**.

> **¿Por qué este paso es vital?**
> Al configurar el driver como `Raw`, transformas la impresora en un canal de paso directo. Odoo ya no espera señales bidireccionales de estado (que la impresora virtual no puede enviar), logrando que la UI de Odoo marque el trabajo como completado inmediatamente después del envío.

---

### 7h — Reiniciar el servicio de impresión
Para aplicar el cambio de driver inmediatamente, reinicia el demonio de CUPS:

```bash
sudo systemctl restart cups
```

### 7i — NOTA: Preparación para impresoras físicas (Zebra/Epson)
La configuración en modo `Raw` que hemos realizado en `localhost:631` es ideal para tu entorno de desarrollo, pero cuando conectes una impresora física (como una térmica o de etiquetas), deberás ajustar este parámetro.

> **¿Cómo migrar a una impresora real?**
> Cuando sustituyas la impresora virtual por una física, no será necesario crear una impresora nueva en Odoo. Simplemente:
> 1. Accede nuevamente a `http://localhost:631/admin`.
> 2. Selecciona `PDF_FILTRADO` (o el nombre que tenga tu impresora).
> 3. En el menú **Administración**, elige **Modificar impresora**.
> 4. En lugar de seleccionar "Raw", selecciona el **fabricante y el modelo específico (PPD)** de tu nueva impresora física.
> 5. Esto permitirá que Odoo envíe los comandos de lenguaje de impresión (como ZPL para Zebra o ESC/POS para Epson) directamente al hardware.

El sistema de colas y el registro en Odoo seguirán funcionando exactamente igual, garantizando una transición suave hacia el hardware real.

---

## Paso 8 — Preparar la carpeta de salida

```bash
make traer-pdf      # crea ~/TutorialOdoo/impresiones_badge
make bashrc-fn      # agrega la función traer_pdf al .bashrc
source ~/.bashrc
```
La función `traer_pdf` copia los PDFs del spool de CUPS (que pertenece a root/lp) a tu carpeta de trabajo con permisos de tu usuario:

```bash
# Lo que se inyecta internamente en tu ~/.bashrc:
traer_pdf() {
    local SRC="[Ruta de tu CUPS_SPOOL]"
    local DST="[Ruta de tu OUTPUT_DIR]"
    echo "Buscando archivos en $SRC ..."
    # ... (resto de la lógica find de tu Makefile) ...
}
```

---

## Flujo de prueba

1. Ajustes, printing, reports, print bange :
- Default Behaviour
Send To Printer
- Default Printer
PDF_FILTRADO

2. En Odoo, ve a **Empleados → [un empleado] → Imprimir insignia**.
3. En el diálogo de impresión, selecciona la impresora `PDF_FILTRADO` y confirma.
4. En WSL2, ejecuta:
   ```bash
   traer_pdf
   ls -l /var/spool/cups-pdf/ANONYMOUS/
   ls -l /home/esau/odoo19_test_impresora/impresiones_badge
   ```
5. El archivo `Badge_-_NombreEmpleado.pdf` debe aparecer con contenido válido (~40-50 KB).

Para acceder desde Windows:
```
\\wsl.localhost\Ubuntu\home\esau\odoo19_test_impresora\impresiones_badge
```

---

## Monitoreo y depuración

```bash
# Iniciar infraestructura de impresión (obligatorio tras reiniciar)
make cups-start

# Ver estado general del entorno
make status

# Limpiar cola de impresión (si Odoo marca error o se bloquea)
sudo cancel -a PDF_FILTRADO

# Log de CUPS en tiempo real (para ver errores de drivers/filtros)
sudo tail -f /var/log/cups/error_log

# Ver trabajos de impresión pendientes en el sistema
lpstat -o

# Verificar que CUPS escucha en el puerto 631
sudo ss -tulnp | grep 631

# Verificar conectividad desde el contenedor Odoo hacia el host
docker exec odoo19-server-dev curl -s [http://172.17.0.1:631/printers/](http://172.17.0.1:631/printers/) | grep -o 'PDF[^<]*'
```
---

## Referencia rápida de comandos Makefile

| Comando | Descripción |
|---------|-------------|
| `make cups-start` | **[EJECUTAR CADA SESIÓN]** Levanta el servicio CUPS |
| `make all` | Flujo completo (primera vez) |
| `make up` | Levanta los contenedores Odoo |
| `make start-all` | Receta de inicio rapido,require que el flujo se haya completado antes |
| `make cups-install` | Instala CUPS y filtros necesarios |
| `make cups-printer` | Registra la impresora `PDF_FILTRADO` |
| `make cups-perms` | Corrige permisos del directorio de spool |
| `make odoo-deps` | Instala `pycups` en el contenedor |
| `make odoo-fix-manifest` | Parchea versión en `__manifest__.py` |
| `make odoo-fix-registry` | Parchea importación de `registry` |
| `make odoo-fix-views` | Reemplaza `res_users.xml` |
| `make odoo-fix-data` | Elimina datos incompatibles (`ir.property`) |
| `make odoo-fix-tags` | Migra etiquetas `<tree>` a `<list>` |
| `make odoo-fix-actions` | Sanea `view_mode` a `list` |
| `make odoo-update` | Instala/actualiza el módulo en Odoo |
| `make traer-pdf` | Prepara carpeta de salida (`impresiones_badge`) |
| `make bashrc-fn` | Configura función `traer_pdf` en el `.bashrc` |
| `make status` | Resumen del estado de servicios y archivos |
| `make clean` | Limpieza total de PDFs generados |
Variables personalizables:
```bash
make all ODOO_DB=mi_db ODOO_CTR=mi_contenedor USER=mi_usuario
```