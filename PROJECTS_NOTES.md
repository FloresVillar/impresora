## impresora_net (docker-compose.yml)
El identiicador para la clave **networks** de primer nivel es **impresora_net**, esta es la red propia en el cual viven y se comunican nuestros dos servicios **myDB19_test**  y  **odoo_test** , contenedores para la base de datos y odoo respectivamente.

Seguidamente se usa un el parametro de configuracion **driver: brigde** quien definirá una red red de tipo PUENTE, los contenedores se comunican entre si y salen a internet, sin embargo están aislados a accesos desde el exterior.

Para soslayar problema de la asignaciones aleatorias de redes que Docker realiza, se toma el control manual para forzar un rango de IP´s mediante la sub clave **ipam** ,se declara un List of Mappings **config**, con un solo elemento (-), este tiene los atributos subnet y gateway. Es justamente en este primer atributo donde se declara la red con una mascara de red /24 (255.255.255.0) **-subnet: 172.30.0.0/24**

**Utilidad**

Esto es util pues cuspd (el servidor CUPS) vive en wsl2, mientras que odoo está dentro del contenedor Docker.La IP del gateway (172.30.0.1) mapea la interfaz de red del host desde la perspectiva del contenedor.Permitiendo que :
- El contenedor siempre sepa donde encontrar el backend de Linux
- Permite que OCA apunte a  **172.30.0.1:631** sin riesgo de que Docker cambie ip's tras un **make start-all**

**terminos simples**

Docker crea un "switch virtual" a quien le otorga el ip **172.30.0.1(gateway)** y configura las tablas de enrutamiento de Linux de manera que todo el trafico que los contenedores envian al gateway serán entregados a WSL (SO donde está Docker).<br>
Entonces cuando odoo(ej 172.30.0.2) marque a 172.30.0.1 , docker intercepta esa llamada en la "puerta de Odoo" y la redirige automaticamente hacia WSL puesto 631, donde habita CUPS.

**repaso teórico**

La mascara de red es /24 , como una dirección IPv4  tiene 32 bit , 32 -24  = 8 
```text
172   .   30   .    0   |   0
[8 bits]  [8 bits]  [8 bits]  | [8 bits libres]
|_______ 24 bits _______| |
       PARTE FIJA         |  PARTE VARIABLE
     (Nombre de Red)      | (Para tus contenedores)
```
se dispone de 8 bits libres, lo que corresponde a 2**8 = 256 direcciones ip's disponibles. Y como se sabe la primera direccion 172.30.0.0 para la red, la ultima 172.0.30.255  para el Broadcast. De tal modo que las ip's disponibles son 172.30.0.2 , 172.30.0.3 , ... ,172.30.0.254 . 

### miras a una futura arquitectura en producción
**Un servidor**

En un escenario real se dispondria de las siguientes arquitecturas
```text
                 Red Corporativa

                        │

              Ubuntu Server

              Docker Engine

        ┌─────────────────────────┐
        │ Docker Network          │
        │  172.30.0.0/24          │
        │  Docker Bridge          │
        │   172.30.0.1            │
        │ ├── Odoo 172.30.0.2     │
        │ ├── PostgreSQL 172.30.0.3│
        │ ├── Redis 172.30.0.5    │
        │ ├── Nginx 172.30.0.6    │
        │ └── CUPS 172.30.0.4     │
        └─────────────────────────┘
                   │
                   │
                   │ IPP / JetDirect /LPD
                   ▼

      192.168.1.100  Contabilidad

      192.168.1.110  Logística

      192.168.1.120  Producción
```
Todos los servicios viven dentro del mismo Docker Engine, la comunicación se daría entre Odoo → cups:631

**Dos servidores**
```text
                Red Corporativa

                     │

         ┌─────────────────────┐
         │  Servidor Odoo      │
         │    10.0.1.20        │
         │ Docker              │
         │ ├── Odoo            │
         │ ├── PostgreSQL      │
         │ └── Redis           │
         └─────────────────────┘

                     │
                HTTP (631)
                localhost:631
                     │

         ┌─────────────────────┐
         │    Servidor CUPS    │
         │     10.0.1.30       │
         │ Cola Contabilidad   │
         │ Cola Logistica      │
         │ Cola Produccion     │
         │ Cola Gerencia       │
         └─────────────────────┘

             │       │        │

             ▼       ▼        ▼
192.168.10.50  192.168.10.51 192.168.10.52
    Impresora1  Impresora2     Impresora3
```
Dos maquinas dedicadas distintas ej:
- Servidor Odoo 10.0.1.20
- Servidor CUPS 10.0.1.30
Odoo envia el pdf a http://10.0.1.30:631

**Disclaimer**

El escenario actual es 
```text
Windows
     │
     ▼
WSL2 (Ubuntu)
     │
     ├── CUPS (host)
     │
     └── Docker Engine
            │
     Docker Bridge (172.30.0.1)
            │
     ├── Odoo (172.30.0.2)
     └── PostgreSQL (172.30.0.3)

Odoo
   │
   ▼
172.30.0.1 (gateway)
   │
   ▼
CUPS
```
Se usa CUPS ejecutandose sobre WSL2 para una simplificar el acceso a dispositivos USB, sin embargo la misma logica puede desplegarse en un escenario real.
 
## variables de entorno 
Al ejecutar docker compose up , Docker realiza un proceso automatico en dos etapas:
- Interpolacion: En el contexto lee el .env para armar el YAML,lee los pares clave=valor y los expande ${VARIABLE} en el docker-compose 
- Inyección : pasa las variables dentro de los  contenedores,solo si estas estan declaradas dentro de la clave **environment**
Las variables de entorno de **.env** solo son ejecutadas en la fase de interpolacion , su utilidad se desarrolla en el makefile.


 