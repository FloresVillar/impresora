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
OCA_BRANCH  := 19.0

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
	sudo chmod -R 777 ./odoo_test_data
	sudo chmod -R 777 $(ADDONS_DIR)
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

# Detiene contenedores y BORRA los volúmenes (Base de datos limpia)RECURSO EXTREMO
borrar-db: check-env
	@echo ">>> Deteniendo contenedores de este proyecto..."
	docker compose --env-file .env down
	@echo ">>> Eliminando carpetas físicas de la base de datos y Odoo..."
	sudo rm -rf ./postgres19_test_data/
	sudo rm -rf ./odoo_test_data/
	@echo ">>> ¡Todo limpio de verdad! Listo para un inicio virgen."

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
ifndef ADDONS_DIR
	$(error Falta la variable DB_PORT en tu .env
	)
endif
ifndef ODOO_PORT
	$(error Falta la variable ODOO_PORT en tu .env
	)
endif
ifndef NOMBRE_IMPRESORA
	$(error Falta la variable NOMBRE_IMPRESORA en tu .env
	)
endif

# ── Objetivo principal ───────────────────────────────────────
all: check-env cups-start odoo-dowload-mod cups-install cups-printer cups-perms odoo-deps odoo-force-deps odoo-fix-manifest odoo-fix-registry odoo-fix-views odoo-fix-data odoo-fiix-tags odoo-fix-actions odoo-update
	@echo ""
	@echo " Configuración completa. Revisa la guía para los pasos manuales en la UI."
# -- inicio rapido
start-all: cups-start up
	@echo ">> sistema listo "

# descargando el modulo de la OCA, reemplazar git clone a futuro, de modo que se tenga un modulo (.zip)
odoo-download-modulo: check-env
	@echo ">>> Descargando repositorio completo de la OCA..."
	@rm -rf $(ADDONS_DIR)/report-print-send
	git clone $(OCA_REPO) -b $(OCA_BRANCH) $(ADDONS_DIR)/report-print-send
	@echo ">>> ¡Repositorio listo y actualizado!"


# ── 1. Instalar y levantar CUPS con filtros reales ───────────
 
cups-install: check-env
	@echo ">>> Instalando CUPS y filtros PDF..."
	sudo apt-get update -qq
	sudo apt-get install -y cups cups-filters printer-driver-cups-pdf cups-pdf
	sudo service cups start
	sudo cupsctl --remote-any
	sudo service cups restart
	@echo ">>> CUPS listo."

# ── 3. Corregir permisos del spool ..PARA LA IMPRESORA VIRTUAL───────────────────────────
 
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
	docker exec -u root $(ODOO_CTR) pip3 install pycups --break-system-packages
	docker restart $(ODOO_CTR)
	@echo ">>> Dependencias instaladas y contenedor reiniciado."

# ── 4b. Rescate: Instalación forzada de dependencias (para evitar errores de upgrade)
odoo-force-deps: check-env odoo-deps

# ── 6. Actualizar/instalar el módulo en Odoo ─────────────────
odoo-update: check-env
	@echo ">>> Instalando base_report_to_printer en la base $(ODOO_DB)..."
	docker exec $(ODOO_CTR) odoo \
	    -d $(ODOO_DB) \
	    -i base_report_to_printer,base_report_to_printer_cups,base_report_to_label_printer,base_report_to_printer_qztray,base_report_to_printer_websocket \
	    --stop-after-init
	docker restart $(ODOO_CTR)
	@echo ">>> Módulo instalado y contenedor reiniciado."
	
# ── 6. Actualizar de verdad (Upgrade) el módulo en Odoo ───────
odoo-upgrade: check-env
	@echo ">>> Forzando la ACTUALIZACIÓN (Upgrade) del módulo en la base $(ODOO_DB)..."
	docker exec $(ODOO_CTR) odoo \
		-d $(ODOO_DB) \
		-u base_report_to_printer \
		--stop-after-init
	docker restart $(ODOO_CTR)
	@echo ">>> Estructura de base de datos actualizada y contenedor reiniciado."
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

