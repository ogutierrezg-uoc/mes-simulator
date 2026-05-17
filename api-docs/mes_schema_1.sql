-- ============================================================
-- SISTEMA MES - SCRIPT DE CREACIÓN DE BASE DE DATOS
-- SQL Server · TFG Ingeniería del Software
-- Autor: Óscar Gutiérrez González
-- Descripción: Esquema completo del sistema MES basado en
--              arquitectura orientada a eventos para línea SMT
-- ============================================================

USE master;
GO

IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'MES_DB')
    CREATE DATABASE MES_DB;
GO

USE MES_DB;
GO

-- ============================================================
-- 1. MÓDULO DE CONFIGURACIÓN
-- ============================================================

-- ------------------------------------------------------------
-- 1.1 Productos
-- Artículos fabricables. Cada producto tiene una cara (CA/CB)
-- y un código base que relaciona ambas caras del mismo artículo.
-- ------------------------------------------------------------
CREATE TABLE Producto (
    id          INT IDENTITY(1,1) PRIMARY KEY,
    referencia  NVARCHAR(50)  NOT NULL UNIQUE,
    descripcion NVARCHAR(200) NOT NULL,
    cara        NVARCHAR(2)   NOT NULL CHECK (cara IN ('CA', 'CB')),
    base        NVARCHAR(50)  NOT NULL,
    activo      BIT           NOT NULL DEFAULT 1,
    fecha_alta  DATETIME2     NOT NULL DEFAULT GETDATE()
);
GO

-- ------------------------------------------------------------
-- 1.2 Estaciones
-- Máquinas físicas de la línea de producción.
-- isRepair indica si es la estación de reparaciones.
-- ------------------------------------------------------------
CREATE TABLE Estacion (
    id          INT IDENTITY(1,1) PRIMARY KEY,
    nombre      NVARCHAR(50)  NOT NULL UNIQUE,
    tipo        NVARCHAR(50)  NOT NULL,
    protocolo   NVARCHAR(50)  NOT NULL,
    is_repair   BIT           NOT NULL DEFAULT 0,
    activa      BIT           NOT NULL DEFAULT 1
);
GO

-- ------------------------------------------------------------
-- 1.3 Materiales
-- Componentes, materias primas y semiacabados que se consumen
-- durante el proceso productivo.
-- tipo: RAW = materia prima, SEMI = semiacabado, FINISHED = acabado
-- ------------------------------------------------------------
CREATE TABLE Material (
    id          INT IDENTITY(1,1) PRIMARY KEY,
    referencia  NVARCHAR(50)  NOT NULL UNIQUE,
    descripcion NVARCHAR(200) NOT NULL,
    tipo        NVARCHAR(10)  NOT NULL CHECK (tipo IN ('RAW', 'SEMI', 'FINISHED')),
    unidad      NVARCHAR(10)  NOT NULL,
    activo      BIT           NOT NULL DEFAULT 1
);
GO

-- ------------------------------------------------------------
-- 1.4 Recetas
-- Programas de fabricación por producto y estación.
-- Define los parámetros que debe aplicar cada máquina.
-- ------------------------------------------------------------
CREATE TABLE Receta (
    id          INT IDENTITY(1,1) PRIMARY KEY,
    producto_id INT           NOT NULL REFERENCES Producto(id),
    estacion_id INT           NOT NULL REFERENCES Estacion(id),
    version     NVARCHAR(20)  NOT NULL,
    parametros  NVARCHAR(MAX) NULL,
    activa      BIT           NOT NULL DEFAULT 1,
    fecha_alta  DATETIME2     NOT NULL DEFAULT GETDATE(),
    UNIQUE (producto_id, estacion_id, version)
);
GO

-- ============================================================
-- 2. MÓDULO DE RUTAS Y ÓRDENES
-- ============================================================

-- ------------------------------------------------------------
-- 2.1 Rutas
-- Define la secuencia de operaciones para fabricar un producto.
-- Una misma ruta puede ser compartida por varios productos.
-- ------------------------------------------------------------
CREATE TABLE Ruta (
    id          INT IDENTITY(1,1) PRIMARY KEY,
    codigo      NVARCHAR(50)  NOT NULL UNIQUE,
    descripcion NVARCHAR(200) NOT NULL,
    version     NVARCHAR(20)  NOT NULL,
    activa      BIT           NOT NULL DEFAULT 1
);
GO

