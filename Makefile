# ============================================================
#  Makefile — Impresión PDF desde Odoo 19 vía CUPS (WSL2)
#  Proyecto: TutorialOdoo / Odoo-19-Develop
# ============================================================

-include .env
export
ENV_FILE=.env

USER        ?= $(shell whoami)
CUPS_SPOOL  := /var/spool/cups-pdf/ANONYMOUS
OCA_REPO    := https://github.com/OCA/report-print-send.git
OCA_BRANCH  := 17.0

.PHONY: cups-start fix-env cups-printer-fix up down restart-net all all-start odoo-download-mod check-env cups-install cups-printer cups-perms \
        odoo-module-install odoo-fix-manifest odoo-fix-registry odoo-fix-views odoo-fix-tags odoo-fix-actions odoo-patch-all\
        odoo-deps odoo-update odoo-force-deps traer-pdf bashrc-fn \
        status clean help dependencias-impresora-real configuracion-impresora-real prueba-impresora-real actualizar-impresora-real monitoreo-impresora-real
# 
cups-start:
	@echo "--- Iniciando servicio CUPS ---"
	@if sudo service cups status | grep -q "is running"; then \
		echo "CUPS ya está corriendo."; \
	else \
		sudo service cups start && echo "CUPS iniciado correctamente."; \
	fi
# Target para limpiar el archivo .env de forma total 
fix-env:
	@echo ">>> Normalizando $(ENV_FILE)..."
	@# Eliminar caracteres Windows, espacios extra al inicio/final y asegurar formato
	@if [ -f $(ENV_FILE) ]; then \
		sed -i 's/\r//g' $(ENV_FILE); \
		sed -i 's/^[[:space:]]*//;s/[[:space:]]*$$//' $(ENV_FILE); \
		sed -i '/^$$/d' $(ENV_FILE); \
		sed -i 's/=[[:space:]]*/=/' $(ENV_FILE); \
		echo ">>> Archivo $(ENV_FILE) validado."; \
	else \
		echo ">>> [ERROR] $(ENV_FILE) no encontrado."; exit 1; \
	fi
	cat -A .env
	
# docker compose up -d
up: fix-env check-env
	@echo ">>> Creando carpetas locales de datos con permisos correctos..."
	mkdir -p ./odoo_test_data
	mkdir -p $(ADDONS_DIR)
	mkdir -p $(OUTPUT_DIR)
	sudo chmod -R 777 ./odoo_test_data
	sudo chmod -R 777 $(ADDONS_DIR)
	sudo chmod -R 777 $(OUTPUT_DIR)
	@echo ">>> Levantando contenedores en segundo plano...$(PROJECT_NAME)"
	docker compose --env-file .env up -d 
	@echo ">>> Contenedores iniciados. Odoo respondiendo en localhost:$(ODOO_PORT)"
# docker compose down
down: check-env
	@echo ">>> Deteniendo y eliminando contenedores..."
	docker compose --env-file .env down
	@echo ">>> Contenedores detenidos."

# Recrea contenedores aplicando cambios de red del docker-compose.yml
# Docker prefija el nombre del proyecto al nombre de la red (ej: impresora_test_impresora_net)
restart-net: down up
	@echo ">>> Contenedores recreados con nueva configuración de red."
	@echo ">>> Verificando gateway de la red..."
	@NET=$$(docker network ls --filter name=impresora_net --format '{{.Name}}' | head -1); 	docker network inspect $$NET | grep Gateway

#validando variables de existan
check-env:
ifndef ODOO_DB
	$(error El archivo .env
	 no existe o le falta la variable ODOO_DB. Copia .env.example a .env y configúralo)
endif
ifndef ODOO_CTR
	$(error Falta la variable ODOO_CTR en tu .env
	)
endif
ifndef DB_PORT
	$(error Falta la variable DB_PORT en tu .env
	)
endif
ifndef ODOO_PORT
	$(error Falta la variable ODOO_PORT en tu .env
	)
endif
ifndef ADDONS_DIR
	$(error Falta la variable ADDONS_DIR en tu .env
	)
endif
ifndef OUTPUT_DIR
	$(error Falta la variable OUTPUT_DIR en tu .env
	)
endif