# -----------------IMPRESORA REAL---------------------
# Instala CUPS, utilitarios de comunicación y drivers específicos para la EPSON L3150
preparar-impresora: check-env
	@echo ">>> Actualizando el índice de paquetes..."
	sudo apt-get update -qq
	@echo ">>> Instalando herramientas USB, CUPS y drivers (Epson/Gutenprint)..."
	sudo apt-get install -y usbutils cups cups-ipp-utils printer-driver-escpr printer-driver-gutenprint
	@echo ">>> Corrigiendo permisos del backend USB de CUPS para detección en WSL2..."
	sudo chmod 0755 /usr/lib/cups/backend/usb
	@echo ">>> Reiniciando el servicio de CUPS..."
	sudo service cups restart
	@echo ">>> ¡Sistema listo! CUPS ya puede buscar e instalar la impresora física."
# ------luego de attach en powershell-----------------------------------------
desbloquear-usb:
	@echo ">>> 1. Limpiando cola de impresión por seguridad..." 
	@echo ">>> Detectando impresora en bus USB..."
	@# Buscamos la línea de Epson y extraemos el bus y el dispositivo
	@BUS=$$(lsusb | grep "04b8:1143" | awk '{print $$2}'); \
	DEV=$$(lsusb | grep "04b8:1143" | awk '{print $$4}' | tr -d ':'); \
	BUS_PATH="/dev/bus/usb/$$BUS/$$DEV"; \
	if [ -z "$$BUS" ] || [ -z "$$DEV" ]; then \
		echo "[ERROR] Impresora no detectada. ¿Hiciste el 'usbipd attach' en Windows?"; exit 1; \
	fi; \
	echo ">>> Dispositivo detectado en: $$BUS_PATH"; \
	sudo chmod 666 $$BUS_PATH
#.---
registrar-impresora: 
	@echo ">>> Detectando driver y dispositivo..."
	@echo "# Buscamos el driver exacto para L3150 automáticamente"
	@DRIVER=$$(lpinfo -m | grep -i "L3150" | grep "escpr" | head -n 1 | cut -d' ' -f1); \
	URI=$$(sudo /usr/lib/cups/backend/usb | grep 'usb://EPSON' | head -n 1 | awk '{print $$2}'); \
	\
	if [ -z "$$DRIVER" ]; then echo "[ERROR] Driver no encontrado."; exit 1; fi; \
	if [ -z "$$URI" ]; then echo "[ERROR] Impresora no detectada."; exit 1; fi; \
	\
	echo ">>> Usando driver: $$DRIVER"; \
	-sudo lpadmin -x "$(NOMBRE_IMPRESORA)" 2>/dev/null; \
	sudo lpadmin -p "$(NOMBRE_IMPRESORA)" -v "$$URI" -m "$$DRIVER" -E; \
	sudo lpadmin -d "$(NOMBRE_IMPRESORA)"; \
	echo ">>> ¡Configuración completada con el driver dinámico!"
#-----------------
prueba-impresora: 
	echo "Prueba de impresion $(NOMBRE_IMPRESORA)" | lp -d "$(NOMBRE_IMPRESORA)"
#----
actualizar-limpiar-impresora-real:
	sudo cancel -a "$(NOMBRE_IMPRESORA)"
#---
monitoreo-impresora:
	lpstat -p
	lpstat -o "$(NOMBRE_IMPRESORA)"
	lpstat -W completed -p "$(NOMBRE_IMPRESORA)"
# Busca líneas que empiecen por 'direct usb://' o 'network ipp://'
# El 'awk' extrae el segundo campo sin importar si hay uno o diez espacios
DEVICE_URI := $(shell lpinfo -v | grep -E '^(direct usb|network ipp)://' | head -n 1 | awk '{print $$2}')

configuracion-impresora-real-2: 
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
# ── 1. PREPARACIÓN ÚNICA (WSL2 optimizado) ──

# ── 2. CONFIGURACIÓN DE IMPRESORA (Busca y registra) ──
# Este target usa la preparación previa y se enfoca solo en detectar y registrar.


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