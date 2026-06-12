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

.PHONY: cups-install cups-start fix-env check-env up down restart-net borrar-db \
        setup start-all odoo-download-modulo spool-perms \
        odoo-deps odoo-force-deps odoo-update odoo-upgrade \
        status clean preparar-impresora desbloquear-usb registrar-impresora \
        prueba-impresora actualizar-limpiar-impresora monitoreo-impresora \
        limpiar-impresora help registrar-impresora-wifi
 
# ── 1. Instalar y levantar CUPS con filtros reales ───────────
 
cups-install: check-env
	@echo ">>> Instalando CUPS y filtros PDF..."
	sudo apt-get update -qq
	sudo apt-get install -y cups cups-filters printer-driver-cups-pdf cups-pdf
	sudo service cups start
	sudo cupsctl --remote-any
	sudo service cups restart
	@echo ">>> CUPS listo."
# ---- 2. iniciar cups----
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
	@if [ -f $(ENV_FILE) ]; then \
		sed -i 's/\r//g' $(ENV_FILE); \
		# 1. Elimina espacios al inicio y final absoluto de cada línea \
		sed -i 's/^[[:space:]]*//;s/[[:space:]]*$$//' $(ENV_FILE); \
		# 2. ¡NUEVO! Elimina espacios justo antes de un comentario '#' \
		sed -i 's/[[:space:]]*#/#/g' $(ENV_FILE); \
		# 3. ¡NUEVO! Elimina espacios específicos alrededor del signo '=' (atrás y adelante) \
		sed -i 's/[[:space:]]*=[[:space:]]*/=/g' $(ENV_FILE); \
		# 4. Elimina líneas vacías \
		sed -i '/^$$/d' $(ENV_FILE); \
		echo ">>> Archivo $(ENV_FILE) corregido y blindado con éxito."; \
	else \
		echo ">>> [ERROR] $(ENV_FILE) no encontrado."; exit 1; \
	fi
	@cat -A $(ENV_FILE) 
#validando variables de existan
check-env:
ifndef ODOO_DB
	$(error El archivo .env no existe o le falta la variable ODOO_DB. Copia .env.example a .env y configúralo)
endif
ifndef ODOO_CTR
	$(error Falta la variable ODOO_CTR en tu .env)
endif
ifndef DB_PORT
	$(error Falta la variable DB_PORT en tu .env)
endif
ifndef ADDONS_DIR
	$(error Falta la variable ADDONS_DIR en tu .env)
endif
ifndef ODOO_PORT
	$(error Falta la variable ODOO_PORT en tu .env)
endif
ifndef NOMBRE_IMPRESORA
	$(error Falta la variable NOMBRE_IMPRESORA en tu .env)
endif
ifndef PRINTER_IP
	$(error Falta la variable PRINTER_IP en tu .env)
endif
ifndef PRINTER_DRIVER
	$(error Falta la variable PRINTER_DRIVER en tu .env)
endif
ifndef PRINTER_MARCA
	$(error Falta PRINTER_MARCA en .env)
endif
# -------------------------------------------------
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


# ── Objetivo principal ───────────────────────────────────────
setup: cups-install up odoo-download-modulo spool-perms odoo-force-deps odoo-update   
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

# ── 3. Corregir permisos del spool ..PARA LA IMPRESORA VIRTUAL───────────────────────────
 
spool-perms: check-env
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
	
# ── 6. Actualizar (Upgrade) el módulo en Odoo ───────
odoo-upgrade: check-env
	@echo ">>> Forzando la ACTUALIZACIÓN (Upgrade) del módulo en la base $(ODOO_DB)..."
	docker exec $(ODOO_CTR) odoo \
		-d $(ODOO_DB) \
		-u base_report_to_printer,base_report_to_printer_cups \
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
	 
clean: check-env
	@echo ">>> Limpiando archivos del spool CUPS..."
	sudo find $(CUPS_SPOOL) -name "*.pdf" -delete
	@echo ">>> Limpiando carpeta de trabajo..."

# ------------IMPRESORA REAL--CONEXION VIA USB -GENERALIZADO----------------

PRINTER_MARCA ?=EPSON
PRINTER_DRIVER ?=escpr
# Instala CUPS, utilitarios de comunicación y drivers específicos para la EPSON L3150(este caso)
preparar-impresora: check-env
	@echo ">>> Actualizando el índice de paquetes..."
	sudo apt-get update -qq
	@echo ">>> Instalando herramientas USB, CUPS y drivers (Epson/Gutenprint)...$(PRINTER_MARCA)"
	sudo apt-get install -y usbutils cups cups-ipp-utils printer-driver-$(PRINTER_DRIVER) printer-driver-gutenprint
	@echo ">>> Corrigiendo permisos del backend USB de CUPS para detección en WSL2..."
	sudo chmod 0755 /usr/lib/cups/backend/usb
	@echo ">>> Reiniciando el servicio de CUPS..."
	sudo service cups restart
	@echo ">>> ¡Sistema listo! CUPS ya puede buscar e instalar la impresora física."
