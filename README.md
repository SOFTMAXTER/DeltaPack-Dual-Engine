# DeltaPack Dual-Engine V1.0.0 by SOFTMAXTER

<p align="center">
  <img width="350" height="350" alt="DeltaPack Dual-Engine Logo" src="https://github.com/user-attachments/assets/eca22113-b9a7-41e3-a071-478737909fa9" />
</p>

**DeltaPack Dual-Engine** es una suite avanzada de ingeniería inversa automatizada, diseñada para empaquetar aplicaciones en entornos Windows. Utilizando una metodología de captura diferencial (Snapshot) aísla el software de su instalador original y genera contenedores portables altamente optimizados para su inyección en imágenes offline.

## Filosofía de la Herramienta: "Cero Ruido"

Los sistemas operativos modernos (Windows 10 22H2 y Windows 11 24H2+) generan gigabytes de "ruido blanco" en segundo plano durante cualquier instalación: descargas de Windows Update, telemetría masiva, sincronización de la nube y cachés de IA. 

DeltaPack actúa como un **filtro purificador de grado forense**. Su motor ignora quirúrgicamente esta respiración de fondo del sistema, asegurando que el paquete final contenga *exclusivamente* los binarios y registros de la aplicación objetivo, bloqueando extensiones ruidosas, volcados de memoria y archivos transaccionales.

## Características Principales

* **Núcleo Híbrido C# + PowerShell:** El motor diferencial (`DiffEngine`) se compila en tiempo de ejecución vía `Add-Type`, lo que permite escaneo de registro y archivos de alto rendimiento junto con un motor de sanitización basado en Regex.
* **Soporte WIM Estándar:** Generación de contenedores `.wim` nativos aplicando el ratio de compresión máximo (`/Compress:max`), garantizando integración perfecta con DISM y utilizando directorios aislados para evitar errores de extracción.
* **Saneamiento de Perfil (Portabilidad Absoluta):** Detecta rutas absolutas atadas al usuario actual y las redirige de forma inteligente a `Users\Default`, asegurando que el despliegue sea universal sin importar la cuenta de destino.
* **Sanitización Jerárquica de Registro:** Las rutas absolutas detectadas en valores de registro se reemplazan automáticamente por variables de entorno (`%ProgramFiles(x86)%`, `%ProgramFiles%`, `%ProgramData%`, `%USERPROFILE%`, `%SystemRoot%`, `%SystemDrive%`) en orden de prioridad, garantizando portabilidad entre distintas instalaciones de Windows.
* **Escaneo de Registro COM (HKCR):** Además de `HKLM\SOFTWARE`, `HKCU\Software` y los servicios del sistema, el motor indexa `CLSID`, `Interface`, `TypeLib` y `AppID`, capturando registros de componentes COM requeridos por muchas aplicaciones de escritorio.
* **Diff de Registro Bidire
* ccional:** El motor no solo detecta claves y valores nuevos o modificados; también identifica y elimina del paquete final los valores y claves completas que la instalación haya borrado del sistema.
* **Soporte Completo de Tipos de Datos de Registro:** Serialización nativa y correcta de `DWORD`, `QWORD` (`hex(b)`), `SZ`, `ExpandString`, `Binary` y `MultiString`, evitando corrupciones al importar el `.reg` resultante.
* **Resiliencia ante Reinicios (Auto-Reanudación):** Incorpora un sistema de supervivencia a reinicios mediante un ancla en `RunOnce`. Si el instalador de tu programa requiere reiniciar el equipo, DeltaPack guarda su estado actual y reanuda la captura automáticamente tras el reinicio del sistema operativo.
* **Soporte VSS Integrado:** Capacidad nativa para rescatar y extraer archivos bloqueados o en uso durante la captura mediante instantáneas de volumen (Volume Shadow Copy), con limpieza posterior de doble vía (`vssadmin` con fallback a CIM) para máxima fiabilidad.
* **Adaptabilidad de Arquitectura Avanzada:** Detecta automáticamente la arquitectura del sistema (`x64`, `x86` o `arm64`) y la incorpora al nombre del paquete final, gestionando correctamente las rutas de registro y directorios variables (como WOW6432Node) sin duplicidad de datos.
* **Validaciones de Entrada:** Rechaza caracteres no válidos en el nombre del paquete y en el sufijo antes de iniciar la captura, evitando fallos posteriores por nombres de archivo inválidos.
* **Verificaciones Previas del Entorno:** Antes de ejecutarse, valida la versión mínima de PowerShell (5.1+), los privilegios de Administrador y la disponibilidad de `dism.exe` en el sistema.
* **Optimización y Estándares Modernos:** Implementa llamadas nativas CIM para mayor estabilidad (omitiendo por completo dependencias obsoletas WMI) y habilita automáticamente el soporte de rutas largas en Windows para evitar fallos de indexación.
* **Auditoría Automática:** Genera un reporte final en formato Markdown con el recuento exacto de claves de registro afectadas, tamaño real descomprimido, un manifiesto completo de rutas interceptadas y notas técnicas sobre el orden correcto de inyección (WIM antes que REG).

