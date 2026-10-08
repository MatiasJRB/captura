# Captura en el iPhone: guía rápida

Este es el resumen en español de la [guía completa](ios.md) (en inglés). Los pasos tienen
los mismos números. Cada uno de la guía completa dice qué deberías ver y qué hacer si no
lo ves: andá ahí cuando algo no coincida. Los comandos se escriben tal cual, en Terminal,
y se termina cada uno con Return. Xcode está solo en inglés; el iPhone, en español.

Si te ayuda un agente de código (Claude Code, Codex), pedile que siga
[`.claude/skills/captura-setup/SKILL.md`](../.claude/skills/captura-setup/SKILL.md).

## Qué necesitás

- Una Mac con Apple silicon (M1 o posterior) y macOS 26.6 o posterior. Para verlo:
  menú Apple > Acerca de esta Mac.
- Un iPhone con iOS 18 o posterior y un cable para conectarlo a la Mac.
- Una cuenta de Apple gratis (la del App Store sirve).
- El **ID de cliente de iOS** que te da quien administra el proyecto de Google Cloud.
  Para crearlo necesita tu bundle ID (paso 4.1).
- Varios GB libres en disco.

Con una cuenta de Apple gratis, la app deja de abrir a los **7 días** y hay que volver a
instalarla desde la Mac. Tus grabaciones no se pierden.

## 1. Instalar Xcode 27

1. En la Mac, abrí el **App Store**, buscá **Xcode** y tocá **Obtener**.
2. Abrí Xcode, aceptá la licencia y, cuando pregunte por plataformas, tildá **iOS**.
3. En Xcode, andá a **Xcode > Settings > Apple Accounts**, tocá **+** e iniciá sesión con
   tu cuenta de Apple. Vas a ver "Tu Nombre (Personal Team)".

## 2. Abrir Terminal

Está en Aplicaciones > Utilidades > Terminal, o buscala con Spotlight (⌘ Espacio).

## 3. Descargar Captura

```sh
cd ~
git clone https://github.com/MatiasJRB/captura.git
cd captura
ls ios/scripts
```

- Deberías ver `check.py` y `configure.py`.
- Si dice `destination path 'captura' already exists`, ya lo habías descargado.
  Actualizalo con `git -C ~/captura pull`, después `cd ~/captura` y `ls ios/scripts`.
- Si dice `No such file or directory`, avisale a quien te mandó esta guía y pará acá.

## 4. Guardar tu configuración

1. Elegí tu **bundle ID**: `com.` + tu nombre + `.captura`, todo en minúsculas, sin
   espacios ni tildes. Revisalo con este comando, poniendo tu nombre en lugar de
   `yourname`:

   ```sh
   python3 ios/scripts/configure.py --bundle-id com.yourname.captura
   ```

   Mandale al administrador de Google exactamente el valor que aparece después de
   `Send the Google admin exactly this value:`. Te va a devolver el ID de cliente de iOS.
2. Con ese ID, guardá la configuración. Usá el mismo bundle ID y poné el ID de cliente
   en lugar de `PASTE-THE-IOS-CLIENT-ID`:

   ```sh
   python3 ios/scripts/configure.py --bundle-id com.yourname.captura --google-client-id PASTE-THE-IOS-CLIENT-ID
   ```

   Si tu cuenta de Google es de una empresa (Google Workspace), agregá al final
   `--hosted-domain` y tu dominio (lo que va después de la @ en tu correo de trabajo).

   **Desde un gestor de contraseñas (lo recomendado si el administrador te compartió un
   ítem).** Si el ID de cliente está en un ítem de 1Password, con el campo
   `ios_client_id` (y, si quiere, `bundle_id` y `hosted_domain`), leelo desde ahí en
   lugar de pegarlo. Poné la bóveda y el nombre del ítem en lugar del ejemplo:

   ```sh
   python3 ios/scripts/configure.py --bundle-id com.yourname.captura --from "op://Captura/Captura iOS"
   ```

   Si el ítem tiene `bundle_id`, sacá `--bundle-id`. Hace falta el CLI de 1Password con
   1Password > Settings > Developer > **Integrate with 1Password CLI** activado. Si los
   campos tienen otros nombres, usá `--field-map` (detalles en la guía completa).

