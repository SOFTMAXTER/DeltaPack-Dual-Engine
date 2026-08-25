# DeltaPack Dual-Engine V1.1.0 by SOFTMAXTER

<p align="center">
  <img width="230" height="250" alt="DeltaPack Dual-Engine Logo" src="https://github.com/user-attachments/assets/eca22113-b9a7-41e3-a071-478737909fa9" />
</p>

**DeltaPack Dual-Engine** es una suite de ingeniería inversa automatizada, diseñada para empaquetar aplicaciones en entornos Windows. Utilizando una metodología de captura diferencial (Snapshot), aísla el software de su instalador original y genera contenedores portables altamente optimizados para su inyección en imágenes offline.

## Filosofía de la Herramienta: "Cero Ruido"

Los sistemas operativos modernos (Windows 10 22H2 y Windows 11 24H2+) generan "ruido blanco" en segundo plano durante cualquier instalación: Windows Update, telemetría, sincronización de nube, cachés de aplicaciones modernas, servicios por usuario, componentes del sistema y eventos transitorios.

DeltaPack actúa como un **filtro purificador de grado forense**. Su matriz de exclusiones separa el movimiento natural del sistema de los cambios reales de la aplicación objetivo, ayudando a que el paquete final contenga únicamente los binarios, accesos directos y entradas de registro necesarias para el despliegue.

## Características Principales

