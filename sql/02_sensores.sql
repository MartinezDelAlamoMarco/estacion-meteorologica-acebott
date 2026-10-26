-- Añade a dbo.Lecturas las columnas del resto de sensores.
-- Al principio solo guardábamos temperatura y humedad, y luego ampliamos.
-- Se puede ejecutar más de una vez: solo añade las columnas que falten.
-- Ejecútalo con tu usuario de Windows, no con estacion_app (no tiene permisos para ALTER).

USE EstacionMeteo;
GO

IF COL_LENGTH('dbo.Lecturas', 'Lluvia')    IS NULL ALTER TABLE dbo.Lecturas ADD Lluvia    INT          NULL;  -- sensor de gotas, analógico 0-4095
IF COL_LENGTH('dbo.Lecturas', 'Vibracion') IS NULL ALTER TABLE dbo.Lecturas ADD Vibracion BIT          NULL;  -- 1 = hay vibración
IF COL_LENGTH('dbo.Lecturas', 'UV')        IS NULL ALTER TABLE dbo.Lecturas ADD UV        INT          NULL;  -- índice UV
IF COL_LENGTH('dbo.Lecturas', 'Presion')   IS NULL ALTER TABLE dbo.Lecturas ADD Presion   DECIMAL(8,2) NULL;  -- hPa
IF COL_LENGTH('dbo.Lecturas', 'Luz')       IS NULL ALTER TABLE dbo.Lecturas ADD Luz       INT          NULL;  -- analógico 0-4095, más alto = más oscuro
IF COL_LENGTH('dbo.Lecturas', 'Viento')    IS NULL ALTER TABLE dbo.Lecturas ADD Viento    DECIMAL(5,1) NULL;  -- m/s
IF COL_LENGTH('dbo.Lecturas', 'PM25')      IS NULL ALTER TABLE dbo.Lecturas ADD PM25      INT          NULL;  -- microgramos por m3
GO

SELECT TOP 10 * FROM dbo.Lecturas ORDER BY Id DESC;