## Modo de Uso y Estructura

1. Descarga el repositorio como un archivo `.zip` y extráelo en una ruta corta (ej. `C:\DeltaPackDual`).
2. Asegúrate de mantener la integridad de la estructura de directorios para el correcto funcionamiento de la suite:
   ```text
        TuCarpetaPrincipal/
        │   DeltaPackDual-Engine.exe    <-- Ejecutable Lanzador
        ├───Script/
            └───DeltaPackDual-Engine.ps1

    ```
3. Haz doble clic en **`DeltaPackDual-Engine.exe`**. El lanzador solicitará permisos de Administrador y preparará el entorno de ejecución de manera automática.

## Recomendación de Entorno (Clean Room)
Para garantizar que los paquetes generados sean completamente universales y no contengan dependencias cruzadas, es estrictamente recomendado crear un entorno "Clean Room" (Habitación Limpia).

Se debe utilizar una instalación base de Windows 10 22H2 o superior sin conexión a internet (si es posible), la cual debe tener incluidas previamente todas las librerías necesarias (como Visual C++ Redistributables, .NET Framework, etc.) para el correcto funcionamiento del software a empaquetar. Es preferible que esta base esté montada en una Máquina Virtual con soporte para Snapshots (Instantáneas). Esto permite realizar capturas completamente limpias y revertir la máquina a su estado original después de empaquetar cada aplicación.

---

## Guía de Uso: Creación del Paquete (Packager)

El proceso de creación está diseñado como un asistente interactivo y seguro:

1. Ejecuta el lanzador **`DeltaPackDual-Engine.exe`**. El sistema validará automáticamente los privilegios de Administrador y preparará el entorno.
2. Ingresa el nombre base de tu paquete y selecciona su categoría (Paquete Principal o Complemento/Extra).
3. **Fase 1 (Mapeo Base):** El motor tomará una fotografía instantánea del estado actual de todos los directorios clave y las colmenas de registro del sistema.
4. **Pausa de Instalación:** El proceso se detendrá. En este momento, instala tu software, inícialo, aplica licencias y configuraciones. **Cierra el programa por completo** al terminar.
* *Nota:* Si el instalador te pide reiniciar el equipo, hazlo con tranquilidad. La herramienta detectará el reinicio y te permitirá continuar la captura al volver a Windows.
5. **Fase 2 y Empaquetado:** Presiona Enter en la consola. El motor aislará los cambios exactos, aplicará la matriz de exclusiones de ruido, rescatará archivos bloqueados, redirigirá los perfiles de usuario y empaquetará los resultados finales.

### Estructura de Salida

En tu escritorio se creará automáticamente la carpeta `DeltaPack_[Nombre_Del_Paquete]` conteniendo:

* `[Nombre].wim` (Contenedor con los binarios purificados).
* `[Nombre].reg` (Registro saneado con redirecciones universales).
* `README_[Nombre].md` (Reporte forense, estadístico y manifiesto de archivos).
* `Install_Log.txt` (Traza completa del proceso detallando niveles de severidad).

---

## Guía de Uso: Inyección en Imágenes Windows (Despliegue)