* **Captura Diferencial Completa:** Compara el estado inicial y final del sistema (archivos, registro y eliminaciones) para aislar únicamente lo que el instalador cambió.
* **Matriz "Cero Ruido" Externalizada:** `DeltaPack.Exclusions.json` centraliza las exclusiones de archivos, registro y ruido típico de Windows 10/11.
* **Soporte WIM Estándar:** Genera `.wim` compatibles con DISM, con compresión máxima y progreso supervisado (tiempo/tamaño en vez de una barra congelada en 0%).
* **Registro y Perfil Portables:** Exporta un `.reg` saneado, redirige rutas atadas al usuario de captura a `Users\Default` y reemplaza la ACL ligada a su SID.
* **Resiliencia ante Reinicios:** Auto-reanudación endurecida vía `RunOnce`, con verificación exacta de identidad (PS1, motor C#, exclusiones y snapshot) antes de continuar.
* **Identidad Canónica e Integridad SHA256:** Nombre, arquitectura y tipo generan una identidad inmutable; el motor y todos los artefactos se re-verifican en cada etapa y ante cualquier discrepancia se bloquea la publicación.
* **Reparse Points Reproducibles:** Lee y recrea junctions/symlinks vía `FSCTL_GET/SET_REPARSE_POINT`, verificando su huella antes del WIM.
* **Tombstones y Acciones Offline:** `Deletions_*.json` y `Actions_*.json` (JSON transaccional y validado) documentan eliminaciones y pasos especializados (drivers, catálogos, tareas) para el inyector.
* **Auditoría Automática:** Reporte Markdown, `manifest_*.json` estructurado y checksums SHA256 por capas (payload y artefactos), incluso en Dry Run.
* **Bloqueos Fail-Closed:** Protege ante mantenimiento del sistema base, migraciones masivas de Edge/WebView2 y brechas de registro no estables; nunca empaqueta un delta contaminado.
* **Modo Dry Run:** Calcula y audita cambios sin copiar archivos ni generar `.wim`.
* **Verificaciones de Entorno:** Valida PowerShell 5.1+, elevación, `dism.exe`, privilegios de captura, espacio en disco y arquitectura (`x64`/`x86`/`arm64`) antes de empezar.
## Modo de Uso y Estructura

1. Descarga el archivo `.zip` y extráelo en una ruta corta, por ejemplo `C:\DeltaPackDual`.
2. Mantén la estructura de directorios completa. No muevas ni renombres los archivos internos de la suite:

   ```text
   TuCarpetaPrincipal/
   │   DeltaPackDual-Engine.exe
   │   README.md
   │   LICENSE
   ├───Script/
       │   DeltaPackDual-Engine.ps1
       │   DiffEngine.cs
       │   DeltaPack.Exclusions.json
   ```

3. Haz doble clic en **`DeltaPackDual-Engine.exe`**. El lanzador solicitará permisos de Administrador y preparará el entorno de ejecución de manera automática.

## Recomendación de Entorno (Clean Room)

Para garantizar que los paquetes generados sean universales y no contengan dependencias cruzadas, es estrictamente recomendado crear un entorno **Clean Room**.

Se debe utilizar una instalación base de Windows 10 22H2 o superior, preferentemente sin conexión a internet durante la captura, con las librerías necesarias ya instaladas previamente (Visual C++ Redistributables, .NET Framework, runtimes requeridos, etc.). Lo ideal es trabajar en una máquina virtual con soporte para Snapshots, de modo que puedas revertir la máquina a su estado original después de empaquetar cada aplicación.

Desactiva Windows Update y Windows Defender (o excluye la ruta de trabajo en Defender) antes de iniciar la captura. Ambos pueden tocar rutas protegidas (`CatRoot`, firma de drivers) o poner en cuarentena archivos del instalador durante la ventana de captura, disparando el bloqueo fail-closed o contaminando el delta con ruido no atribuible a la aplicación.

Usa la misma cuenta local con privilegios de Administrador antes y después de un reinicio. La reanudación automática (`HKCU\RunOnce`) solo funciona si vuelve a iniciar sesión el mismo usuario. Si otra persona inicia sesión con una cuenta de administrador distinta para continuar, la captura se reanudará en el perfil de esa otra cuenta, no en el original.

### Ajustes para Instaladores Complejos

`Script\DeltaPack.Exclusions.json` contiene un bloque opcional `captureSettings`:

* `additionalFileRoots`: agrega rutas absolutas que el instalador usa fuera del alcance estándar, por ejemplo `%SystemDrive%\Autodesk` o `D:\Aplicaciones`.
* `additionalRegistryTargets`: agrega objetivos `HKLM`/`HKCU` mediante objetos `{ "hive": "HKLM", "path": "...", "label": "..." }`.
* `allowManagedRuntimeUpdates`: actívalo únicamente cuando el instalador deba incluir intencionalmente Edge/WebView2. Por defecto una migración masiva sigue siendo bloqueante.
* `allowAuditOnlyDeletions`: por defecto es `false`. Solo debe activarse cuando se acepta deliberadamente que el inyector no aplique las entradas accionables de `Deletions_*.json`. La evidencia `filesystemAuditOnly` y `registryAuditOnly` nunca requiere activar esta opción.
* `includeBundledOneDrive`: por defecto es `false`; separa OneDrive cuando Office u otro instalador lo actualiza incidentalmente. Actívalo únicamente si OneDrive forma parte intencional del paquete.
* `actionAwareInjector`: por defecto es `false`. Actívalo únicamente cuando el inyector pueda consumir `Actions_*.json` schema 2; de lo contrario el WIM puede generarse, pero `packageReady` permanece en `false` si hay catálogos/controladores especializados.
* `fileScanMaxAttempts`: número de intentos de lectura directa antes del rescate; el valor predeterminado es `3`.
* `fileScanRetryDelayMs`: espera incremental entre intentos; el valor predeterminado es `200` ms.
* `useVssScanFallback`: por defecto es `true`. Permite verificar desde VSS cualquier archivo del volumen del sistema que siga inestable después de los reintentos.

---

## Guía de Uso: Creación del Paquete (Packager)

El proceso de creación está diseñado como un asistente interactivo y seguro:

1. Ejecuta el lanzador **`DeltaPackDual-Engine.exe`**. El sistema validará la elevación y los privilegios de backup, restauración y creación de enlaces antes de preparar una Captura Completa. Si el token no los contiene, se detiene antes del snapshot o del Staging.
2. Ingresa el nombre base del paquete, por ejemplo: `WinRAR`, `Office_24`, `MiApp`.
3. Selecciona la categoría:
   * **Paquete Principal:** usa el sufijo `_main`.
   * **Complemento / Idioma / Update:** permite definir un sufijo personalizado.
4. Selecciona el modo de ejecución:
   * **Captura Completa:** genera `.wim`, `.reg`, reporte, manifest y checksums.
   * **Dry Run / Vista Previa:** solo calcula y reporta los cambios detectados; no copia archivos ni genera `.wim`. Si la cobertura es íntegra, finaliza como vista previa completada aunque `packageReady` permanezca en `false` por diseño.
5. **Fase 1 (Mapeo Base):** DeltaPack tomará una fotografía inicial del sistema. Si alguna ruta continúa ilegible después de reintentos y VSS, se detendrá aquí y conservará el log; no instales la aplicación hasta reparar o restaurar la base.
6. **Pausa de Instalación:** instala tu software, inícialo, aplica licencias y configuraciones. **Cierra el programa por completo** al terminar.
7. Si el instalador pide reiniciar, reinicia con tranquilidad. DeltaPack podrá continuar la captura al volver a Windows.
8. **Fase Final:** presiona Enter en la consola. DeltaPack calculará los cambios, aplicará exclusiones, rescatará archivos necesarios, redirigirá perfiles de usuario y generará los artefactos finales.

### Estructura de Salida

En tu escritorio se creará automáticamente la carpeta `DeltaPack_[Nombre_Del_Paquete]`. Si ya existe, se conservará y la nueva salida recibirá una marca de tiempo.

* `[Nombre].wim` — contenedor con los binarios purificados. No se genera en Dry Run.
* `[Nombre].reg` — registro saneado con redirecciones universales.
* `Deletions_[Nombre].json` — schema 2 con tombstones accionables y evidencia no destructiva. `filesystemAuditOnlyEntryCount`, `registryAuditOnlyEntryCount`, `actionableEntryCount` y `applyPolicy` distinguen cada caso.
* `Actions_[Nombre].json` — acciones y validaciones offline para controladores, catálogos, tareas y reparse points; aparece cuando hay evidencia aplicable.
* `README_[Nombre].md` — reporte forense, estadístico y manifiesto de archivos.
* `manifest_[Nombre].json` — manifiesto estructurado de la captura.
* `Checksums_[Nombre].sha256` — manifiesto de integridad del payload copiado al WIM. No se genera en Dry Run porque no existe Staging de archivos.
* `Artifacts_[Nombre].sha256` — índice de integridad de los artefactos generados (`REG`, `Actions`, reporte y manifest; también WIM/checksums cuando existen). Se genera también en Dry Run, pero nunca si falta un JSON obligatorio o alguno no supera la validación.
* `Install_Log.txt` — traza completa del proceso con niveles de severidad.
* `dism.log` — log de captura WIM cuando aplica.

### Qué incluye el reporte generado

El reporte `README_[Nombre].md` incluye:

* resumen estadístico del paquete;
* archivos nuevos y modificados;
* carpetas nuevas detectadas;
* claves y valores de registro exportados;
* archivos o carpetas eliminados por el instalador;
* métricas internas de escaneo;
* diagnóstico automático del estado de la captura;
* estado de integridad del sistema base (bloqueo fail-closed si hubo mantenimiento de Windows durante la captura);
* manifiesto completo de archivos incluidos o detectados en Dry Run;
* notas técnicas de inyección.

### Notas importantes de empaquetado

* El orden es: despliega `.wim`, ejecuta `Actions_*.json` en fase `afterWimBeforeRegistry`, aplica únicamente las entradas accionables de `Deletions_*.json`, importa `.reg` y ejecuta las validaciones `afterRegistry`. `filesystemAuditOnly` y `registryAuditOnly` no se ejecutan.
* Los elementos eliminados no caben dentro de un WIM aditivo. El paquete no se marca listo si el inyector debe aplicarlos y no se autorizó el modo de auditoría.
* Si el diagnóstico marca advertencias, revisa el `manifest_[Nombre].json` y `Install_Log.txt` antes de usar el paquete como base final.
* Si trabajas en Dry Run, vuelve a ejecutar en Captura Completa para generar el `.wim`.
* En el manifest, usa `scanCoverageComplete`, `staging.status`, `stagingComplete`, `captureIntegrityStatus`, `wimCreated` y `packageReady` como estados distintos. En Dry Run, Staging e integridad de captura figuran como `notApplicable` y nunca se presentan como completados.

## Seguridad y Límites Conocidos

* Ejecuta DeltaPack únicamente en una VM limpia y desconectada de internet durante la captura. El proceso requiere elevación y observa áreas sensibles del sistema.
* El launcher incluido no tiene firma Authenticode. Descárgalo únicamente de una fuente confiable antes de elevarlo y no reemplaces archivos dentro de `Script\`.
* `HKCR` no se captura como vista combinada: las clases globales y por usuario se registran por separado desde `HKLM\SOFTWARE\Classes` y `HKCU\Software\Classes`.
* `-ExecutionPolicy Bypass` no valida la integridad del script; por eso una distribución controlada del `.zip` sigue siendo necesaria.
* El motor no realiza conexiones de red ni descarga componentes. Los enlaces del README son solo documentación.
* Se conservan contenido, timestamps, atributos y ACL cuando Windows lo permite. No se garantiza la reproducción de Alternate Data Streams, EFS, enlaces físicos ni todos los metadatos especiales de NTFS.
* El rescate VSS opera sobre el volumen del sistema. Un archivo bloqueado dentro de una raíz adicional ubicada en otro volumen detendrá la captura para no producir un paquete incompleto.
* Los reparse points fuera del perfil capturador se reproducen desde su descriptor NTFS. Los ubicados dentro del perfil no se trasladan automáticamente a `Users\Default`, porque hacerlo podría cambiar el destino o la seguridad del enlace.
* Las ACL y timestamps del objeto enlace se heredan de Staging para evitar que las APIs de alto nivel sigan el destino; el descriptor, tag y buffer NTFS sí se conservan y verifican exactamente.
* Las rutas almacenadas dentro de valores binarios de Registro no pueden sanearse de forma universal.
* Las rutas absolutas usadas como nombres de valores de Registro no admiten variables de entorno. El manifest registra `requiresSameSystemDrive=true` cuando el destino debe conservar la misma letra de sistema.
* No captures activaciones, tokens, certificados privados ni secretos ligados a la VM. El licenciamiento debe ejecutarse en el equipo destino según el contrato del fabricante.
* El workspace vigente está en `%ProgramData%\DeltaPack\Captures`. Cada captura guarda SHA256 separados del PS1, motor C# y exclusiones. La reanudación exige coincidencia exacta de esos componentes y del formato binario; si alguno cambia, la captura guardada se rechaza y debe iniciarse otra desde cero.

---

## Guía de Uso: Inyección en Imágenes Windows (Despliegue)

Los paquetes generados por **DeltaPack Dual-Engine** están diseñados para integrarse de forma nativa con **[AdminImagenOffline](https://github.com/SOFTMAXTER/AdminImagenOffline)**.

**Requisito Previo Importante:** Antes de proceder, asegúrate de que la imagen de Windows de destino ya tenga incluidas todas las librerías necesarias de las que dependa tu aplicación.

A continuación, se detallan los pasos exactos para inyectar permanentemente tu aplicación (WIM + REG) dentro de un archivo `install.wim` o un disco virtual de despliegue (`.vhdx`):

### Pasos exactos para la integración:

1. **Preparación:** Ejecuta `AdminImagenOffline` con privilegios de Administrador.
2. **Montaje de Imagen:**
   * En el Menú Principal, selecciona **[1] Montar / Desmontar / Guardar Imagen**.
   * Selecciona **[1] Montar Imagen** y busca tu archivo base, por ejemplo `install.wim` o `.vhdx`.
   * Selecciona el índice de la edición de Windows deseada y espera a que finalice el montaje.
   * Regresa al Menú Principal pulsando **[V]**.
3. **Acceso al Inyector:**
   * En **INGENIERÍA & AJUSTES**, selecciona **[5] Personalización (Apps, Tweaks, Unattend.xml)**.
   * Dentro del menú de personalización, elige **[7] Inyector de Addons (.wim, .tpk, .bpk, .reg)**.
4. **Carga de Archivos:**
   * Haz clic en **"+ Agregar Addons..."**.
   * Selecciona ambos archivos generados por DeltaPack: `tu_app.wim` y `tu_app.reg`.
   * Si existe `Actions_tu_app.json`, confirma soporte del schema 2 y respeta sus fases. Si `Deletions_tu_app.json` schema 2 declara `requiresDeletionAwareInjector=true`, confirma que el inyector pueda aplicar sus `entries`. `filesystemAuditOnly` y `registryAuditOnly` son evidencia y no se ejecutan.
5. **Filtro de Arquitectura:** Selecciona la arquitectura de destino de tu imagen (`x86`, `x64` o `arm64`, según corresponda).
6. **Ejecución:** Haz clic en **"INYECTAR TODOS LOS ADDONS"**. El orden requerido es WIM, acciones previas, tombstones, REG y validaciones posteriores.
7. **Guardado (Commit):**
   * Cierra el módulo gráfico y regresa al Menú de Gestión de Imagen.
   * Selecciona **[3] Guardar y Desmontar Imagen (Commit)** para sellar permanentemente la aplicación dentro de la imagen maestra de Windows.

---

## Apoya el Proyecto

DeltaPack Dual-Engine es una herramienta de grado empresarial desarrollada y mantenida para facilitar la ingeniería de sistemas. Si esta suite te ha ahorrado horas de trabajo empaquetando software atípico o ha mejorado tus despliegues corporativos, considera apoyar su desarrollo para garantizar actualizaciones continuas frente a las nuevas iteraciones de Windows.

* [💳 Donar vía PayPal](https://www.paypal.com/donate/?hosted_button_id=U65G2GXDTUGML)

## Autor y Colaboradores

* **Autor Principal:** SOFTMAXTER
* **Análisis y refinamiento de código:** Realizado en colaboración con inteligencia artificial para garantizar máxima calidad y optimización de algoritmos.

## Aviso Legal y Uso Aceptable (Disclaimer)

**DeltaPack Dual-Engine** es una herramienta de administración, auditoría y empaquetado, diseñada estrictamente para fines corporativos legítimos y despliegue automatizado.

* **Neutralidad:** Este software actúa como un clonador neutral del estado del sistema de archivos. No elude, promueve ni facilita la rotura de mecanismos DRM ni el pirateo de software.
* **Responsabilidad Compartida:** Al emplear DeltaPack, el usuario asume la obligación de garantizar que posee las licencias corporativas adecuadas para empaquetar, modificar y redistribuir el software capturado, cumpliendo con los EULA vigentes.
* **Exención:** El desarrollador (SOFTMAXTER) declina cualquier responsabilidad derivada del uso indebido de la herramienta, de infracciones de propiedad intelectual, o de corrupciones del sistema causadas por inyecciones defectuosas o bloqueos de antivirus en entornos hostiles.

### Cómo Contribuir

Si tienes ideas o mejoras para este proyecto:

1. Haz un Fork del repositorio principal.
2. Crea una nueva rama (`git checkout -b feature/nueva-funcionalidad`).
3. Aplica y documenta tus cambios asegurando la compatibilidad con el entorno general.
4. Realiza un Push hacia tu rama (`git push origin feature/nueva-funcionalidad`).
5. Abre un Pull Request en el repositorio.

---

## Licencia y Modelo de Negocio (Dual Licensing)

Este proyecto está protegido bajo derechos de autor y utiliza un modelo de **Doble Licencia (Dual Licensing)**:

### 1. Licencia Comunitaria (Open Source)

Distribuido bajo la **Licencia GNU GPLv3**. Eres libre de usar, modificar y compartir este software. Bajo esta licencia (*Copyleft*), cualquier herramienta derivada o script que integre código de DeltaPack **debe ser de código abierto** bajo la misma licencia.

### 2. Licencia Comercial Corporativa

Si deseas integrar el motor de DeltaPack en un producto comercial propietario (closed-source), o requieres Acuerdos de Nivel de Servicio (SLA) para tu corporación, **debes adquirir una Licencia Comercial**.

Para mayor información o consultas de licenciamiento empresarial, contactar mediante correo electrónico a: `softmaxter@hotmail.com`
