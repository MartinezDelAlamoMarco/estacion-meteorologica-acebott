/*
  Estación meteorológica ACEBOTT (QE011) - firmware del ESP32

  Este programa parte del ejemplo de la lección 14 del tutorial de ACEBOTT,
  que lee todos los sensores y los enseña en la pantalla OLED en dos páginas.
  Nosotros le hemos añadido la parte de WiFi y el envío de las lecturas a
  nuestra API, que las guarda en SQL Server.

  Antes de subirlo:
    1. Copia secretos.h.example como secretos.h (en esta misma carpeta).
    2. Rellena tu WiFi, la URL de tu API y la clave (la misma que pusiste
       en el instalador del servidor).
  secretos.h está en el .gitignore, así que tus claves no se suben al repo.

  Placa en Arduino IDE: "ESP32 Dev Module". Monitor serie a 115200.
*/

#include <Arduino.h>
#include <Wire.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <U8g2lib.h>
#include <ACB_DHT11.h>
#include <ACB_Ultraviolet_V2.h>
#include <ACB_WindCup.h>
#include <ACB_PM25.h>
#include <ACB_Atmospheric.h>

#include "secretos.h"   // SSID, PASS, URL y API_KEY

// Cada cuánto mandamos una lectura. Lo tenemos en 1 minuto para ver los datos
// casi en directo, pero ojo: el plan gratis de ngrok da 20.000 peticiones al
// mes y así son unas 1.440 al día, o sea que se acaba en unas dos semanas.
// Si la vas a dejar funcionando mucho tiempo, súbelo a 5 minutos (5UL * 60UL * 1000UL).
const unsigned long INTERVALO_ENVIO = 1UL * 60UL * 1000UL;

// Pines del kit. Los analógicos van todos al ADC1, que es el que sigue
// funcionando con la WiFi encendida (el ADC2 se pelea con la WiFi).
#define raindropPin 39
#define vibrationPin 18
#define DHT11PIN 23
#define UVPin 33
#define lightPin 36
#define WindPin 32
#define PM25RX 17
#define PM25TX 16

U8G2_SSD1306_128X64_NONAME_F_HW_I2C u8g2(U8G2_R0, U8X8_PIN_NONE);
ACB_DHT11 dht11(DHT11PIN);
ACB_Ultraviolet uv;
ACB_Atmospheric BMP;
ACB_WindCup wind;
ACB_PM25 PM25;

int raindrop;
int vibration;
float tem;          // en el ejemplo original era int y perdíamos los decimales
float hum;          // el DHT11 mide la humedad de 1 en 1 %, pero la guardamos igual
int uv_level;
float barometric_pressure;
int light;
float windSpeed;    // también era int en el original
int PM25_value;

unsigned long ultimoEnvio = 0;
bool primerEnvio = true;
int ultimoCodigo = 0;   // lo que respondió la API la última vez (201 = guardado)

// Intenta conectar a la WiFi durante 15 segundos como mucho. Si no puede,
// no se queda colgado: la estación sigue midiendo y lo vuelve a intentar
// en el siguiente envío.
void conectarWiFi() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(SSID, PASS);
  Serial.print("Conectando a WiFi");
  unsigned long t0 = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t0 < 15000) {
    delay(500);
    Serial.print(".");
  }
  if (WiFi.status() == WL_CONNECTED) Serial.println("\nConectado. IP: " + WiFi.localIP().toString());
  else Serial.println("\nSin WiFi de momento, sigo midiendo y lo reintento luego.");
}

// Pasa un número a texto para el JSON. Si el sensor devuelve algo raro
// (NaN, infinito) mandamos null, y la API lo guarda vacío en vez de fallar.
String jnum(float v, int decimales = 1) {
  if (isnan(v) || isinf(v)) return "null";
  return String(v, decimales);
}

// Monta el JSON con todas las lecturas y lo manda por POST a la API.
void enviarDatos() {
  if (WiFi.status() != WL_CONNECTED) {
    WiFi.reconnect();
    Serial.println("Sin WiFi, esta lectura no se envía");
    ultimoCodigo = -1;
    return;
  }

  String json = "{";
  json += "\"temperatura\":" + jnum(tem) + ",";
  json += "\"humedad\":"     + jnum(hum) + ",";
  json += "\"lluvia\":"      + String(raindrop) + ",";
  json += "\"vibracion\":"   + String(vibration) + ",";
  json += "\"uv\":"          + String(uv_level) + ",";
  json += "\"presion\":"     + jnum(barometric_pressure, 2) + ",";
  json += "\"luz\":"         + String(light) + ",";
  json += "\"viento\":"      + jnum(windSpeed) + ",";
  json += "\"pm25\":"        + String(PM25_value);
  json += "}";

  HTTPClient http;
  // Ojo: mandamos por HTTP, no HTTPS. En la red de nuestro centro la conexión
  // HTTPS del ESP32 con ngrok se cortaba en el saludo TLS (con el PC iba bien).
  // Con una URL http:// hay que usar http.begin(URL) a secas: si le pasas un
  // WiFiClientSecure intenta cifrar y devuelve -1.
  http.begin(URL);
  http.setTimeout(8000);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("X-API-Key", API_KEY);
  http.addHeader("ngrok-skip-browser-warning", "1");   // salta el aviso de ngrok gratis
  ultimoCodigo = http.POST(json);
  Serial.printf("Enviado %s -> %d\n", json.c_str(), ultimoCodigo);   // 201 = guardado
  http.end();
}

