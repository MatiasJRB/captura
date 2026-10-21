# Ola iOS + retorno de estados

Pedido aprobado por Matías el 21 de octubre de 2026: integrar las mejoras iOS
en main y completar el retorno Mac → iPhone sin depender de la cuenta de Mauro.

## Alcance, dueños y contrato

Captura/agente posee código iOS, worker, CLI, tests y documentación de esta ola.
Ningún recurso privado, grabador, cuenta o runtime existente se activa/modifica.
Se integra sólo `ios/` de la candidata local y sus regresiones; Android conserva
su propia ola. Primera etapa: Core + build iPhone/simulador sin ejecutar micrófono.
Segunda etapa: transporte real de metadatos por Drive, con pruebas ficticias.

El importador sigue GET-only. Un escritor separado `worker/feedback.py`, apagado
por defecto, crea/actualiza únicamente SU JSON marcado dentro de la carpeta
privada del teléfono fijada en la configuración. Nunca modifica audio, carpetas,
permisos ni Google Docs. Antes de escribir verifica cuenta, carpeta y propiedad
del reporte; duplicados o marcadores inválidos bloquean la operación. Retrying
descubre el mismo reporte; no crea uno por cada corrida. Sin texto ni audio.

El reporte schema_version=1 conserva folder_id, device_id, generated_at,
available y hasta 500 pares ID/SHA-256 con estado downloaded/transcribed/error.
Sólo incluye recibos de esa carpeta con fuente/hash coincidente; transcribed
requiere salida ASR comprometida. Sin fuente o evidencia se omite el resultado.

iOS usa su sesión Google y carpeta/device actuales para buscar y descargar el
reporte por HTTPS Google, con OAuth existente, sin servidor local ni nueva API key.
Verifica identidad/privacidad/parent/tamaño y envelope antes de mostrar estados.
El acceso drive.file depende de que el reporte sea accesible a la misma app OAuth;
si no es visible, muestra desconocido, sin ampliar scopes automáticamente.
No hay vinculación por email supuesto ni por un nombre de archivo solamente.

Un reporte tiene vigencia de una hora; tolerancia de reloj futuro de 60 segundos.
Ausente, vencido, conflictivo, de otra carpeta/dispositivo/cuenta o error de red:
limpiar éxito previo y mostrar sin confirmar. No confundir subida con transcripción.
Leer al volver al foreground y al sincronizar, incluso sin archivos por subir;
no prometer polling continuo cuando iOS suspenda la app. La cuenta/carpeta se
recomprueban tras el await para impedir aplicar una respuesta de sesión anterior.

## Aceptación y QA

- Mejoras iOS previas integradas, avisos silenciosos, UI oscura de estados sin
  navegador de archivos inicial, retrato/horizontal y controles existentes.
- `capture feedback --dry-run` no usa red. Publicación sólo con opt-in explícito;
  `capture run` publica metadatos al finalizar cuando ese opt-in está activo.
- Roundtrip Python → bytes del reporte → cliente Swift → resumen por ID/hash,
  verificado con fuentes y transportes ficticios, incluyendo reintento/dedupe,
  error ASR, falta de texto, cuenta/parent ajenos, duplicados y caducidad.
- Importador/publisher actuales conservan sus límites y regresiones.
- Gate técnico: Core, XCTest compilados, build iPhone sin firma, Python, public
  tree, harness y diff. `agent_ui`/`human_physical` quedan pendientes donde no hay
  iPhone; ningún test simulado se presenta como Drive real o QA física.
- Publicar el código por PR a main. TestFlight, firma, cuenta de Mauro, pruebas
  de micrófono y activación sobre la Mac privada quedan fuera de esta ola.

Fuentes oficiales: [Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth),
[update media](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/update).
El JSON es una copia de progreso, no nueva fuente de tareas ni una interpretación IA.
