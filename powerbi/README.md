# Dashboard de Power BI

Proyecto de Power BI guardado como `.pbip` (formato de proyecto en texto), así se puede ver y versionar en Git.

Antes de abrirlo tienes que haber creado la vista `vw_Lecturas` con `sql/03_vista_powerbi.sql`.

Para abrirlo:

1. Abre `EstacionACEBOTT.pbip` con Power BI Desktop. Tienen que estar juntas las carpetas `EstacionACEBOTT.Report` y `EstacionACEBOTT.SemanticModel`.
2. Si te pide credenciales de SQL Server: Windows, "Usar mis credenciales actuales".
3. Si sale un aviso amarillo, dale a Actualizar.

Se conecta a `localhost` y a la base de datos `EstacionMeteo` en modo DirectQuery, por eso lo usamos en el propio servidor. Si tu SQL Server está en otro sitio, cambia el origen en Transformar datos, Configuración del origen de datos.

Para que se refresque solo: haz clic en un hueco vacío de la página y en Formato activa "Actualización de página" cada minuto.

Las carpetas `.pbi` son ajustes locales de cada equipo y no se suben (están en el `.gitignore`).
