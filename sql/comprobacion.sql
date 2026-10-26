-- Un par de consultas para ver que están llegando datos.

USE EstacionMeteo;
GO

-- Las 10 últimas lecturas
SELECT TOP 10 * FROM dbo.Lecturas ORDER BY Id DESC;

-- Media por hora de las últimas 24 horas
SELECT DATEADD(HOUR, DATEDIFF(HOUR, 0, Fecha), 0) AS Hora,
       AVG(Temperatura) AS TempMedia,
       AVG(Humedad)     AS HumMedia,
       COUNT(*)         AS Lecturas
FROM dbo.Lecturas
WHERE Fecha >= DATEADD(DAY, -1, SYSDATETIME())
GROUP BY DATEADD(HOUR, DATEDIFF(HOUR, 0, Fecha), 0)
ORDER BY Hora;