# ── Objetivo principal ───────────────────────────────────────
all: check-env cups-start odoo-dowload-mod cups-install cups-printer cups-perms odoo-deps odoo-force-deps odoo-fix-manifest odoo-fix-registry odoo-fix-views odoo-fix-data odoo-fiix-tags odoo-fix-actions odoo-update
	@echo ""
	@echo " Configuración completa. Revisa la guía para los pasos manuales en la UI."
# -- inicio rapido
start-all: cups-start up
	@echo ">> sistema listo "

# descargando el modulo de la OCA
odoo-download-mod: check-env
	@echo ">>> Descargando repositorio de la OCA (${OCA_BRANCH})..."
	@mkdir -p $(ADDONS_DIR)
	@rm -rf $(ADDONS_DIR)/base_report_to_printer
	@rm -rf $(ADDONS_DIR)/report-print-send
	git clone $(OCA_REPO) -b $(OCA_BRANCH) $(ADDONS_DIR)/report-print-send
	@echo ">>> Extrayendo base_report_to_printer..."
	mv $(ADDONS_DIR)/report-print-send/base_report_to_printer $(ADDONS_DIR)/
	@echo ">>> Limpiando archivos temporales..."
	rm -rf $(ADDONS_DIR)/report-print-send
	@echo ">>> Módulo descargado con éxito en $(ADDONS_DIR)/base_report_to_printer"



# ── 1. Instalar y levantar CUPS con filtros reales ───────────
cups-install: check-env
	@echo ">>> Instalando CUPS y filtros PDF..."
	sudo apt-get update -qq
	sudo apt-get install -y cups cups-filters printer-driver-cups-pdf cups-pdf
	sudo service cups start
	sudo cupsctl --remote-any
	sudo service cups restart
	@echo ">>> CUPS listo."

# ── 2. Registrar la impresora PDF_FILTRADO ───────────────────
cups-printer: check-env
	@echo ">>> Creando impresora PDF_FILTRADO con PPD genérico..."
	sudo lpadmin -p PDF_FILTRADO \
	             -v cups-pdf:/ \
	             -m "drv:///sample.drv/generic.ppd" \
	             -E
	sudo lpadmin -d PDF_FILTRADO
	@echo ">>> Impresora registrada:"
	lpstat -p -d

# ── 3. Corregir permisos del spool ───────────────────────────
cups-perms: check-env
	@echo ">>> Ajustando permisos del spool CUPS..."
	@# cups-pdf corre como 'nobody' — debe ser dueño de ANONYMOUS/ para escribir archivos
	@# chown lp:lp FALLA: nobody no puede hacer chmod sobre archivos que no le pertenecen
	sudo chown -R nobody:lp $(CUPS_SPOOL)
	sudo chown lp:lp $(CUPS_SPOOL)/..
	sudo chmod 777 $(CUPS_SPOOL)
	sudo chmod g+s $(CUPS_SPOOL)
	@echo ">>> Permisos aplicados."

# ── 4. Dependencias Python dentro del contenedor Odoo ────────
odoo-deps: check-env
	@echo ">>> Instalando libcups2 y pycups en el contenedor Odoo..."
	docker exec -u root $(ODOO_CTR) apt-get update -qq
	docker exec -u root $(ODOO_CTR) apt-get install -y libcups2-dev python3-dev gcc
	docker exec -u root $(ODOO_CTR) pip install pycups --break-system-packages
	docker restart $(ODOO_CTR)
	@echo ">>> Dependencias instaladas y contenedor reiniciado."

# ── 5. Aplicar parches al módulo base_report_to_printer ──────
#    Ejecuta solo si el módulo ya está copiado en ADDONS_DIR
# ── 5a. Corregir versión en el __manifest__.py ────────────────
# ── 5a. Corregir versión en el __manifest__.py ────────────────
odoo-fix-manifest: check-env
	@echo ">>> Actualizando versión a 19.0.1.3.0 en __manifest__.py..."
	@FILE=$(ADDONS_DIR)/base_report_to_printer/__manifest__.py; \
	if [ -f "$$FILE" ]; then \
		sed -i 's/"version":.*/"version": "19.0.1.3.0",/' "$$FILE"; \
		sed -i "s/'version':.*/'version': '19.0.1.3.0',/" "$$FILE"; \
		echo ">>> Versión actualizada con éxito."; \
	else \
		echo ">>> [ERROR] No se encontró el archivo __manifest__.py en $$FILE"; \
		exit 1; \
	fi