Los paquetes generados por **DeltaPack Dual-Engine** están diseñados arquitectónicamente para integrarse de forma nativa con **[AdminImagenOffline](https://github.com/SOFTMAXTER/AdminImagenOffline)**.

**Requisito Previo Importante**: Antes de proceder, es fundamental asegurarse de que la imagen de Windows de destino ya tenga **incluidas todas las librerías necesarias** (como Visual C++ Redistributables, .NET Framework, etc.) de las que dependa tu aplicación para garantizar su correcto funcionamiento una vez desplegado el sistema.

A continuación, se detallan los pasos exactos para inyectar permanentemente tu aplicación (WIM + REG) dentro de un archivo `install.wim` o un disco virtual de despliegue (`.vhdx`):

### Pasos exactos para la integración:

1. **Preparación:** Ejecuta `AdminImagenOffline` (vía su archivo `.exe`) con privilegios de Administrador.
2. **Montaje de Imagen:** * En el Menú Principal, selecciona la opción **[1] Montar / Desmontar / Guardar Imagen**.
* Selecciona **[1] Montar Imagen** y busca tu archivo base (ej. `install.wim` o un archivo `.vhdx`).
* Selecciona el número de índice de la edición de Windows deseada (ej. Pro, Enterprise) y espera a que finalice el proceso de montaje.
* Regresa al Menú Principal pulsando **[V]**.
3. **Acceso al Inyector:** * En la sección de *INGENIERÍA & AJUSTES*, selecciona la opción **[5] Personalizacion (Apps, Tweaks, Unattend.xml)**.
* Dentro del menú de personalización, elige la opción **[7] Inyector de Addons (.wim, .tpk, .bpk, .reg)** para abrir el módulo gráfico avanzado.
4. **Carga de Archivos:** * Haz clic en el botón azul **"+ Agregar Addons..."** ubicado en la esquina superior derecha.
* Selecciona **ambos** archivos generados por DeltaPack (`tu_app.wim` y `tu_app.reg`) desde tu carpeta de salida.
* *Nota del Motor:* El sistema auto-ordenará internamente las prioridades (inyectando primero los binarios .wim y luego fusionando el registro).
5. **Filtro de Arquitectura:** En la sección superior de la interfaz, selecciona la arquitectura de destino de tu imagen (`x86` o `x64`). El módulo ignorará archivos que no correspondan para proteger la integridad del sistema.
6. **Ejecución:** Haz clic en el botón verde **"INYECTAR TODOS LOS ADDONS"**. El motor descomprimirá limpiamente los binarios evadiendo las restricciones de *TrustedInstaller* y fusionará las claves de registro en las colmenas offline (`HKLM\OfflineSoftware`, etc.).
7. **Guardado (Commit):** * Cierra el módulo gráfico y regresa al Menú de Gestión de Imagen (Opción **[1]** del Menú Principal).
* Selecciona **[3] Guardar y Desmontar Imagen (Commit)** para sellar permanentemente la aplicación dentro de la imagen maestra de Windows.

---

## Apoya el Proyecto

DeltaPack Dual-Engine es una herramienta de grado empresarial desarrollada y mantenida para facilitar la ingeniería de sistemas. Si esta suite te ha ahorrado horas de trabajo empaquetando software atípico o ha mejorado tus despliegues corporativos, considera apoyar su desarrollo para garantizar actualizaciones continuas frente a las nuevas iteraciones de Windows.

* [💳 Donar vía PayPal](https://www.paypal.com/donate/?hosted_button_id=U65G2GXDTUGML)

## Autor y Colaboradores

* **Autor Principal**: SOFTMAXTER
* **Análisis y refinamiento de código**: Realizado en colaboración con inteligencia artificial para garantizar máxima calidad, optimización de algoritmos.

## Aviso Legal y Uso Aceptable (Disclaimer)

**DeltaPack Dual-Engine** es una herramienta de administración, auditoría y empaquetado, diseñada estrictamente para fines corporativos legítimos y despliegue automatizado.

* **Neutralidad:** Este software actúa como un clonador neutral del estado del sistema de archivos. No elude, promueve ni facilita la rotura de mecanismos DRM ni el pirateo de software.
* **Responsabilidad Compartida:** Al emplear DeltaPack, el usuario asume la obligación de garantizar que posee las licencias corporativas adecuadas para empaquetar, modificar y redistribuir el software capturado, cumpliendo con los EULA vigentes.
* **Exención:** El desarrollador (SOFTMAXTER) declina cualquier responsabilidad derivada del uso indebido de la herramienta, de infracciones de propiedad intelectual, o de corrupciones del sistema causadas por inyecciones defectuosas o bloqueos de antivirus en entornos hostiles.

### Cómo Contribuir

Si tienes ideas o mejoras para este proyecto:
1.  Haz un Fork del repositorio principal.
2.  Crea una nueva rama (`git checkout -b feature/nueva-funcionalidad`).
3.  Aplica y documenta tus cambios asegurando la compatibilidad con el entorno general.
4.  Realiza un Push hacia tu rama (`git push origin feature/nueva-funcionalidad`).
5.  Abre un Pull Request en el repositorio.

---
## Licencia y Modelo de Negocio (Dual Licensing)
Este proyecto está protegido bajo derechos de autor y utiliza un modelo de **Doble Licencia (Dual Licensing)**:

### 1. Licencia Comunitaria (Open Source)
Distribuido bajo la **Licencia GNU GPLv3**. Eres libre de usar, modificar y compartir este software. Bajo esta licencia (*Copyleft*), cualquier herramienta derivada o script que integre código de DeltaPack **debe ser de código abierto** bajo la misma licencia.

### 2. Licencia Comercial Corporativa
Si deseas integrar el motor de DeltaPack en un producto comercial propietario (closed-source), o requieres Acuerdos de Nivel de Servicio (SLA) para tu corporación, **debes adquirir una Licencia Comercial**.

Para mayor información o consultas de licenciamiento empresarial, contactar mediante correo electrónico a: `softmaxter@hotmail.com`
