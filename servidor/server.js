// API de la estación meteorológica.
//
// Recibe las lecturas que manda el ESP32, las guarda en SQL Server y tiene
// un par de rutas para consultarlas (una en JSON y una página web sencilla).
// La configuración (contraseña de la base de datos, clave de la API, puerto)
// la lee de config.json, que lo genera el instalador. Si quieres montarlo a
// mano, copia config.example.json como config.json y rellénalo.

const express = require('express');
const sql = require('mssql');
const path = require('path');

let CFG;
try {
  CFG = require(path.join(__dirname, 'config.json'));
} catch (e) {
  console.error('No encuentro config.json. Ejecuta INSTALAR.bat o copia config.example.json como config.json.');
  process.exit(1);
}

const config = {
  server: CFG.dbServer || 'localhost',
  port: CFG.dbPort || 1433,
  database: CFG.dbName || 'EstacionMeteo',
  user: CFG.dbUser || 'estacion_app',
  password: CFG.dbPassword,
  // SQL Server en local usa un certificado autofirmado, así que lo aceptamos
  options: { encrypt: true, trustServerCertificate: true }
};
const API_KEY = CFG.apiKey;
const PUERTO  = CFG.puerto || 3000;

const app = express();
app.use(express.json());
let pool;

// Devuelve el número si es válido. Si viene vacío, como texto o como NaN,
// devuelve null y en la base de datos queda vacío.
const num = v => (typeof v === 'number' && Number.isFinite(v)) ? v : null;

const COLUMNAS = 'Fecha, Temperatura, Humedad, Lluvia, Vibracion, UV, Presion, Luz, Viento, PM25';

// La API está publicada en Internet con ngrok, así que solo dejamos escribir
// a quien mande la clave correcta en la cabecera X-API-Key. Es sencillo, pero
// para un proyecto así nos vale.
app.use('/api/lecturas', (req, res, next) => {
  if (req.method === 'POST' && req.get('X-API-Key') !== API_KEY) {
    console.warn('Petición rechazada (clave incorrecta) desde', req.ip);
    return res.sendStatus(401);
  }
  next();
});

// Aquí llegan las lecturas de la estación.
// Temperatura y humedad son obligatorias. El resto es opcional: si un sensor
// falla, esa columna queda vacía pero no perdemos toda la lectura.
// La fecha no la manda el ESP32, la pone SQL Server al insertar.
app.post('/api/lecturas', async (req, res) => {
  const b = req.body || {};
  const temperatura = num(b.temperatura);
  const humedad     = num(b.humedad);
  if (temperatura === null || humedad === null) {
    return res.status(400).send('Faltan temperatura o humedad');
  }
  const vib = num(b.vibracion);

  try {
    // Consulta parametrizada: los valores nunca se pegan dentro del SQL,
    // así evitamos inyección SQL.
    await pool.request()
      .input('t',    sql.Decimal(4, 1), temperatura)
      .input('h',    sql.Decimal(4, 1), humedad)
      .input('ll',   sql.Int,           num(b.lluvia))
      .input('vib',  sql.Bit,           vib === null ? null : (vib ? 1 : 0))
      .input('uv',   sql.Int,           num(b.uv))
      .input('pres', sql.Decimal(8, 2), num(b.presion))
      .input('luz',  sql.Int,           num(b.luz))
      .input('vto',  sql.Decimal(5, 1), num(b.viento))
      .input('pm',   sql.Int,           num(b.pm25))
      .query(`INSERT INTO dbo.Lecturas
                (Temperatura, Humedad, Lluvia, Vibracion, UV, Presion, Luz, Viento, PM25)
              VALUES (@t, @h, @ll, @vib, @uv, @pres, @luz, @vto, @pm)`);
    console.log(`${new Date().toLocaleString('es-ES')} Guardado:`, JSON.stringify(b));
    res.sendStatus(201);
  } catch (err) {
    console.error(err);
    res.sendStatus(500);
  }
});

// Las 20 últimas lecturas en JSON, por si quieres tirar de ellas desde otro sitio
app.get('/api/ultimas', async (req, res) => {
  try {
    const r = await pool.request().query(
      `SELECT TOP 20 ${COLUMNAS} FROM dbo.Lecturas ORDER BY Id DESC`);
    res.json(r.recordset);
  } catch (err) {
    console.error(err);
    res.sendStatus(500);
  }
});

// Pinta una celda de la tabla. Si el dato está vacío, pone un guion.
const celda = (v, unidad = '') => (v === null || v === undefined) ? '<td>-</td>' : `<td>${v}${unidad}</td>`;

// Página web con una tabla de las últimas lecturas. Se recarga sola cada
// 60 segundos. No lo bajamos más porque con ngrok gratis cada recarga cuenta
// como una petición.
app.get('/', async (req, res) => {
  try {
    const r = await pool.request().query(
      `SELECT TOP 20 ${COLUMNAS} FROM dbo.Lecturas ORDER BY Id DESC`);
    const filas = r.recordset.map(l => `<tr>
        <td>${l.Fecha.toLocaleString('es-ES')}</td>
        ${celda(l.Temperatura, ' °C')}${celda(l.Humedad, ' %')}
        ${celda(l.Presion, ' hPa')}${celda(l.Viento, ' m/s')}
        ${celda(l.UV)}${celda(l.Luz)}${celda(l.PM25, ' µg/m³')}
        ${celda(l.Lluvia)}${celda(l.Vibracion === null ? null : (l.Vibracion ? 'Sí' : 'No'))}
      </tr>`).join('');
    res.send(`<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="60">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Estación meteorológica</title>
      <style>
        body { font-family: system-ui, sans-serif; margin: 16px; }
        .scroll { overflow-x: auto; }
        table { border-collapse: collapse; white-space: nowrap; }
        th, td { border: 1px solid #ccc; padding: 6px 10px; text-align: right; }
        th { background: #f2f2f2; }
        td:first-child, th:first-child { text-align: left; }
      </style>
      <h1>Estación meteorológica</h1>
      <div class="scroll"><table>
        <tr><th>Fecha</th><th>Temp.</th><th>Humedad</th><th>Presión</th><th>Viento</th>
            <th>UV</th><th>Luz</th><th>PM2.5</th><th>Lluvia</th><th>Vibración</th></tr>
        ${filas}
      </table></div>`);
  } catch (err) {
    console.error(err);
    res.status(500).send('Error leyendo la base de datos');
  }
});

// Primero conectamos con SQL Server y solo después abrimos el puerto.
// Si la base de datos no responde, mejor que la API no arranque a medias.
// No le pasamos host a listen() para que escuche en IPv4 e IPv6: nos dio
// guerra que ngrok buscara "localhost" por IPv6 y la API solo estuviera en IPv4.
sql.connect(config)
  .then(p => {
    pool = p;
    app.listen(PUERTO, () => console.log(`API escuchando en el puerto ${PUERTO}`));
  })
  .catch(err => {
    console.error('No se pudo conectar a SQL Server:', err.message);
    process.exit(1);
  });