-- ------------------------------------------------------------
-- 2.2 Producto-Ruta (relación muchos a muchos)
-- Un producto puede usar varias rutas a lo largo del tiempo
-- y una ruta puede ser compartida por varios productos.
-- ------------------------------------------------------------
CREATE TABLE ProductoRuta (
    producto_id INT       NOT NULL REFERENCES Producto(id),
    ruta_id     INT       NOT NULL REFERENCES Ruta(id),
    fecha_desde DATETIME2 NOT NULL DEFAULT GETDATE(),
    fecha_hasta DATETIME2 NULL,
    PRIMARY KEY (producto_id, ruta_id)
);
GO

-- ------------------------------------------------------------
-- 2.3 Operaciones
-- Pasos secuenciales que componen una ruta.
-- condicional indica que la operación solo se ejecuta si se
-- cumple la condición definida (ej: resultado_AOI=OK).
-- ------------------------------------------------------------
CREATE TABLE Operacion (
    id               INT IDENTITY(1,1) PRIMARY KEY,
    ruta_id          INT           NOT NULL REFERENCES Ruta(id),
    estacion_id      INT           NOT NULL REFERENCES Estacion(id),
    orden_ejecucion  INT           NOT NULL,
    nombre           NVARCHAR(100) NOT NULL,
    condicional      BIT           NOT NULL DEFAULT 0,
    condicion        NVARCHAR(200) NULL,
    tiempo_ciclo_seg INT           NULL,
    UNIQUE (ruta_id, orden_ejecucion)
);
GO

-- ------------------------------------------------------------
-- 2.4 BOM (Bill of Materials)
-- Materiales que se consumen durante la producción.
-- Cada línea de BOM está asociada a una ruta y a la operación
-- específica donde se consume ese material.
-- ------------------------------------------------------------
CREATE TABLE BOM (
    id            INT IDENTITY(1,1) PRIMARY KEY,
    ruta_id       INT            NOT NULL REFERENCES Ruta(id),
    material_id   INT            NOT NULL REFERENCES Material(id),
    operacion_id  INT            NOT NULL REFERENCES Operacion(id),
    cantidad      DECIMAL(10, 4) NOT NULL,
    tipo_consumo  NVARCHAR(50)   NOT NULL DEFAULT 'Consumo RAW'
);
GO

