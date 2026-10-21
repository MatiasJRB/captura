# Estado de transcripción de la Mac en el iPhone

El iPhone ya conoce su cola de subida. Para conocer la transcripción, la Mac
publica un JSON pequeño en la misma carpeta privada de Drive y el iPhone lo lee
con su cuenta existente. No hay servidor público, nueva API key ni audio/texto en
ese reporte. El importador y la publicación opcional de Google Docs no cambian.

## Configuración de la Mac

1. Actualizar al código que incluye esta función y comprobar la configuración:

   ```sh
   python3 bin/capture doctor
   ```

   Debe corresponder a la cuenta y carpeta que muestra el iPhone. Si falta una
   configuración, seguir [worker](worker.md); no copiar la de otro teléfono.
   Con configuración en otra ruta, agregar `--config /ruta/config.json` a cada
   comando. No imprimir ni compartir el archivo ni sus credenciales.
2. Revisar lo que envía, sin usar red ni leer credenciales:

   ```sh
   python3 bin/capture feedback --dry-run
   ```

   Esperado: `state: preview`, `network: false`; sólo IDs, hashes y estados. La
   revisión no publica nada y funciona con el opt-in todavía apagado.
3. Habilitar explícitamente este retorno y publicar un reporte:

   ```sh
   python3 bin/capture set --feedback on
   python3 bin/capture feedback
   ```

   Esperado: `state: published` y cantidad de recibos incluidos. La Mac comprueba
   la cuenta, la carpeta privada fijada y el dispositivo. Si falla, conservar el
   error sin claves: `feedback_account_mismatch` indica cuenta incorrecta;
   `feedback_duplicate_reports` requiere revisar los JSON duplicados, nunca
   borrar audios; `feedback_receipts_unavailable` requiere una corrida del worker.
   `feedback_http_403` puede indicar que el remoto no tiene acceso de escritura:
   consultar el setup del worker; no ampliar scopes ni reemplazar cuentas a ciegas.
4. Seguir ejecutando el worker de la manera habitual:

   ```sh
   python3 bin/capture run
   ```

   Cada corrida, aun sin nuevas transcripciones, renueva el reporte si está
   habilitado. El JSON de salida tiene una sección `feedback` con el resultado.
   El [job opcional existente](worker.md#optional-run-every-15-minutes-with-launchd)
   también usa este comando; no hace falta otro daemon. Ejecutar `worker.py`
   directamente sólo importa/transcribe y no publica el reporte.

Para apagar futuras publicaciones:

```sh
python3 bin/capture set --feedback off
```

El último reporte deja de ser válido al cumplir una hora. No se borra la carpeta
ni ningún original al desactivar la función.

## En el iPhone

Usar la candidata que incluye esta función y la cuenta/carpeta del mismo
teléfono. Al volver a Captura o tocar sincronizar, obtiene el reporte incluso si
no hay archivos pendientes de subir. Mientras la app está activa reconsulta cada
minuto; iOS puede suspenderla en segundo plano. La lectura automática usa Wi-Fi;
el pedido manual permite la ventana de red móvil ya existente.

El cliente valida dispositivo/carpeta, propiedad privada, ID, hash, tamaño,
checksum y fecha. Un ID con otro SHA no cuenta como transcrito. El reporte abarca
hasta los 500 recibos más recientes de esa carpeta; lo no incluido queda sin
confirmar. Un error ASR queda como error; un descargado sin completar queda
pendiente. Subida confirmada y transcripción son etapas diferentes.

Al perder red, desvincular/cambiar cuenta o recibir una respuesta ausente,
vencida, duplicada o inválida, se limpia el éxito anterior. **Sin confirmar** no
significa perdido ni pendiente: significa que el teléfono no tiene evidencia
vigente de la Mac. No se fabrica un tema o una cita a partir del reporte.

Los clientes OAuth Desktop/iOS deben pertenecer a la app Google que puede acceder
a esos archivos. `drive.file` sólo permite archivos accesibles a esa app; si el
reporte no aparece, revisar proyecto/cuenta con su titular. No se eleva el scope
del iPhone ni se solicitan credenciales en el chat.

## Verificación y límites

El fixture [report.json](../tests/fixtures/worker-feedback/report.json) se compara
con `feedback.snapshot` en Python y se consume mediante el cliente Drive real
con transporte ficticio en Swift. Hay regresiones de archivo ajeno, duplicado,
caducidad, falta de ASR, hash, reintento y opt-in. Eso verifica el contrato y el
recorrido de código, sin enviar datos a una cuenta real.

La firma/TestFlight y la prueba con iPhone real conservan su gate independiente.
No se ha activado el retorno en la Mac privada ni modificado su scheduler por
publicar el código. La IA de temas/citas no está incluida en esta función.

Referencias: [scope de archivos](https://developers.google.com/workspace/drive/api/guides/api-specific-auth),
[actualización de media](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/update).