# --- 5b--
odoo-fix-registry: check-env
	@echo ">>> Parcheando importación de Registry en ir_actions_report.py..."
	@FILE=$(ADDONS_DIR)/base_report_to_printer/models/ir_actions_report.py; \
	sed -i 's/^from odoo import .*/from odoo import _, api, exceptions, fields, models/' "$$FILE"; \
	grep -q "from odoo.modules.registry import Registry as registry" "$$FILE" || \
	    sed -i '/^from odoo import/a from odoo.modules.registry import Registry as registry' "$$FILE"
	@echo ">>> Parche de registry aplicado."
# ---5c--
odoo-fix-views: check-env
	@echo ">>> Corrigiendo res_users.xml (compatibilidad Odoo 19)..."
	@mkdir -p $(ADDONS_DIR)/base_report_to_printer/views
	@echo '<?xml version="1.0" ?>' > $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '<odoo>' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '    <record model="ir.ui.view" id="view_users_form">' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '        <field name="name">res.users.form (in base_report_to_printer)</field>' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '        <field name="model">res.users</field>' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '        <field name="inherit_id" ref="base.view_users_form" />' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '        <field name="arch" type="xml">' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '            <xpath expr="//notebook" position="inside">' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '                <page string="Impresión" name="printing_page">' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '                    <group string="Configuración de Impresión Continua" name="printing">' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '                        <field name="printing_action" />' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo "                        <field name=\"printing_printer_id\" options=\"{'no_create': True}\" />" >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '                    </group>' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '                </page>' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '            </xpath>' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '        </field>' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '    </record>' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '    <record model="ir.ui.view" id="view_users_form_simple_modif">' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '        <field name="name">res.users.form.simple (in base_report_to_printer)</field>' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '        <field name="model">res.users</field>' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '        <field name="inherit_id" ref="base.view_users_form_simple_modif" />' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '        <field name="arch" type="xml">' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '            <xpath expr="//form/sheet" position="inside">' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '                <group string="Impresión" name="printing">' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '                    <field name="printing_action" readonly="0" />' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo "                    <field name=\"printing_printer_id\" readonly=\"0\" options=\"{'no_create': True}\" />" >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '                </group>' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '            </xpath>' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '        </field>' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '    </record>' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo '</odoo>' >> $(ADDONS_DIR)/base_report_to_printer/views/res_users.xml
	@echo ">>> res_users.xml reemplazado."

# ---5d--
odoo-fix-data: check-env
	@echo ">>> Desactivando datos incompatibles de ir.property en __manifest__.py..."
	@FILE=$(ADDONS_DIR)/base_report_to_printer/__manifest__.py; \
	if [ -f "$$FILE" ]; then \
		sed -i "s/'data\/printing_data.xml',//" "$$FILE"; \
		sed -i 's/"data\/printing_data.xml",//' "$$FILE"; \
		echo ">>> Datos antiguos desactivados con éxito."; \
	else \
		echo ">>> [ERROR] No se encontró el archivo __manifest__.py"; \
		exit 1; \
	fi
# ---5e--
odoo-fix-tags: check-env
	@echo ">>> Reemplazando de manera GLOBAL todas las vistas <tree> obsoletas por <list>..."
	@DIR=$(ADDONS_DIR)/base_report_to_printer; \
	if [ -d "$$DIR" ]; then \
		find "$$DIR" -type f -name "*.xml" -exec sed -i 's/<tree/<list/g' {} +; \
		find "$$DIR" -type f -name "*.xml" -exec sed -i 's/<\/tree/<\/list/g' {} +; \
		echo ">>> Todo el código XML del módulo ha sido actualizado a <list>."; \
	else \
		echo ">>> [ERROR] No se encontró la carpeta del módulo en $$DIR"; \
		exit 1; \
	fi
