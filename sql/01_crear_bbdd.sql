-- Crea la base de datos, la tabla de lecturas y el usuario que usa la API.
-- Si usas el instalador (INSTALAR.bat) no hace falta: lo hace él.
-- Esto es por si prefieres montarlo a mano desde SSMS.
--
-- Cambia la contraseña antes de ejecutarlo, y pon la misma en config.json.

CREATE DATABASE EstacionMeteo;
GO
USE EstacionMeteo;
GO

-- Una fila por cada envío de la estación. La fecha la pone SQL Server,
-- así el ESP32 no necesita saber la hora.
CREATE TABLE dbo.Lecturas (
    Id           INT IDENTITY(1,1) PRIMARY KEY,
    Fecha        DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    Temperatura  DECIMAL(4,1) NOT NULL,
    Humedad      DECIMAL(4,1) NOT NULL
);
GO

-- Usuario solo para la API: puede leer y escribir en esta base de datos y nada más
CREATE LOGIN estacion_app WITH PASSWORD = 'CambiaEstaContrasena_2026!';
GO
CREATE USER estacion_app FOR LOGIN estacion_app;
ALTER ROLE db_datareader ADD MEMBER estacion_app;
ALTER ROLE db_datawriter ADD MEMBER estacion_app;
GO