void setup() {
  Serial.begin(115200);
  u8g2.setI2CAddress(0x3C * 2);
  u8g2.begin();
  u8g2.enableUTF8Print();
  uv.setpin(UVPin);
  PM25.setpin(PM25RX, PM25TX);
  wind.setpin(WindPin);
  BMP.Atmospheric_init();
  conectarWiFi();
}

void loop() {
  // 1. Leemos todos los sensores, igual que en el ejemplo del kit
  raindrop = analogRead(raindropPin);
  // El sensor de vibración va al revés: da 0 cuando vibra. Lo invertimos
  // para que en la base de datos 1 signifique "hay vibración".
  vibration = !digitalRead(vibrationPin);
  tem = dht11.get_Temperature_Data();
  hum = dht11.get_Humidity_Data();
  uv_level = uv.read("level");
  barometric_pressure = BMP.read("Press");
  light = analogRead(lightPin);
  windSpeed = wind.read();
  PM25_value = PM25.read();

  // 2. Enviamos nada más arrancar y luego cada INTERVALO_ENVIO.
  // Como cada vuelta del loop tarda unos 4 s (las dos páginas de la OLED),
  // el intervalo real queda en 60-64 s. Para esto nos da igual.
  if (primerEnvio || millis() - ultimoEnvio >= INTERVALO_ENVIO) {
    enviarDatos();
    ultimoEnvio = millis();
    primerEnvio = false;
  }

  // 3. Pantalla: dos páginas de 2 segundos cada una
  Page1();
  Page2();
}

// Página 1: icono de lluvia o sol, lluvia, temperatura, humedad y vibración
void Page1() {
  u8g2.clearBuffer();
  // Mismo criterio que el ejemplo del kit: por encima de 1000 pinta lluvia
  if (raindrop > 1000) {
    u8g2.setFontPosBottom();
    u8g2.setFont(u8g2_font_open_iconic_all_4x_t);
    u8g2.drawGlyph(0, 0 + 4 * 8, 241);
  } else {
    u8g2.setFontPosBottom();
    u8g2.setFont(u8g2_font_open_iconic_all_4x_t);
    u8g2.drawGlyph(0, 0 + 4 * 8, 259);
  }
  u8g2.setFont(u8g2_font_timR10_tf);
  u8g2.setFontPosTop();
  u8g2.setCursor(50, 0);
  u8g2.print(String("Rain:") + String(raindrop));

  u8g2.setCursor(50, 23);
  u8g2.print(String("Tem:") + String(tem, 1) + String("°C"));

  u8g2.setCursor(70, 45);
  u8g2.print(String("Hum:") + String(hum, 0) + String("%"));

  u8g2.setCursor(0, 45);
  u8g2.print(String("Vib:") + String(vibration));

  u8g2.sendBuffer();
  delay(2000);
}

// Página 2: UV, viento, luz, PM2.5, presión y, arriba a la derecha,
// cómo fue el último envío. Así sabes si llega al servidor sin abrir el monitor serie.
void Page2() {
  u8g2.clearBuffer();
  u8g2.setFont(u8g2_font_timR08_tf);
  u8g2.setFontPosTop();

  u8g2.setCursor(0, 0);
  u8g2.print(String("UV Level:") + String(uv_level));

  u8g2.setCursor(80, 0);
  if (WiFi.status() != WL_CONNECTED) u8g2.print("Sin WiFi");
  else if (ultimoCodigo == 201)      u8g2.print("Envio OK");
  else                               u8g2.print(String("Err ") + String(ultimoCodigo));

  u8g2.setCursor(0, 12);
  u8g2.print(String("Wind Speed:") + String(windSpeed, 1) + String("m/s"));

  u8g2.setCursor(0, 24);
  u8g2.print(String("Lightness:") + String(light));

  u8g2.setCursor(0, 36);
  u8g2.print(String("PM2.5:") + String(PM25_value) + String("µg/m³"));

  u8g2.setCursor(0, 48);
  u8g2.print(String("ATM:") + String(barometric_pressure, 1) + String("hPa"));

  u8g2.sendBuffer();
  delay(2000);
}