# ---5f--
odoo-fix-actions: check-env
	@echo ">>> Saneando view_mode de 'tree' a 'list' en XML y Python..."
	@DIR=$(ADDONS_DIR)/base_report_to_printer; \
	if [ -d "$$DIR" ]; then \
		find "$$DIR" -type f -name "*.xml" -exec sed -i 's/view_mode">tree/view_mode">list/g' {} +; \
		find "$$DIR" -type f -name "*.xml" -exec sed -i 's/view_mode="tree/view_mode="list/g' {} +; \
		find "$$DIR" -type f -name "*.py" -exec sed -i "s/'view_mode': 'tree/'view_mode': 'list/g" {} +; \
		find "$$DIR" -type f -name "*.py" -exec sed -i 's/"view_mode": "tree/"view_mode": "list/g' {} +; \
		find "$$DIR" -type f -name "*.py" -exec sed -i "s/'view_mode': 'tree,/'view_mode': 'list,/g" {} +; \
		echo ">>> Todo el código corregido con éxito."; \
	else \
		echo ">>> [ERROR] No se encontró la carpeta del módulo"; \
		exit 1; \
	fi
# Agrupa todos los parches de Odoo 19
odoo-patch-all: odoo-fix-manifest odoo-fix-registry odoo-fix-views odoo-fix-data odoo-fix-tags odoo-fix-actions
	@echo ">>> Todos los parches de Odoo 19 han sido aplicados con éxito."
# ── 4b. Rescate: Instalación forzada de dependencias (para evitar errores de upgrade)
odoo-force-deps: check-env
	@echo ">>> Instalando dependencias críticas (libcups2-dev, gcc, pycups) en el contenedor..."
	docker exec -u root $(ODOO_CTR) apt-get update -qq
	docker exec -u root $(ODOO_CTR) apt-get install -y libcups2-dev gcc python3-dev
	docker exec -u root $(ODOO_CTR) pip3 install pycups --break-system-packages
	docker restart $(ODOO_CTR)
	@echo ">>> Dependencias instaladas. Intenta el upgrade nuevamente."
 
# ── 6. Actualizar/instalar el módulo en Odoo ─────────────────
odoo-update: check-env
	@echo ">>> Instalando base_report_to_printer en la base $(ODOO_DB)..."
	docker exec $(ODOO_CTR) odoo \
	    -d $(ODOO_DB) \
	    -i base_report_to_printer \
	    --stop-after-init
	docker restart $(ODOO_CTR)
	@echo ">>> Módulo instalado y contenedor reiniciado."
# ── Definición de la función (con etiquetas de control)
# Configuración definitiva del driver genérico para evitar errores de filtro
cups-printer-fix:
	@echo ">>> Configurando impresora PDF_FILTRADO con PPD genérico..."
	sudo lpadmin -p PDF_FILTRADO -v cups-pdf:/ -m "drv:///sample.drv/generic.ppd" -E
	sudo lpadmin -d PDF_FILTRADO
	sudo service cups restart
	@echo ">>> Verificación de PPD:"
	@lpoptions -p PDF_FILTRADO -l | head -3
	@echo ">>> ¡Impresora lista! Prueba ahora imprimir desde Odoo."