- Si dice `Not changed:`, quedó un valor de ejemplo o hay un error (mayúsculas, tildes,
  espacios). El mensaje dice cuál: corregilo y volvé a correr el comando.
- Si dice `No Apple team found in Xcode yet`, revisá el paso 1.3 y corré
  `python3 ios/scripts/configure.py` otra vez. Si sigue igual, seguí con el paso 5.

## 5. Revisar la Mac

```sh
python3 ios/scripts/check.py
```

Al final debería decir `Ready.`. Si una línea dice `FAIL`, hacé lo que dice su línea
`Next:` y volvé a correr el comando. Si la única falla es `Apple team`, seguí con el paso 6.

## 6. Abrir el proyecto y revisar la firma

```sh
open ios/Captura.xcodeproj
```

- Si Xcode ofrece **Update to recommended settings** o actualizar el proyecto, tocá
  **Not Now** o **Cancel**. Nunca **Perform Changes**.
- Tocá el ícono azul **Captura** arriba a la izquierda, después el target **Captura** y la
  pestaña **Signing & Capabilities**. **Team** tiene que decir "(Personal Team)" y
  **Bundle Identifier**, tu bundle ID.
- Si Bundle Identifier dice `org.example.captura`, cerrá Xcode y repetí los pasos 4 y 5.
- Si Team dice **None**, elegí tu "(Personal Team)", cerrá Xcode (Xcode > Quit Xcode) y
  corré `python3 ios/scripts/configure.py --adopt-xcode-team`.

## 7. Conectar el iPhone

1. Conectá el iPhone con el cable y desbloquealo. Cuando pregunte **¿Confiar en esta
   computadora?**, tocá **Confiar** y poné el código del iPhone.
2. En Xcode, elegí tu iPhone en el menú de dispositivos de arriba.
3. En el iPhone: **Configuración > Privacidad y seguridad > Modo de desarrollador**,
   activalo y reiniciá. Si no aparece, repetí 7.1 y 7.2.
4. Corré `python3 ios/scripts/check.py` otra vez: tiene que aparecer tu iPhone.

## 8. Instalar la app

En Xcode, tocá **Run** (▶) o ⌘R. Si macOS pide permiso para `codesign`, poné la contraseña
de la Mac y tocá **Permitir siempre** (Always Allow).

## 9. Confiar en vos como desarrollador

En el iPhone: **Configuración > General > Admón. de dispositivos y VPN**, tocá tu cuenta
de Apple y después **Confiar**. Abrí Captura.

## 10. Primer uso

1. Tocá **Grabar** y **Permitir** el micrófono. Permití también las notificaciones.
   Avisá a las personas antes de grabarlas.
2. Tocá **Vincular Google Drive** y elegí tu cuenta de Google.
3. Activá **Sincronizar automáticamente por Wi-Fi**.
4. Tocá **Copiar ID de carpeta**: lo vas a usar en la Mac.
5. Seguí con el [worker en la Mac](worker.md) (en inglés), que descarga y transcribe.
   En su paso 3, `python3 bin/capture drive-setup --from "op://Captura/Captura worker OAuth"`
   (con la bóveda y el ítem que te compartió el administrador) lee el ID y el secreto del
   cliente de escritorio sin mostrarlos. Sin ítem, el mismo comando sin `--from` te los
   pide y el secreto no se ve al pegarlo.

**Dónde leer las transcripciones.** La Mac transcribe; la app del iPhone no muestra
texto. En la Mac las ves con `capture list` o `capture view` (paso 8 del worker). Para
leerlas en el teléfono, activá la publicación en la Mac (paso 9 del worker,
`python3 bin/capture set --publish on`): cada transcripción aparece también como un
documento de Google en la carpeta **Captura · transcripciones** de tu Drive, que abrís
con la app de Google Drive o Documentos. Viene apagada.

## Cada 7 días

1. En Captura, tocá **Detener** si está grabando.
2. Conectá el iPhone, corré `open ~/captura/ios/Captura.xcodeproj`, elegí el iPhone y
   tocá **Run**.

**Nunca borres la app** si tiene grabaciones pendientes de subir: se borran con ella.

## Si algo falla

Buscá el mensaje exacto en la tabla de [problemas frecuentes](ios.md#troubleshooting).
