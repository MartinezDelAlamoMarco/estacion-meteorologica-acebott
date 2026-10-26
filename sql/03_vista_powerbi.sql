-- Vista para el dashboard de Power BI.
-- Ejecútala una vez en SSMS con tu usuario de Windows. Se puede repetir
-- sin problema porque es CREATE OR ALTER.
--
-- La idea es que Power BI no tenga que hacer cuentas raras: aquí ya
-- separamos día y hora, pasamos la presión a hPa y traducimos UV,
-- calidad del aire, lluvia y vibración a texto que se entiende.
-- También quitamos las lecturas de prueba que mete el instalador (-99.9).

USE EstacionMeteo;
GO

CREATE OR ALTER VIEW dbo.vw_Lecturas AS
SELECT
    Id,
    Fecha,
    CAST(Fecha AS date)                                  AS Dia,
    DATEPART(HOUR, Fecha)                                AS Hora,
    DATEADD(HOUR, DATEDIFF(HOUR, 0, Fecha), 0)           AS FechaHora,
    Temperatura,
    Humedad,
    CAST(CASE WHEN Presion > 2000 THEN Presion / 100.0 ELSE Presion END AS DECIMAL(7,1)) AS Presion,
    Viento,
    UV,
    CASE
        WHEN UV IS NULL THEN NULL
        WHEN UV <= 2  THEN 'Bajo'
        WHEN UV <= 5  THEN 'Moderado'
        WHEN UV <= 7  THEN 'Alto'
        WHEN UV <= 10 THEN 'Muy alto'
        ELSE 'Extremo'
    END                                                  AS NivelUV,
    Luz,
    CAST(Luz * 100.0 / 4095 AS DECIMAL(5,1))             AS LuzPct,
    PM25,
    -- Tramos orientativos. Como referencia, la OMS recomienda no pasar de 15 de media diaria.
    CASE
        WHEN PM25 IS NULL THEN NULL
        WHEN PM25 <= 10 THEN 'Buena'
        WHEN PM25 <= 20 THEN 'Aceptable'
        WHEN PM25 <= 25 THEN 'Moderada'
        WHEN PM25 <= 50 THEN 'Mala'
        ELSE 'Muy mala'
    END                                                  AS CalidadAire,
    Lluvia,
    -- Mismo criterio que la pantalla de la estación (pinta lluvia si pasa de 1000).
    -- Si con tu sensor sale al revés, cambia ">" por "<".
    CASE WHEN Lluvia IS NULL THEN NULL WHEN Lluvia > 1000 THEN 'Sí' ELSE 'No' END AS Llueve,
    CASE Vibracion WHEN 1 THEN 'Sí' WHEN 0 THEN 'No' END AS Vibracion
FROM dbo.Lecturas
WHERE Temperatura > -50;
GO

-- Opcional: un usuario de solo lectura para Power BI.
-- Solo hace falta si abres Power BI desde OTRO equipo con usuario de SQL.
-- Si lo usas en el propio servidor con tu usuario de Windows, no lo necesitas.
/*
CREATE LOGIN powerbi_lector WITH PASSWORD = 'CambiaEsta_Clave_2026!';
CREATE USER  powerbi_lector FOR LOGIN powerbi_lector;
ALTER ROLE db_datareader ADD MEMBER powerbi_lector;
*/

-- Comprobación
SELECT TOP 10 * FROM dbo.vw_Lecturas ORDER BY Fecha DESC;
