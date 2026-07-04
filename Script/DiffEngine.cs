// ============================================================================
// DeltaPack Dual-Engine - DiffEngine.cs
// ----------------------------------------------------------------------------
// Motor C# de snapshot diferencial para registro y archivos.
//
// Responsabilidades principales:
//   - Escanear arboles de registro y generar un .reg diferencial.
//   - Escanear archivos con fingerprint hibrido configurable.
//   - Separar archivos nuevos, modificados y eliminados.
//   - Recolectar metricas internas del escaneo.
//   - Serializar/deserializar el estado para sobrevivir reinicios.
//
// ============================================================================
// Copyright (C) 2026 SOFTMAXTER
// ============================================================================

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;
using System.Text.RegularExpressions;

public class DiffEngine
{
    // --- MOTOR REGISTRO ---
    public Dictionary<string, Dictionary<string, string>> RegSnapshot = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);

    // Contador de progreso para arboles grandes (HKCR\CLSID, Interface, TypeLib,
    // etc. pueden tener decenas de miles de claves). Sin esto, el usuario puede pensar que el
    // script se colgo durante varios segundos/minutos de escaneo silencioso.
    public static long KeysScanned = 0;
    private static void ReportRegistryProgress() {
        KeysScanned++;
        if (KeysScanned % 2000 == 0) {
            Console.Write("\r  Escaneando registro... {0:N0} claves procesadas (Ctrl+C para cancelar)", KeysScanned);
        }
    }

    // Externalizado a DeltaPack.Exclusions.json (ver carga tras Add-Type, tras esta
    // definicion de clase). Estatico y mutable: PowerShell lo puebla en runtime; se comparte entre
    // las instancias Pre y Post sin necesidad de duplicar el HashSet por cada DiffEngine.
    public static HashSet<string> RegExclusions = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

    // Guardia anti-doble-inyeccion: solo genera el path WOW si la regla
    // no contiene ya "WOW6432Node" para evitar "SOFTWARE\WOW6432Node\WOW6432Node\..."
    private bool IsRegExcluded(string path) {
        foreach (string ex in RegExclusions) {
            if (path.IndexOf(ex, StringComparison.OrdinalIgnoreCase) >= 0) return true;
            
            if (ex.StartsWith(@"SOFTWARE\", StringComparison.OrdinalIgnoreCase) &&
                ex.IndexOf(@"WOW6432Node", StringComparison.OrdinalIgnoreCase) < 0) {
                string wowPath = ex.Insert(9, @"WOW6432Node\");
                if (path.IndexOf(wowPath, StringComparison.OrdinalIgnoreCase) >= 0) return true;
            }
        }
        return false;
    }

    private string ParseValueData(RegistryKey key, string valName) {
        try {
            RegistryValueKind kind = key.GetValueKind(valName);
            object data = key.GetValue(valName, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
            if (data == null) return "";

            // --- 1. CAPTURA DE VARIABLES DEL ENTORNO LOCAL ---
            string userProfile  = Environment.GetEnvironmentVariable("USERPROFILE");
            string sysDrive     = Environment.GetEnvironmentVariable("SystemDrive");
            string windir       = Environment.GetEnvironmentVariable("windir");
            string progFiles    = Environment.GetEnvironmentVariable("ProgramFiles");
            string progFilesX86 = Environment.GetEnvironmentVariable("ProgramFiles(x86)");
            string progData     = Environment.GetEnvironmentVariable("ProgramData");

            // --- 2. MOTOR DE SANITIZACION JERARQUICO ---
            // El orden es CRITICO: rutas mas largas y especificas primero.
            Func<string, string> Sanitize = (input) => {
                if (string.IsNullOrEmpty(input)) return input;
                string output = input;
                
                if (!string.IsNullOrEmpty(progFilesX86) && output.IndexOf(progFilesX86, StringComparison.OrdinalIgnoreCase) >= 0)
                    output = Regex.Replace(output, Regex.Escape(progFilesX86), "%ProgramFiles(x86)%", RegexOptions.IgnoreCase);
                    
                if (!string.IsNullOrEmpty(progFiles) && output.IndexOf(progFiles, StringComparison.OrdinalIgnoreCase) >= 0)
                    output = Regex.Replace(output, Regex.Escape(progFiles), "%ProgramFiles%", RegexOptions.IgnoreCase);
                    
                if (!string.IsNullOrEmpty(progData) && output.IndexOf(progData, StringComparison.OrdinalIgnoreCase) >= 0)
                    output = Regex.Replace(output, Regex.Escape(progData), "%ProgramData%", RegexOptions.IgnoreCase);
                    
                if (!string.IsNullOrEmpty(userProfile) && output.IndexOf(userProfile, StringComparison.OrdinalIgnoreCase) >= 0)
                    output = Regex.Replace(output, Regex.Escape(userProfile), "%USERPROFILE%", RegexOptions.IgnoreCase);
                    
                if (!string.IsNullOrEmpty(windir) && output.IndexOf(windir, StringComparison.OrdinalIgnoreCase) >= 0)
                    output = Regex.Replace(output, Regex.Escape(windir), "%SystemRoot%", RegexOptions.IgnoreCase);
                    
                // Anclado con lookahead "(?=\\)" para reemplazar "C:" solo cuando
                // realmente encabeza una ruta (seguido de backslash), evitando corromper
                // apariciones no-ruta de "C:" (claves de licencia, horas, URLs, etc.).
                if (!string.IsNullOrEmpty(sysDrive) && output.IndexOf(sysDrive + "\\", StringComparison.OrdinalIgnoreCase) >= 0)
                    output = Regex.Replace(output, Regex.Escape(sysDrive) + @"(?=\\)", "%SystemDrive%", RegexOptions.IgnoreCase);

                return output;
            };

            // --- 3. CONVERSION Y ESCRITURA EN FORMATO .REG ---
            switch (kind) {
                case RegistryValueKind.DWord:
                    return "dword:" + ((int)data).ToString("x8");
                    
                // REG_QWORD serializado correctamente como hex(b) (little-endian de 8 bytes).
                // Sin este case, los valores QWORD (usados por Adobe, VS, JetBrains, etc.)
                // caian al default y se escribian como REG_SZ, corrompiendose al importar.
                case RegistryValueKind.QWord:
                    ulong qwordVal = Convert.ToUInt64(data);
                    byte[] qBytes  = BitConverter.GetBytes(qwordVal);
                    return "hex(b):" + BitConverter.ToString(qBytes).Replace("-", ",").ToLower();
                    
                case RegistryValueKind.String:
                case RegistryValueKind.ExpandString:
                    string originalString  = (string)data;
                    string sanitizedString = Sanitize(originalString);
                    
                    if (originalString != sanitizedString || kind == RegistryValueKind.ExpandString) {
                        byte[] strBytes = System.Text.Encoding.Unicode.GetBytes(sanitizedString);
                        return "hex(2):" + BitConverter.ToString(strBytes).Replace("-", ",").ToLower() + ",00,00";
                    }
                    
                    return "\"" + sanitizedString.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
                    
                case RegistryValueKind.Binary:
                    byte[] bytes = (byte[])data;
                    if (bytes.Length == 0) return "hex:";
                    return "hex:" + BitConverter.ToString(bytes).Replace("-", ",").ToLower();
                   
                case RegistryValueKind.MultiString:
                    string[] strings = (string[])data;
                    if (strings.Length == 0) return "hex(7):00,00,00,00";
                    
                    List<string> hex7Parts = new List<string>();
                    foreach (string str in strings) {
                        string safeStr = Sanitize(str);
                        byte[] strBytesMulti = System.Text.Encoding.Unicode.GetBytes(safeStr);
                        foreach (byte b in strBytesMulti) {
                            hex7Parts.Add(b.ToString("x2"));
                        }
                        hex7Parts.Add("00"); hex7Parts.Add("00");
                    }
                    hex7Parts.Add("00"); hex7Parts.Add("00");
                    return "hex(7):" + string.Join(",", hex7Parts);

                default:
                    return "\"" + data.ToString().Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
            }
        } catch { return ""; }
    }

    public void ScanRegistryTree(RegistryKey root, string currentPath) {
        if (IsRegExcluded(currentPath)) return;
        try {
            using (RegistryKey key = root.OpenSubKey(currentPath, false)) {
                if (key == null) return;
                var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (string vName in key.GetValueNames()) {
                    values[vName] = ParseValueData(key, vName);
                }
                string absPath = root.Name + "\\" + currentPath;
                RegSnapshot[absPath] = values;
                ReportRegistryProgress();

                foreach (string subKey in key.GetSubKeyNames()) {
                    ScanRegistryTree(root, currentPath + "\\" + subKey);
                }
            }
        } catch { }
    }

    // --- Motor Diferencial Completo (Nuevas, Modificadas y ELIMINADAS) ---
    public static void GenerateRegFile(DiffEngine pre, DiffEngine post, string outputPath) {
        using (StreamWriter writer = new StreamWriter(outputPath, false, System.Text.Encoding.Unicode)) {
            writer.WriteLine("Windows Registry Editor Version 5.00");
            writer.WriteLine("; ==================================================");
            writer.WriteLine("; Generado por DeltaPack Dual-Engine");
            writer.WriteLine("; ==================================================");

            // 1. Procesar Claves Nuevas, Modificadas y Valores Eliminados
            foreach (var postKey in post.RegSnapshot) {
                string keyPath = postKey.Key;
                bool isNewKey = !pre.RegSnapshot.ContainsKey(keyPath);
                bool keyHeaderWritten = false;

                if (isNewKey) {
                    writer.WriteLine("\n[" + keyPath + "]");
                    keyHeaderWritten = true;
                }

                foreach (var postVal in postKey.Value) {
                    string valName = postVal.Key;
                    string valData = postVal.Value;
                    bool isNewOrModified = true;

                    if (!isNewKey && pre.RegSnapshot[keyPath].ContainsKey(valName)) {
                        if (pre.RegSnapshot[keyPath][valName] == valData) isNewOrModified = false;
                    }

                    if (isNewOrModified) {
                        if (!keyHeaderWritten) { writer.WriteLine("\n[" + keyPath + "]"); keyHeaderWritten = true; }
                        string formattedName = string.IsNullOrEmpty(valName) ? "@" : "\"" + valName.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
                        writer.WriteLine(formattedName + "=" + valData);
                    }
                }

                // Valores que estaban en Pre pero ya no en Post (Valores Eliminados)
                if (!isNewKey) {
                    foreach (var preVal in pre.RegSnapshot[keyPath]) {
                        if (!post.RegSnapshot[keyPath].ContainsKey(preVal.Key)) {
                            if (!keyHeaderWritten) { writer.WriteLine("\n[" + keyPath + "]"); keyHeaderWritten = true; }
                            string formattedName = string.IsNullOrEmpty(preVal.Key) ? "@" : "\"" + preVal.Key.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
                            writer.WriteLine(formattedName + "=-");
                        }
                    }
                }
            }

            // 2. Procesar Claves Enteras Eliminadas
            foreach (var preKey in pre.RegSnapshot) {
                if (!post.RegSnapshot.ContainsKey(preKey.Key)) {
                    writer.WriteLine("\n[-" + preKey.Key + "]");
                }
            }
        }
    }

    // --- MOTOR ARCHIVOS ---
    // ConcurrentDictionary: permite escritura segura desde los hilos paralelos de ScanDirectoryParallel.
    // Compatible con todos los sitios de lectura existentes (ContainsKey, indexer, foreach, Count).
    public ConcurrentDictionary<string, string> FileSnapshot = new ConcurrentDictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    // Externalizado a DeltaPack.Exclusions.json. Estatico y mutable por el mismo
    // motivo que RegExclusions.
    public static HashSet<string> FileExclusions = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

    public class FileScanMetrics {
        public long DirectoriesDiscovered = 0;
        public long DirectoriesScanned = 0;
        public long DirectoriesSkippedByExclusion = 0;
        public long DirectoriesSkippedByReparsePoint = 0;
        public long DirectoriesSkippedByAccessDenied = 0;
        public long DirectoriesSkippedByIoError = 0;
        public long DirectoriesSkippedByOtherError = 0;

        public long FilesDiscovered = 0;
        public long FilesIndexed = 0;
        public long FilesHashed = 0;
        public long FilesByMetadata = 0;
        public long FilesLegacy = 0;
        public long FilesFallbackSize = 0;
        public long FilesSkippedByExclusion = 0;
        public long FilesSkippedByReparsePoint = 0;
        public long FilesSkippedByAccessDenied = 0;
        public long FilesSkippedByIoError = 0;
        public long FilesSkippedByOtherError = 0;

        public long HashBytesRead = 0;
        public long ElapsedMilliseconds = 0;

        public long FilesFingerprinted {
            get { return FilesHashed + FilesByMetadata + FilesLegacy + FilesFallbackSize; }
        }
        public long FilesSkipped {
            get { return FilesSkippedByExclusion + FilesSkippedByReparsePoint + FilesSkippedByAccessDenied + FilesSkippedByIoError + FilesSkippedByOtherError; }
        }
        public long DirectoriesSkipped {
            get { return DirectoriesSkippedByExclusion + DirectoriesSkippedByReparsePoint + DirectoriesSkippedByAccessDenied + DirectoriesSkippedByIoError + DirectoriesSkippedByOtherError; }
        }
    }

    public FileScanMetrics ScanMetrics = new FileScanMetrics();

    public void ResetScanMetrics() {
        ScanMetrics = new FileScanMetrics();
    }

    public static long HashThresholdBytes = 512 * 1024L;  // 512 KB por defecto

    // Alias de compatibilidad para las pruebas y configuraciones del Paso 6.
    // Mantiene [DiffEngine]::SmallFileHashThresholdBytes funcionando sin romper el PS1,
    // que ya usa [DiffEngine]::HashThresholdBytes.
    public static long SmallFileHashThresholdBytes {
        get { return HashThresholdBytes; }
        set { HashThresholdBytes = value; }
    }

    public static int MaxScanParallelism = 0;

    private static ParallelOptions GetScanOptions() {
        int dop = MaxScanParallelism;
        if (dop <= 0) dop = Math.Min(4, Environment.ProcessorCount);
        if (dop < 1) dop = 1;
        return new ParallelOptions { MaxDegreeOfParallelism = dop };
    }

    private bool IsFileExcluded(string path) {
        if (string.IsNullOrEmpty(path)) return true;

        foreach (string ex in FileExclusions) {
            if (string.IsNullOrEmpty(ex)) continue;

            if (ex.StartsWith(".")) {
                if (path.EndsWith(ex, StringComparison.OrdinalIgnoreCase)) return true;
            } else {
                if (path.IndexOf(ex, StringComparison.OrdinalIgnoreCase) >= 0) return true;
            }
        }
        return false;
    }

    // Evita seguir junctions/symlinks/mount-points. En Windows varias rutas comunes
    // (por ejemplo perfiles heredados o enlaces de sistema) son reparse points; seguirlas puede
    // duplicar contenido, salir del arbol esperado o incluso crear recorridos recursivos.
    private bool IsReparsePoint(string path) {
        try {
            FileAttributes attr = File.GetAttributes(path);
            return (attr & FileAttributes.ReparsePoint) == FileAttributes.ReparsePoint;
        } catch {
            // Si no se puede leer el atributo, no bloqueamos el escaneo: ScanDirectory ya tiene
            // manejo granular de UnauthorizedAccessException/IOException en los puntos de lectura.
            return false;
        }
    }

    // Normaliza fingerprints del formato anterior al nuevo (sin prefijo -> prefijo T:).
    // Garantiza compatibilidad al cargar estados guardados por versiones pre-MEJORA A:
    // los archivos grandes seguiran comparando igual en GetFileDifferences evitando
    // false-positives masivos en el primer resume tras actualizar el motor.
    private static string NormalizeFingerprint(string value) {
        if (string.IsNullOrEmpty(value) || value == "DIR") return value;
        if (value.StartsWith("SHA256:", StringComparison.OrdinalIgnoreCase)) return value;
        if (value.StartsWith("META:",   StringComparison.OrdinalIgnoreCase)) return value;
        if (value.Length >= 2 && value[1] == ':') return value;  // compatibilidad H:/T:/S:

        // Formato antiguo: "ticks-size". Lo convertimos al formato META nuevo cuando sea posible.
        int sep = value.LastIndexOf('-');
        if (sep > 0 && sep < value.Length - 1) {
            string ticks = value.Substring(0, sep);
            string len   = value.Substring(sep + 1);
            return "META:" + ticks + ";LEN:" + len;
        }
        return value;
    }

    private string ComputeSizeFallback(string filePath, Exception originalError) {
        try {
            FileInfo fi = new FileInfo(filePath);
            Interlocked.Increment(ref ScanMetrics.FilesFallbackSize);
            return "S:" + fi.Length;
        } catch (UnauthorizedAccessException) {
            Interlocked.Increment(ref ScanMetrics.FilesSkippedByAccessDenied);
        } catch (IOException) {
            Interlocked.Increment(ref ScanMetrics.FilesSkippedByIoError);
        } catch {
            Interlocked.Increment(ref ScanMetrics.FilesSkippedByOtherError);
        }
        return string.Empty;
    }

    private string ComputeFingerprint(string filePath) {
        try {
            FileInfo fi = new FileInfo(filePath);
            if (HashThresholdBytes <= 0) {
                Interlocked.Increment(ref ScanMetrics.FilesLegacy);
                return fi.LastWriteTimeUtc.Ticks + "-" + fi.Length;
            }
            if (fi.Length < HashThresholdBytes) {
                using (SHA256 sha = SHA256.Create())
                using (FileStream fs = new FileStream(filePath, FileMode.Open, FileAccess.Read,
                                                      FileShare.ReadWrite, 65536, FileOptions.SequentialScan)) {
                    byte[] hash = sha.ComputeHash(fs);
                    Interlocked.Increment(ref ScanMetrics.FilesHashed);
                    Interlocked.Add(ref ScanMetrics.HashBytesRead, fi.Length);
                    return "SHA256:" + BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant() + ";LEN:" + fi.Length;
                }
            }

            Interlocked.Increment(ref ScanMetrics.FilesByMetadata);
            return "META:" + fi.LastWriteTimeUtc.Ticks + ";LEN:" + fi.Length;
        } catch (UnauthorizedAccessException ex) {
            return ComputeSizeFallback(filePath, ex);
        } catch (IOException ex) {
            return ComputeSizeFallback(filePath, ex);
        } catch (Exception ex) {
            return ComputeSizeFallback(filePath, ex);
        }
    }

    public void ScanDirectory(string path) {
        Stopwatch sw = Stopwatch.StartNew();
        try {
            ScanDirectoryInternal(path);
        } finally {
            sw.Stop();
            Interlocked.Add(ref ScanMetrics.ElapsedMilliseconds, sw.ElapsedMilliseconds);
        }
    }

    private void ScanDirectoryInternal(string path) {
        if (!Directory.Exists(path)) return;
        if (IsFileExcluded(path)) {
            Interlocked.Increment(ref ScanMetrics.DirectoriesSkippedByExclusion);
            return;
        }
        if (IsReparsePoint(path)) {
            Interlocked.Increment(ref ScanMetrics.DirectoriesSkippedByReparsePoint);
            return;
        }

        string[] files, dirs;
        try {
            files = Directory.GetFiles(path);
            dirs  = Directory.GetDirectories(path);
            Interlocked.Increment(ref ScanMetrics.DirectoriesScanned);
        } catch (UnauthorizedAccessException) {
            Interlocked.Increment(ref ScanMetrics.DirectoriesSkippedByAccessDenied);
            return;
        } catch (IOException) {
            Interlocked.Increment(ref ScanMetrics.DirectoriesSkippedByIoError);
            return;
        } catch {
            Interlocked.Increment(ref ScanMetrics.DirectoriesSkippedByOtherError);
            return;
        }

        Parallel.ForEach(files, GetScanOptions(), file => {
            Interlocked.Increment(ref ScanMetrics.FilesDiscovered);
            if (IsFileExcluded(file)) {
                Interlocked.Increment(ref ScanMetrics.FilesSkippedByExclusion);
                return;
            }
            if (IsReparsePoint(file)) {
                Interlocked.Increment(ref ScanMetrics.FilesSkippedByReparsePoint);
                return;
            }
            try {
                string fp = ComputeFingerprint(file);
                if (!string.IsNullOrEmpty(fp)) {
                    FileSnapshot[file] = fp;
                    Interlocked.Increment(ref ScanMetrics.FilesIndexed);
                }
            } catch (UnauthorizedAccessException) {
                Interlocked.Increment(ref ScanMetrics.FilesSkippedByAccessDenied);
            } catch (IOException) {
                Interlocked.Increment(ref ScanMetrics.FilesSkippedByIoError);
            } catch {
                Interlocked.Increment(ref ScanMetrics.FilesSkippedByOtherError);
            }
        });

        Parallel.ForEach(dirs, GetScanOptions(), dir => {
            Interlocked.Increment(ref ScanMetrics.DirectoriesDiscovered);
            if (IsFileExcluded(dir)) {
                Interlocked.Increment(ref ScanMetrics.DirectoriesSkippedByExclusion);
                return;
            }
            if (IsReparsePoint(dir)) {
                Interlocked.Increment(ref ScanMetrics.DirectoriesSkippedByReparsePoint);
                return;
            }
            FileSnapshot[dir] = "DIR";
            ScanDirectoryInternal(dir);  // recursion segura: cada rama opera sobre su propio subconjunto
        });
    }

    // CopyAndHash: lee el origen UNA sola vez, escribe al destino y alimenta
    // SHA256 por bloques simultaneamente. Elimina la doble lectura de la ruta anterior
    // (File.Copy + segundo FileStream.OpenRead sobre el destino para calcular el hash).
    // Uso de FileOptions.SequentialScan: informa al SO que puede prefetch agresivo.
    // Uso de FileShare.ReadWrite en origen: no bloquea lectores concurrentes (compatible con
    // el Explorador de Windows mientras el staging corre). Los archivos realmente bloqueados
    // (en escritura exclusiva por otro proceso) lanzan IOException y caen al canal VSS.
    public static string CopyAndHash(string sourcePath, string destPath) {
        const int BUF = 81920; // 80 KB: sweet-spot velocidad/RAM para HDD y SSD
        using (SHA256 sha = SHA256.Create())
        using (var fsIn  = new FileStream(sourcePath, FileMode.Open,   FileAccess.Read,  FileShare.ReadWrite, BUF, FileOptions.SequentialScan))
        using (var fsOut = new FileStream(destPath,   FileMode.Create, FileAccess.Write, FileShare.None,      BUF)) {
            byte[] buf = new byte[BUF];
            int n;
            while ((n = fsIn.Read(buf, 0, BUF)) > 0) {
                sha.TransformBlock(buf, 0, n, null, 0);
                fsOut.Write(buf, 0, n);
            }
            sha.TransformFinalBlock(buf, 0, 0);
            return BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
        }
    }

    public class FileDiffResult : System.Collections.Generic.IEnumerable<string> {
        public List<string> NewFiles      = new List<string>();  // archivos no presentes en Pre
        public List<string> ModifiedFiles = new List<string>();  // archivos con fingerprint distinto
        public List<string> NewDirs       = new List<string>();  // carpetas nuevas (para staging)
        public int FileCount { get { return NewFiles.Count + ModifiedFiles.Count; } }
        public int TotalCount { get { return FileCount; } }
        public List<string> AllChangedFiles {
            get {
                List<string> all = new List<string>();
                all.AddRange(NewFiles);
                all.AddRange(ModifiedFiles);
                return all;
            }
        }

        public System.Collections.Generic.IEnumerator<string> GetEnumerator() {
            foreach (var f in NewFiles)      yield return f;
            foreach (var f in ModifiedFiles) yield return f;
            foreach (var d in NewDirs)       yield return d;
        }
        System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() { return GetEnumerator(); }
    }

    public static FileDiffResult GetFileDifferences(DiffEngine pre, DiffEngine post) {
        var result = new FileDiffResult();
        foreach (var kvp in post.FileSnapshot) {
            bool isDir = kvp.Value == "DIR";
            bool isNew = !pre.FileSnapshot.ContainsKey(kvp.Key);
            if (isNew) {
                if (isDir) result.NewDirs.Add(kvp.Key);
                else       result.NewFiles.Add(kvp.Key);
            } else if (!isDir && pre.FileSnapshot[kvp.Key] != kvp.Value) {
                result.ModifiedFiles.Add(kvp.Key);
            }
        }
        return result;
    }

    // Alias explicito para reportes: conserva GetFileDifferences como API principal
    // e incorpora el nombre usado por las pruebas del Paso 6.
    public static FileDiffResult GetFileDifferenceReport(DiffEngine pre, DiffEngine post) {
        return GetFileDifferences(pre, post);
    }

    // Detecta archivos/carpetas presentes en Pre pero ausentes en Post (eliminados
    // por el instalador). Un WIM es aditivo y no puede representar una eliminacion, por lo que esta
    // lista no se copia al paquete; se devuelve para documentarla en el reporte y dar visibilidad
    // de lo que el instalador borro del sistema base.
    public static List<string> GetDeletedFiles(DiffEngine pre, DiffEngine post) {
        List<string> deleted = new List<string>();
        foreach (var kvp in pre.FileSnapshot) {
            if (!post.FileSnapshot.ContainsKey(kvp.Key)) {
                deleted.Add(kvp.Key);
            }
        }
        return deleted;
    }

    // =================================================================
    //  SISTEMA DE SERIALIZACION BINARIA (SUPERVIVENCIA A REINICIOS)
    // =================================================================
    public void SaveState(string filePath) {
        using (FileStream fs = new FileStream(filePath, FileMode.Create))
        using (BinaryWriter bw = new BinaryWriter(fs, System.Text.Encoding.UTF8)) {
            
            // 1. Guardar Archivos
            bw.Write(FileSnapshot.Count);
            foreach (var kvp in FileSnapshot) {
                bw.Write(kvp.Key);
                bw.Write(kvp.Value);
            }
            
            // 2. Guardar Registro
            bw.Write(RegSnapshot.Count);
            foreach (var keyKvp in RegSnapshot) {
                bw.Write(keyKvp.Key);
                bw.Write(keyKvp.Value.Count);
                foreach (var valKvp in keyKvp.Value) {
                    bw.Write(valKvp.Key);
                    bw.Write(valKvp.Value);
                }
            }
        }
    }

    public static DiffEngine LoadState(string filePath) {
        DiffEngine engine = new DiffEngine();
        using (FileStream fs = new FileStream(filePath, FileMode.Open))
        using (BinaryReader br = new BinaryReader(fs, System.Text.Encoding.UTF8)) {
            
            // 1. Cargar Archivos
            // NormalizeFingerprint convierte el formato antiguo (sin prefijo) al nuevo (T:)
            // para que el primer GetFileDifferences tras actualizar el motor no genere
            // false-positives masivos en capturas reanudadas con estado pre-MEJORA A.
            int fileCount = br.ReadInt32();
            for (int i = 0; i < fileCount; i++) {
                string key = br.ReadString();
                string val = NormalizeFingerprint(br.ReadString());
                engine.FileSnapshot[key] = val;
            }
            
            // 2. Cargar Registro
            int regCount = br.ReadInt32();
            for (int i = 0; i < regCount; i++) {
                string keyPath = br.ReadString();
                int valCount = br.ReadInt32();
                var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                for (int j = 0; j < valCount; j++) {
                    values[br.ReadString()] = br.ReadString();
                }
                engine.RegSnapshot[keyPath] = values;
            }
        }
        return engine;
    }
}