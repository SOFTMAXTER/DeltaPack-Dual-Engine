# DeltaPack Dual-Engine V1.0.0 by SOFTMAXTER

<p align="center">
  <img width="350" height="350" alt="DeltaPack Dual-Engine Logo" src="https://github.com/user-attachments/assets/eca22113-b9a7-41e3-a071-478737909fa9" />
</p>

**DeltaPack Dual-Engine** es una suite avanzada de ingeniería inversa automatizada, diseñada para empaquetar aplicaciones en entornos Windows. Utilizando una metodología de captura diferencial (Snapshot), aísla el software de su instalador original y genera contenedores portables altamente optimizados para su inyección en imágenes offline.

## Filosofía de la Herramienta: "Cero Ruido"

Los sistemas operativos modernos (Windows 10 22H2 y Windows 11 24H2+) generan "ruido blanco" en segundo plano durante cualquier instalación: Windows Update, telemetría, sincronización de nube, cachés de aplicaciones modernas, servicios por usuario, componentes del sistema y eventos transitorios.

DeltaPack actúa como un **filtro purificador de grado forense**. Su matriz de exclusiones separa el movimiento natural del sistema de los cambios reales de la aplicación objetivo, ayudando a que el paquete final contenga únicamente los binarios, accesos directos y entradas de registro necesarias para el despliegue.

## Características Principales

* **Captura Diferencial Completa:** Compara el estado inicial y final del sistema para detectar archivos nuevos, archivos modificados, claves de registro nuevas o modificadas y elementos eliminados por el instalador.
* **Matriz "Cero Ruido" Externalizada:** Usa `DeltaPack.Exclusions.json` como fuente central de exclusiones de archivos y registro, incluyendo ruido típico de Windows 10/11, telemetría, cachés, servicios por usuario, actualizaciones, componentes modernos y ruido post-instalación.
* **Soporte WIM Estándar:** Generación de contenedores `.wim` compatibles con DISM y flujos de despliegue offline, con compresión máxima y uso de espacio temporal aislado.
* **Saneamiento de Perfil (Portabilidad Absoluta):** Detecta rutas atadas al usuario de captura y las redirige a `Users\Default`, asegurando que el despliegue sea universal sin importar la cuenta de destino.
* **Registro Portable:** Genera un `.reg` saneado, listo para importarse después de desplegar el `.wim`, preservando valores relevantes y documentando eliminaciones cuando corresponda.
* **Cobertura Avanzada de Registro:** Captura áreas críticas de software, servicios, COM y asociaciones del sistema, necesarias para muchas aplicaciones de escritorio.
* **Soporte Completo de Tipos de Datos de Registro:** Exporta correctamente valores `DWORD`, `QWORD`, `SZ`, `ExpandString`, `Binary` y `MultiString`, evitando corrupciones al importar el `.reg` resultante.
* **Resiliencia ante Reinicios (Auto-Reanudación):** Si el instalador requiere reiniciar el equipo, DeltaPack guarda el estado base y permite continuar la captura al volver a Windows.
* **Soporte VSS Integrado:** Puede rescatar archivos bloqueados o en uso durante la captura mediante instantáneas de volumen, limpiando la instantánea al finalizar.
* **Modo Dry Run / Vista Previa:** Permite calcular y auditar los cambios detectados sin copiar archivos ni crear el `.wim`, ideal para validar ruido antes de generar el paquete final.
* **Auditoría Automática:** Genera un reporte Markdown con resumen estadístico, manifiesto de archivos, métricas de escaneo, diagnóstico automático, archivos eliminados y notas técnicas de despliegue.
* **Manifest JSON:** Crea un `manifest_[Nombre].json` con información estructurada del paquete, métricas, salidas generadas, diagnóstico del escaneo y banderas de ejecución.
* **Integridad SHA256:** Genera un manifiesto de checksums para verificar los archivos extraídos del paquete.
* **Diagnóstico de Escaneo:** Reporta estado del escaneo, cobertura de verificación, omisiones por exclusión, acceso denegado, reparse points, errores I/O y tiempo total de análisis.
* **Adaptabilidad de Arquitectura:** Detecta automáticamente la arquitectura del sistema (`x64`, `x86` o `arm64`) y la incorpora al nombre final del paquete.
* **Validaciones de Entrada:** Rechaza caracteres no válidos en el nombre del paquete y en el sufijo antes de iniciar la captura.
* **Verificaciones Previas del Entorno:** Antes de ejecutarse, valida PowerShell 5.1+, privilegios de Administrador y disponibilidad de `dism.exe`.
* **Soporte de Rutas Largas:** Habilita la compatibilidad con rutas largas de Windows para reducir fallos de indexación y empaquetado.
* **Control de Espacio:** Antes de crear el `.wim`, valida espacio disponible para el destino y el directorio temporal de trabajo.