# ------estrictamente luego de attach en powershell--------------------------------------- 
desbloquear-usb:
	lpinfo -v
	@echo ">>> 1. Limpiando cola de impresión por seguridad..."
	@echo ">>> Detectando impresora $(PRINTER_MARCA) en bus USB..."
	@# Detecta la línea de lsusb dinámicamente usando la marca de la impresora
	@LINE=$$(lsusb | grep -i "$(PRINTER_MARCA)" | head -n 1); \
	if [ -z "$$LINE" ]; then \
		echo "[ERROR] Impresora $(PRINTER_MARCA) no detectada. ¿Hiciste el 'usbipd attach' en Windows?"; exit 1; \
	fi; \
	BUS=$$(echo "$$LINE" | awk '{print $$2}'); \
	DEV=$$(echo "$$LINE" | awk '{print $$4}' | tr -d ':'); \
	BUS_PATH="/dev/bus/usb/$$BUS/$$DEV"; \
	echo ">>> Dispositivo detectado en: $$BUS_PATH"; \
	sudo chmod 666 $$BUS_PATH; \
	DEV_INT=$$(echo "$$DEV" | sed 's/^0*//'); \
	for d in /sys/bus/usb/devices/*; do \
		if [ -f "$$d/devnum" ] && [ "$$(cat $$d/devnum 2>/dev/null)" = "$$DEV_INT" ]; then \
			for intf in $$d/*:* ; do \
				if [ -d "$$intf/driver" ]; then \
					echo "$$(basename $$intf)" | sudo tee "$$intf/driver/unbind" >/dev/null 2>&1 || true; \
				fi; \
			done; \
		fi; \
	done
	@echo "desbloqueo hecho"
	lpinfo -v
# Busca y registra el hardware detectado de forma automática
registrar-impresora: check-env
	@echo ">>> Detectando driver y dispositivo para $(NOMBRE_IMPRESORA)..."
	@BUSQUEDA=$$(echo "$(NOMBRE_IMPRESORA)" | tr '_' ' '); \
	DRIVER=$$(lpinfo -m | grep -i "$$BUSQUEDA" | grep "$(PRINTER_DRIVER)" | head -n 1 | cut -d' ' -f1); \
	if [ -z "$$DRIVER" ]; then \
		MODELO_CORTO=$$(echo "$(NOMBRE_IMPRESORA)" | sed 's/.*_//'); \
		DRIVER=$$(lpinfo -m | grep -i "$$MODELO_CORTO" | grep "$(PRINTER_DRIVER)" | head -n 1 | cut -d' ' -f1); \
	fi; \
	if [ -z "$$DRIVER" ]; then \
		DRIVER=$$(lpinfo -m | grep -i "$(PRINTER_MARCA)" | grep "$(PRINTER_DRIVER)" | head -n 1 | cut -d' ' -f1); \
	fi; \
	URI=$$(sudo /usr/lib/cups/backend/usb | grep -i "usb://$(PRINTER_MARCA)" | head -n 1 | awk '{print $$2}'); \
	if [ -z "$$DRIVER" ]; then echo "[ERROR] Driver para el modelo o marca no encontrado."; exit 1; fi; \
	if [ -z "$$URI" ]; then echo "[ERROR] Dispositivo USB no detectado por el backend de CUPS."; exit 1; fi; \
	echo ">>> URI Encontrada: $$URI"; \
	echo ">>> Driver Seleccionado: $$DRIVER"; \
	sudo lpadmin -x "$(NOMBRE_IMPRESORA)" 2>/dev/null || true; \
	sudo lpadmin -p "$(NOMBRE_IMPRESORA)" -v "$$URI" -m "$$DRIVER" -E; \
	sudo lpadmin -d "$(NOMBRE_IMPRESORA)"; \
	echo ">>> ¡Configuración completada con éxito!"
#-----------------
prueba-impresora: 
	echo "Prueba de impresion $(NOMBRE_IMPRESORA)" | lp -d "$(NOMBRE_IMPRESORA)"
#----
actualizar-limpiar-impresora:
	sudo cancel -a "$(NOMBRE_IMPRESORA)"
#---
monitoreo-impresora:
	lpstat -p
	lpstat -o "$(NOMBRE_IMPRESORA)"
	lpstat -W completed -p "$(NOMBRE_IMPRESORA)"

# limpieza , elimina la impresora del registro
limpiar-impresora: check-env
	@echo ">>> Eliminando impresora $(NOMBRE_IMPRESORA) de CUPS..."
	-sudo lpadmin -x "$(NOMBRE_IMPRESORA)" 2>/dev/null
	lpstat -p
	@echo ">>> Limpiando cualquier trabajo en cola..."
	-sudo cancel -a -x 2>/dev/null
	@echo "Sistema limpio y listo para pruebas."
#  ------------ caso conectividad wifi-- NO PROBADO se requiere un router convencional---
# ── Conectividad Wi-Fi vía Red Convencional ───────────────────
registrar-impresora-wifi: check-env
	@echo ">>> Detectando driver local para $(NOMBRE_IMPRESORA)..."
	@DRIVER=$$(lpinfo -m | grep -i "$(NOMBRE_IMPRESORA)" | grep "$(PRINTER_DRIVER)" | head -n 1 | cut -d' ' -f1); \
	if [ -z "$$DRIVER" ]; then \
		DRIVER=$$(lpinfo -m | grep -i "$(PRINTER_MARCA)" | grep "$(PRINTER_DRIVER)" | head -n 1 | cut -d' ' -f1); \
	fi; \
	if [ -z "$$DRIVER" ]; then echo "[ERROR] Driver $(PRINTER_DRIVER) no encontrado en CUPS."; exit 1; fi; \
	echo ">>> Driver seleccionado: $$DRIVER"; \
	echo ">>> Registrando impresora en red vía JetDirect (Puerto 9100)..."; \
	-sudo lpadmin -x "$(NOMBRE_IMPRESORA)" 2>/dev/null; \
	sudo lpadmin -p "$(NOMBRE_IMPRESORA)" -v "socket://$(PRINTER_IP):9100" -m "$$DRIVER" -E; \
	sudo lpadmin -d "$(NOMBRE_IMPRESORA)"; \
	echo ">>> ¡Impresora Wi-Fi registrada con éxito usando driver real!"
#--------------------------------------------------------
help:
	@echo ""
	@echo "CUPS e impresora virtual:"
	@echo "  cups-install          — Instala CUPS, cups-filters y cups-pdf"
	@echo "  cups-start            — Inicia servicio CUPS"
	@echo "  spool-perms           — Corrige permisos del spool CUPS-PDF"
	@echo ""
	@echo "Contenedores:"
	@echo "  up                    — Levanta contenedores (crea dirs de datos)"
	@echo "  down                  — Detiene y elimina contenedores"
	@echo "  restart-net           — Recrea contenedores con nueva red"
	@echo "  borrar-db             — Detiene contenedores y borra datos (reset total)"
	@echo "  start-all             — cups-start + up (inicio de sesión normal)"
	@echo ""
	@echo "Módulo OCA:"
	@echo "  odoo-download-modulo  — Clona report-print-send de OCA (19.0)"
	@echo "  odoo-deps             — Instala pycups en el contenedor Odoo"
	@echo "  odoo-force-deps       — odoo-deps forzado (tras recrear contenedor)"
	@echo "  odoo-update           — Instala módulos en la BD Odoo"
	@echo "  odoo-upgrade          — Actualiza módulos existentes en la BD"
	@echo ""
	@echo "Impresora física (USB):"
	@echo "  preparar-impresora    — Instala drivers y herramientas USB"
	@echo "  desbloquear-usb       — Permite acceso al dispositivo USB"
	@echo "  registrar-impresora   — Detecta y registra impresora en CUPS"
	@echo "  prueba-impresora      — Envía texto de prueba"
	@echo "  actualizar-limpiar-impresora — Cancela trabajos en cola"
	@echo "  monitoreo-impresora   — Estado y trabajos completados"
	@echo "  limpiar-impresora     — Elimina impresora de CUPS"
	@echo ""
	@echo "Utilidades:"
	@echo "  fix-env               — Normaliza archivo .env"
	@echo "  status                — Estado de CUPS, contenedores y spool"
	@echo "  clean                 — Elimina PDFs del spool"
	@echo "  help                  — Muestra esta ayuda"
	@echo ""
	@echo "Variables (sobreescribibles):"
	@echo "  USER=$(USER)  ODOO_DB=$(ODOO_DB)  ODOO_CTR=$(ODOO_CTR)"
	@echo "  ADDONS_DIR=$(ADDONS_DIR)  NOMBRE_IMPRESORA=$(NOMBRE_IMPRESORA)"
	@echo "  PRINTER_MARCA=$(PRINTER_MARCA)  PRINTER_DRIVER=$(PRINTER_DRIVER)"
	@echo ""