#---
define BASHRC_FUNC
# --- INICIO_TRAER_PDF ---
traer_pdf() {
    local SRC="/var/spool/cups-pdf/ANONYMOUS"
    local DST="$(OUTPUT_DIR)"
    echo "Buscando archivos nuevos en $$SRC ..."
    sudo rsync -a --update --chown=$(USER):$(USER) "$$SRC"/*.pdf "$$DST"/ 2>/dev/null && \
        echo "¡Operación completada! PDFs en $$DST" || \
        echo "No hay archivos PDF nuevos en $$SRC"
}
# --- FIN_TRAER_PDF ---
endef
export BASHRC_FUNC

# ── . Crear carpeta de salida y función traer_pdf ───────────
traer-pdf: $(OUTPUT_DIR)
	@echo ">>> Carpeta de salida lista: $(OUTPUT_DIR)"

$(OUTPUT_DIR):
	mkdir -p $(OUTPUT_DIR)

# ── Inyectar/Actualizar función en ~/.bashrc (El motor de reemplazo) ──
bashrc-fn: check-env
	@echo ">>> Actualizando traer_pdf en ~/.bashrc..."
	@# 1. Si el bloque existe, lo borramos usando las etiquetas como anclas
	@sed -i '/# --- INICIO_TRAER_PDF ---/,/# --- FIN_TRAER_PDF ---/d' ~/.bashrc
	@# 2. Añadimos el bloque fresco al final
	@printf '%s\n' "$$BASHRC_FUNC" >> ~/.bashrc
	@echo ">>> ¡Actualizado correctamente! Recarga con: source ~/.bashrc"
# ── Utilidades ───────────────────────────────────────────────
status: check-env
	@echo "=== Estado de CUPS ==="
	sudo service cups status | head -5
	lpstat -p -d
	@echo ""
	@echo "=== Contenedor Odoo ==="
	docker ps --filter "name=$(ODOO_CTR)" --format "table {{.Names}}\t{{.Status}}"
	@echo ""
	@echo "=== Archivos en spool ==="
	sudo ls -lh $(CUPS_SPOOL)/ 2>/dev/null || echo "(vacío)"
	@echo ""
	@echo "=== Archivos en carpeta de trabajo ==="
	ls -lh $(OUTPUT_DIR)/ 2>/dev/null || echo "(vacío)"

clean: check-env
	@echo ">>> Limpiando archivos del spool CUPS..."
	sudo find $(CUPS_SPOOL) -name "*.pdf" -delete
	@echo ">>> Limpiando carpeta de trabajo..."
	rm -f $(OUTPUT_DIR)/*.pdf
	@echo ">>> Limpieza completada."

# IMPRESORA REAL 
dependencias-impresora-real: 
	sudo apt update
	sudo apt install -y usbutils cups cups-ipp-utils printer-driver-gutenprint printer-driver-all avahi-daemon
	sudo service avahi-daemon start
	sudo service cups restart

DEVICE_URI := $(shell lpinfo -v | grep -E "direct usb://|network (ipp|dnssd)://" | head -n 1 | cut -d ' ' -f 2)

configuracion-impresora-real: 
	@echo "detectando impresoras disponibles"
	if [ -z "$(DEVICE_URI)" ]; then \
		echo "Error: no hay impresoras conectadas ni usb" \
		exit 1; \
	fi
	@echo "Dispositivo $(DEVICE_URI)"
	@echo "---Reiniciando-- CUPS"
	sudo service cups restart
	@echo "--registrando como $(NOMBRE_IMPRESORA)"
	sudo lpadmin -p "$(NOMBRE_IMPRESORA)" -v "$(DEVICE_URI)" -m drv:///sample.drv/generic.ppd -E
	@echo "estableciendo a $(NOMBRE_IMPRESORA) como impresora por defecto" 
	sudo lpadmin -d "$(NOMBRE_IMPRESORA)"
	@echo "--configuracion realizada" 
	lpstat -p -d

prueba-impresora-real: 
	echo "Prueba de impresion $(NOMBRE_IMPRESORA)" | lp -d "$(NOMBRE_IMPRESORA)"

actualizar-impresora-real:
	sudo cancel -a "$(NOMBRE_IMPRESORA)"

monitoreo-impresora-real:
	lpstat -p
	lpstat -o "$(EPSON_L3150)"
	lpstat -W completed -p "$(EPSON_L3150)"

help:
	@echo ""
	@echo "Targets disponibles:"
	@echo "  all              — Flujo completo: CUPS + módulo Odoo"
	@echo "  cups-install     — Instala CUPS, cups-filters y cups-pdf"
	@echo "  cups-printer     — Registra la impresora PDF_FILTRADO"
	@echo "  cups-perms       — Corrige permisos del spool"
	@echo "  odoo-deps        — Instala pycups en el contenedor Odoo"
	@echo "  odoo-fix-manifest — Forzar versión 19.0.1.3.0 en __manifest__.py"
	@echo "  odoo-fix-registry— Parchea importación de Registry (Odoo 19)"
	@echo "  odoo-fix-views   — Reemplaza res_users.xml compatible"
	@echo "  odoo-update      — Instala el módulo en la BD Odoo"
	@echo "  traer-pdf        — Crea carpeta de salida impresiones_badge"
	@echo "  bashrc-fn        — Agrega función traer_pdf al .bashrc"
	@echo "  status           — Muestra estado general del entorno"
	@echo "  clean            — Elimina PDFs del spool y carpeta de trabajo"
	@echo ""
	@echo "Variables (sobreescribibles):"
	@echo "  USER=$(USER)  ODOO_DB=$(ODOO_DB)  ODOO_CTR=$(ODOO_CTR)"
	@echo "  ADDONS_DIR=$(ADDONS_DIR)"
	@echo ""