## Modo de Uso y Estructura

1. Descarga el repositorio como un archivo `.zip` y extráelo en una ruta corta, por ejemplo: `C:\DeltaPackDual`.
2. Mantén la estructura de directorios completa. No muevas ni renombres los archivos internos de la suite:

   ```text
   TuCarpetaPrincipal/
   │   DeltaPackDual-Engine.exe
   ├───Script/
       │   DeltaPackDual-Engine.ps1
       │   DiffEngine.cs
       │   DeltaPack.Exclusions.json
   ```

3. Haz doble clic en **`DeltaPackDual-Engine.exe`**. El lanzador solicitará permisos de Administrador y preparará el entorno de ejecución de manera automática.

## Recomendación de Entorno (Clean Room)

Para garantizar que los paquetes generados sean universales y no contengan dependencias cruzadas, es estrictamente recomendado crear un entorno **Clean Room**.

Se debe utilizar una instalación base de Windows 10 22H2 o superior, preferentemente sin conexión a internet durante la captura, con las librerías necesarias ya instaladas previamente (Visual C++ Redistributables, .NET Framework, runtimes requeridos, etc.). Lo ideal es trabajar en una máquina virtual con soporte para Snapshots, de modo que puedas revertir la máquina a su estado original después de empaquetar cada aplicación.

---

## Guía de Uso: Creación del Paquete (Packager)

El proceso de creación está diseñado como un asistente interactivo y seguro:

1. Ejecuta el lanzador **`DeltaPackDual-Engine.exe`**. El sistema validará automáticamente privilegios de Administrador y preparará el entorno.
2. Ingresa el nombre base del paquete, por ejemplo: `WinRAR`, `Office_24`, `MiApp`.
3. Selecciona la categoría:
   * **Paquete Principal:** usa el sufijo `_main`.
   * **Complemento / Idioma / Update:** permite definir un sufijo personalizado.
4. Selecciona el modo de ejecución:
   * **Captura Completa:** genera `.wim`, `.reg`, reporte, manifest y checksums.
   * **Dry Run / Vista Previa:** solo calcula y reporta los cambios detectados; no copia archivos ni genera `.wim`.
5. **Fase 1 (Mapeo Base):** DeltaPack tomará una fotografía inicial del sistema.
6. **Pausa de Instalación:** instala tu software, inícialo, aplica licencias y configuraciones. **Cierra el programa por completo** al terminar.
7. Si el instalador pide reiniciar, reinicia con tranquilidad. DeltaPack podrá continuar la captura al volver a Windows.
8. **Fase Final:** presiona Enter en la consola. DeltaPack calculará los cambios, aplicará exclusiones, rescatará archivos necesarios, redirigirá perfiles de usuario y generará los artefactos finales.

### Estructura de Salida

En tu escritorio se creará automáticamente la carpeta `DeltaPack_[Nombre_Del_Paquete]` conteniendo:

* `[Nombre].wim` — contenedor con los binarios purificados. No se genera en Dry Run.
* `[Nombre].reg` — registro saneado con redirecciones universales.
* `README_[Nombre].md` — reporte forense, estadístico y manifiesto de archivos.
* `manifest_[Nombre].json` — manifiesto estructurado de la captura.
* `Checksums_[Nombre].sha256` — manifiesto de integridad de archivos. No se genera en Dry Run.
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
* manifiesto completo de archivos incluidos o detectados en Dry Run;
* notas técnicas de inyección.

### Notas importantes de empaquetado

* Inyecta primero el `.wim` y después importa el `.reg`.
* Los elementos eliminados por el instalador se documentan, pero no se incluyen en el `.wim`.
* Si el diagnóstico marca advertencias, revisa el `manifest_[Nombre].json` y `Install_Log.txt` antes de usar el paquete como base final.
* Si trabajas en Dry Run, vuelve a ejecutar en Captura Completa para generar el `.wim`.

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
5. **Filtro de Arquitectura:** Selecciona la arquitectura de destino de tu imagen (`x86`, `x64` o `arm64`, según corresponda).
6. **Ejecución:** Haz clic en **"INYECTAR TODOS LOS ADDONS"**. Primero se desplegarán los binarios y después se fusionará el registro.
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