-- ------------------------------------------------------------
-- 2.5 Órdenes de Fabricación
-- Instancia de producción para un producto concreto.
-- origen: ERP (llegó del ERP) o MES (creada en el propio MES)
-- estado: PENDIENTE, EN_PRODUCCION, FINALIZADA
-- ------------------------------------------------------------
CREATE TABLE OrdenFabricacion (
    id             INT IDENTITY(1,1) PRIMARY KEY,
    nombre         NVARCHAR(50)  NOT NULL UNIQUE,
    producto_id    INT           NOT NULL REFERENCES Producto(id),
    ruta_id        INT           NOT NULL REFERENCES Ruta(id),
    referencia_erp NVARCHAR(100) NULL,
    cantidad_obj   INT           NOT NULL,
    estado         NVARCHAR(20)  NOT NULL DEFAULT 'PENDIENTE'
                   CHECK (estado IN ('PENDIENTE', 'EN_PRODUCCION', 'FINALIZADA')),
    origen         NVARCHAR(5)   NOT NULL DEFAULT 'MES'
                   CHECK (origen IN ('ERP', 'MES')),
    fecha_inicio   DATETIME2     NULL,
    fecha_fin      DATETIME2     NULL,
    fecha_alta     DATETIME2     NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- 3. MÓDULO DE PRODUCCIÓN Y TRAZABILIDAD
-- ============================================================

-- ------------------------------------------------------------
-- 3.1 Piezas
-- Unidades físicas producidas. El serial es el identificador
-- único de cada pieza (número de serie).
-- estado: WIP, MAMA, SCRAP, BLOQUEADA, CONSUMIDO
-- CONSUMIDO indica que el SEMI de cara A fue consumido por CB.
-- ------------------------------------------------------------
CREATE TABLE Pieza (
    id           INT IDENTITY(1,1) PRIMARY KEY,
    serial       NVARCHAR(100) NOT NULL UNIQUE,
    orden_id     INT           NOT NULL REFERENCES OrdenFabricacion(id),
    estado       NVARCHAR(20)  NOT NULL DEFAULT 'WIP'
                 CHECK (estado IN ('WIP', 'MAMA', 'SCRAP', 'BLOQUEADA', 'CONSUMIDO')),
    fecha_entrada DATETIME2    NOT NULL DEFAULT GETDATE(),
    fecha_salida  DATETIME2    NULL
);
GO

-- ------------------------------------------------------------
-- 3.2 Trazabilidad
-- Registro de cada paso de una pieza por una estación.
-- Es el corazón del sistema MES — almacena el historial
-- completo de cada pieza por todas las operaciones.
-- ------------------------------------------------------------
CREATE TABLE Trazabilidad (
    id           INT IDENTITY(1,1) PRIMARY KEY,
    pieza_id     INT           NOT NULL REFERENCES Pieza(id),
    operacion_id INT           NULL REFERENCES Operacion(id),
    estacion_id  INT           NOT NULL REFERENCES Estacion(id),
    checkin      DATETIME2     NOT NULL DEFAULT GETDATE(),
    checkout     DATETIME2     NULL,
    resultado    NVARCHAR(5)   NULL CHECK (resultado IN ('OK', 'NOK')),
    datos        NVARCHAR(MAX) NULL,
    reparada     BIT           NOT NULL DEFAULT 0
);
GO

-- ------------------------------------------------------------
-- 3.3 Reparaciones
-- Registro de las reparaciones realizadas sobre piezas NOK.
-- Una pieza reparada puede ser reintroducida en la estación
-- donde falló para repetir la operación.
-- ------------------------------------------------------------
CREATE TABLE Reparacion (
    id            INT IDENTITY(1,1) PRIMARY KEY,
    pieza_id      INT           NOT NULL REFERENCES Pieza(id),
    reparador_id  INT           NULL REFERENCES Usuario(id),
    tipo          NVARCHAR(50)  NOT NULL,
    descripcion   NVARCHAR(500) NULL,
    resultado     NVARCHAR(5)   NOT NULL CHECK (resultado IN ('OK', 'NOK')),
    fecha         DATETIME2     NOT NULL DEFAULT GETDATE()
);
GO

-- ------------------------------------------------------------
-- 3.4 Paradas
-- Registro de paradas de producción con su motivo y duración.
-- Necesario para el cálculo del OEE (Disponibilidad).
-- ------------------------------------------------------------
CREATE TABLE Parada (
    id          INT IDENTITY(1,1) PRIMARY KEY,
    orden_id    INT           NOT NULL REFERENCES OrdenFabricacion(id),
    estacion_id INT           NULL REFERENCES Estacion(id),
    operario_id INT           NULL REFERENCES Usuario(id),
    motivo      NVARCHAR(200) NOT NULL,
    inicio      DATETIME2     NOT NULL DEFAULT GETDATE(),
    fin         DATETIME2     NULL
);
GO

-- ------------------------------------------------------------
-- 3.5 Consumos
-- Registro de los materiales consumidos por pieza y operación.
-- Se registra en el checkout OK de cada operación (en MES).
-- La notificación al ERP se hace al finalizar la pieza o scrap.
-- ------------------------------------------------------------
CREATE TABLE Consumo (
    id           INT IDENTITY(1,1) PRIMARY KEY,
    pieza_id     INT            NOT NULL REFERENCES Pieza(id),
    operacion_id INT            NOT NULL REFERENCES Operacion(id),
    material_id  INT            NOT NULL REFERENCES Material(id),
    cantidad     DECIMAL(10, 4) NOT NULL,
    fecha        DATETIME2      NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- 4. MÓDULO DE USUARIOS Y SEGURIDAD
-- ============================================================

-- ------------------------------------------------------------
-- 4.1 Roles
-- Agrupación de permisos. Cada usuario tiene un único rol.
-- ------------------------------------------------------------
CREATE TABLE Rol (
    id          INT IDENTITY(1,1) PRIMARY KEY,
    nombre      NVARCHAR(50)  NOT NULL UNIQUE,
    descripcion NVARCHAR(200) NULL
);
GO

-- ------------------------------------------------------------
-- 4.2 Permisos
-- Acciones permitidas por módulo del sistema.
-- ------------------------------------------------------------
CREATE TABLE Permiso (
    id      INT IDENTITY(1,1) PRIMARY KEY,
    modulo  NVARCHAR(50) NOT NULL,
    accion  NVARCHAR(50) NOT NULL,
    UNIQUE (modulo, accion)
);
GO

-- ------------------------------------------------------------
-- 4.3 Rol-Permiso (relación muchos a muchos)
-- ------------------------------------------------------------
CREATE TABLE RolPermiso (
    rol_id     INT NOT NULL REFERENCES Rol(id),
    permiso_id INT NOT NULL REFERENCES Permiso(id),
    PRIMARY KEY (rol_id, permiso_id)
);
GO

-- ------------------------------------------------------------
-- 4.4 Usuarios
-- Operarios, supervisores, ingenieros, reparadores y admins.
-- ------------------------------------------------------------
CREATE TABLE Usuario (
    id             INT IDENTITY(1,1) PRIMARY KEY,
    nombre         NVARCHAR(100) NOT NULL,
    apellidos      NVARCHAR(100) NOT NULL,
    login          NVARCHAR(50)  NOT NULL UNIQUE,
    password_hash  NVARCHAR(256) NOT NULL,
    rol_id         INT           NOT NULL REFERENCES Rol(id),
    activo         BIT           NOT NULL DEFAULT 1,
    fecha_alta     DATETIME2     NOT NULL DEFAULT GETDATE(),
    ultimo_acceso  DATETIME2     NULL
);
GO

-- ============================================================
-- 5. MÓDULO DE INTEGRACIÓN ERP
-- ============================================================

-- ------------------------------------------------------------
-- 5.1 Notificaciones ERP
-- Registro de todas las notificaciones enviadas al ERP.
-- Incluye el payload completo (pieza OK, scrap, OF finalizada).
-- ------------------------------------------------------------
CREATE TABLE NotificacionERP (
    id        INT IDENTITY(1,1) PRIMARY KEY,
    tipo      NVARCHAR(30)  NOT NULL
              CHECK (tipo IN ('PIEZA_OK', 'SCRAP', 'OF_FINALIZADA')),
    payload   NVARCHAR(MAX) NOT NULL,
    timestamp DATETIME2     NOT NULL DEFAULT GETDATE(),
    enviada   BIT           NOT NULL DEFAULT 0,
    ack       NVARCHAR(100) NULL,
    intentos  INT           NOT NULL DEFAULT 0
);
GO

-- ============================================================
-- 6. ÍNDICES
-- Optimizan las consultas más frecuentes del sistema.
-- ============================================================

-- Búsqueda de trazabilidad por pieza (consulta más frecuente)
CREATE INDEX IX_Trazabilidad_Pieza
    ON Trazabilidad(pieza_id);
GO

-- Búsqueda de trazabilidad por estación (estado de línea)
CREATE INDEX IX_Trazabilidad_Estacion
    ON Trazabilidad(estacion_id);
GO

-- Búsqueda de piezas por orden
CREATE INDEX IX_Pieza_Orden
    ON Pieza(orden_id);
GO

-- Búsqueda de piezas por serial (operación más frecuente en check-in)
CREATE INDEX IX_Pieza_Serial
    ON Pieza(serial);
GO

-- Búsqueda de operaciones por ruta
CREATE INDEX IX_Operacion_Ruta
    ON Operacion(ruta_id, orden_ejecucion);
GO

-- Búsqueda de notificaciones ERP pendientes
CREATE INDEX IX_NotificacionERP_Enviada
    ON NotificacionERP(enviada, timestamp);
GO

-- Búsqueda de órdenes por estado
CREATE INDEX IX_OrdenFabricacion_Estado
    ON OrdenFabricacion(estado);
GO

-- ============================================================
-- 7. DATOS INICIALES
-- ============================================================

-- Roles base del sistema
INSERT INTO Rol (nombre, descripcion) VALUES
    ('Administrador', 'Gestión completa del sistema MES'),
    ('Supervisor',    'Monitorización y generación de informes'),
    ('Operario',      'Operación de la línea de producción'),
    ('Ingeniero',     'Gestión de recetas y parámetros de proceso'),
    ('Reparador',     'Análisis y reparación de piezas NOK');
GO

-- Permisos base
INSERT INTO Permiso (modulo, accion) VALUES
    ('Ordenes',      'Ver'),
    ('Ordenes',      'Crear'),
    ('Ordenes',      'Finalizar'),
    ('Trazabilidad', 'Ver'),
    ('Trazabilidad', 'Exportar'),
    ('Piezas',       'Scrap'),
    ('Piezas',       'Reparar'),
    ('Recetas',      'Ver'),
    ('Recetas',      'Editar'),
    ('Usuarios',     'Gestionar'),
    ('Informes',     'Ver'),
    ('Informes',     'Exportar'),
    ('Sistema',      'Configurar');
GO

-- Estaciones de la Línea 1 SMT
INSERT INTO Estacion (nombre, tipo, protocolo, is_repair) VALUES
    ('Etiquetado-L1',  'Manual',     'GPIO',   0),
    ('SPP-L1',         'Automático', 'MQTT',   0),
    ('SPI-L1',         'Automático', 'MQTT',   0),
    ('Pick&Place-L1',  'Automático', 'MQTT',   0),
    ('Reflow-L1',      'Automático', 'Modbus', 0),
    ('AOI-L1',         'Automático', 'MQTT',   0),
    ('Packaging-L1',   'Manual',     'REST',   0),
    ('Reparaciones',   'Manual',     'REST',   1);
GO

PRINT 'Base de datos MES_DB creada correctamente.';
GO
