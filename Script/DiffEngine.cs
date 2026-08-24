// ============================================================================
// DeltaPack Dual-Engine - DiffEngine.cs
// ----------------------------------------------------------------------------
// Motor C# de snapshot diferencial para registro y archivos.
//
// Responsabilidades principales:
//   - Escanear arboles de registro y generar un .reg diferencial.
//   - Escanear archivos con SafeUSN + SHA256 y fallback exhaustivo.
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
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;
using Microsoft.Win32;

public class DiffEngine
{
    // --- MOTOR REGISTRO ---
    public Dictionary<string, Dictionary<string, string>> RegSnapshot = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);

    public class RegistryScanMetrics {
        public long KeysScanned = 0;
        public long ValuesScanned = 0;
        public long BranchesExcluded = 0;
        public long ValuesExcluded = 0;
        public long Errors = 0;
        public long ElapsedMilliseconds = 0;
    }

    // Contadores por instancia para producir un resumen independiente de cada
    // objetivo del Registro.
    public RegistryScanMetrics RegistryMetrics = new RegistryScanMetrics();
    public string LastRegistryScanSummaryLine = "";

    private void ReportRegistryProgress() {
        Interlocked.Increment(ref RegistryMetrics.KeysScanned);
    }

    // Externalizado a DeltaPack.Exclusions.json (ver carga tras Add-Type, tras esta
    // definicion de clase). Estatico y mutable: PowerShell lo puebla en runtime; se comparte entre
    // las instancias Pre y Post sin necesidad de duplicar el HashSet por cada DiffEngine.
    public static HashSet<string> RegExclusions = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    // Las altas y modificaciones de publicadores o integraciones del instalador
    // siguen capturandose. Solo sus eliminaciones, cuando una politica explicita
    // las clasifica como mantenimiento ambiental, se conservan como auditoria.
    public static HashSet<string> RegistryDeletionAuditPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    public static string UserDesktopPath = "";

    // Reglas granulares para valores volatiles dentro de claves que si deben
    // seguir capturandose. Esto evita excluir arboles completos como TaskCache,
    // donde un instalador puede registrar una tarea programada legitima.
    private sealed class RegistryValueExclusionRule {
        public string PathPrefix;
        public string ValueName;

        public RegistryValueExclusionRule(string pathPrefix, string valueName) {
            PathPrefix = pathPrefix;
            ValueName = valueName;
        }
    }

    // Compilamos las exclusiones una sola vez para evitar recorrer la lista
    // completa y construir variantes WOW6432Node para cada clave visitada.
    private sealed class RegExclusionNode {
        public Dictionary<string, RegExclusionNode> Children = new Dictionary<string, RegExclusionNode>(StringComparer.OrdinalIgnoreCase);
        public List<string> SegmentPrefixes = new List<string>();
        public bool Terminal = false;
    }
    private static readonly object ExclusionCompileLock = new object();
    private static RegExclusionNode RegExclusionRoot = new RegExclusionNode();
    private static string[] RegFragmentRules = new string[0];
    private static RegistryValueExclusionRule[] RegValueExclusionRules = new RegistryValueExclusionRule[0];
    private static int PreparedRegExclusionCount = -1;
    private static string[] PreparedFileExtensionRules = new string[0];
    private static string[] PreparedFileSubtreeRules = new string[0];
    private static string[] PreparedFileFragmentRules = new string[0];
    private static int PreparedFileExclusionCount = -1;

    public static int RegistryValueExclusionCount {
        get { return RegValueExclusionRules.Length; }
    }

    public static void AddRegistryValueExclusion(string pathPrefix, string valueName) {
        if (string.IsNullOrWhiteSpace(pathPrefix) || string.IsNullOrWhiteSpace(valueName)) return;
        string normalizedPath = pathPrefix.Trim().TrimEnd('\\');
        string normalizedName = valueName.Trim();

        lock (ExclusionCompileLock) {
            foreach (RegistryValueExclusionRule existing in RegValueExclusionRules) {
                if (existing.PathPrefix.Equals(normalizedPath, StringComparison.OrdinalIgnoreCase) &&
                    existing.ValueName.Equals(normalizedName, StringComparison.OrdinalIgnoreCase)) return;
            }

            List<RegistryValueExclusionRule> updated = new List<RegistryValueExclusionRule>(RegValueExclusionRules);
            updated.Add(new RegistryValueExclusionRule(normalizedPath, normalizedName));
            RegValueExclusionRules = updated.ToArray();
        }
    }

    private static bool IsRegistryValueExcluded(string absoluteKeyPath, string valueName) {
        if (string.IsNullOrEmpty(absoluteKeyPath) || string.IsNullOrEmpty(valueName)) return false;
        RegistryValueExclusionRule[] rules = RegValueExclusionRules;
        foreach (RegistryValueExclusionRule rule in rules) {
            if (!rule.ValueName.Equals(valueName, StringComparison.OrdinalIgnoreCase)) continue;
            if (absoluteKeyPath.Equals(rule.PathPrefix, StringComparison.OrdinalIgnoreCase) ||
                absoluteKeyPath.StartsWith(rule.PathPrefix + @"\", StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    private static void AddRegTrieRule(RegExclusionNode root, string rule) {
        string[] parts = rule.Split(new char[] { '\\' }, StringSplitOptions.RemoveEmptyEntries);
        RegExclusionNode node = root;
        for (int i = 0; i < parts.Length; i++) {
            string part = parts[i];
            bool isLast = i == parts.Length - 1;
            if (isLast && part.EndsWith("_", StringComparison.Ordinal)) {
                node.SegmentPrefixes.Add(part);
                return;
            }
            RegExclusionNode child;
            if (!node.Children.TryGetValue(part, out child)) {
                child = new RegExclusionNode();
                node.Children[part] = child;
            }
            node = child;
        }
        node.Terminal = true;
    }

    public static void PrepareExclusionMatchers() {
        lock (ExclusionCompileLock) {
            if (PreparedRegExclusionCount != RegExclusions.Count) {
                RegExclusionNode root = new RegExclusionNode();
                List<string> fragments = new List<string>();
                HashSet<string> expanded = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (string raw in RegExclusions) {
                    if (string.IsNullOrWhiteSpace(raw)) continue;
                    string rule = raw.Trim();
                    expanded.Add(rule);
                    if (rule.StartsWith(@"SOFTWARE\", StringComparison.OrdinalIgnoreCase) &&
                        rule.IndexOf(@"WOW6432Node", StringComparison.OrdinalIgnoreCase) < 0) {
                        expanded.Add(rule.Insert(9, @"WOW6432Node\"));
                    }
                }
                foreach (string rule in expanded) {
                    if (rule.StartsWith(@"\", StringComparison.Ordinal)) fragments.Add(rule);
                    else AddRegTrieRule(root, rule);
                }
                RegExclusionRoot = root;
                RegFragmentRules = fragments.ToArray();
                PreparedRegExclusionCount = RegExclusions.Count;
            }

            if (PreparedFileExclusionCount != FileExclusions.Count) {
                List<string> extensions = new List<string>();
                List<string> subtrees = new List<string>();
                List<string> fragments = new List<string>();
                foreach (string raw in FileExclusions) {
                    if (string.IsNullOrWhiteSpace(raw)) continue;
                    string rule = raw.Trim();
                    if (rule.StartsWith(".", StringComparison.Ordinal)) extensions.Add(rule);
                    else if (rule.EndsWith(@"\", StringComparison.Ordinal) || rule.EndsWith("/", StringComparison.Ordinal)) subtrees.Add(rule.TrimEnd('\\', '/'));
                    else fragments.Add(rule);
                }
                PreparedFileExtensionRules = extensions.ToArray();
                PreparedFileSubtreeRules = subtrees.ToArray();
                PreparedFileFragmentRules = fragments.ToArray();
                PreparedFileExclusionCount = FileExclusions.Count;
            }
        }
    }

    // Rutas que no pudieron verificarse durante el snapshot. Se conservan para
    // impedir que un error de lectura se transforme en una eliminacion falsa.
    public HashSet<string> RegScanErrors = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

    private void RecordRegistryScanError(string absolutePath) {
        if (string.IsNullOrEmpty(absolutePath)) return;
        lock (RegScanErrors) {
            if (RegScanErrors.Add(absolutePath)) {
                Interlocked.Increment(ref RegistryMetrics.Errors);
            }
        }
    }

    // Punto unico para evaluar las reglas de subarbol. Se expone tambien para
    // que las regresiones puedan comprobar rutas reales observadas tras reinicio
    // sin tener que crear claves temporales en el Registro del host de pruebas.
    public static bool IsRegistryPathExcluded(string path) {
        if (string.IsNullOrEmpty(path)) return false;
        if (PreparedRegExclusionCount != RegExclusions.Count) PrepareExclusionMatchers();

        foreach (string fragment in RegFragmentRules) {
            if (path.IndexOf(fragment, StringComparison.OrdinalIgnoreCase) >= 0) return true;
        }

        RegExclusionNode node = RegExclusionRoot;
        string[] parts = path.Split(new char[] { '\\' }, StringSplitOptions.RemoveEmptyEntries);
        foreach (string part in parts) {
            foreach (string prefix in node.SegmentPrefixes) {
                if (part.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return true;
            }
            RegExclusionNode child;
            if (!node.Children.TryGetValue(part, out child)) return false;
            node = child;
            if (node.Terminal) return true;
        }
        return false;
    }

    private bool IsRegExcluded(string path) {
        return IsRegistryPathExcluded(path);
    }

    private static readonly string EnvUserProfile = Environment.GetEnvironmentVariable("USERPROFILE");
    private static readonly string EnvSystemDrive = Environment.GetEnvironmentVariable("SystemDrive");
    private static readonly string EnvWindows = Environment.GetEnvironmentVariable("windir");
    private static readonly string EnvProgramFiles = Environment.GetEnvironmentVariable("ProgramFiles");
    private static readonly string EnvProgramFilesX86 = Environment.GetEnvironmentVariable("ProgramFiles(x86)");
    private static readonly string EnvProgramData = Environment.GetEnvironmentVariable("ProgramData");

    private static string ReplaceIgnoreCase(string input, string search, string replacement) {
        if (string.IsNullOrEmpty(input) || string.IsNullOrEmpty(search)) return input;
        int found = input.IndexOf(search, StringComparison.OrdinalIgnoreCase);
        if (found < 0) return input;
        StringBuilder sb = new StringBuilder(input.Length + Math.Max(0, replacement.Length - search.Length) * 2);
        int cursor = 0;
        while (found >= 0) {
            sb.Append(input, cursor, found - cursor);
            sb.Append(replacement);
            cursor = found + search.Length;
            found = input.IndexOf(search, cursor, StringComparison.OrdinalIgnoreCase);
        }
        sb.Append(input, cursor, input.Length - cursor);
        return sb.ToString();
    }

    private static string ReplaceDriveRoot(string input, string drive, string replacement) {
        if (string.IsNullOrEmpty(input) || string.IsNullOrEmpty(drive)) return input;
        int cursor = 0;
        int copied = 0;
        StringBuilder sb = null;
        while (cursor < input.Length) {
            int found = input.IndexOf(drive, cursor, StringComparison.OrdinalIgnoreCase);
            if (found < 0) break;
            int after = found + drive.Length;
            if (after < input.Length && (input[after] == '\\' || input[after] == '/')) {
                if (sb == null) sb = new StringBuilder(input.Length + 16);
                sb.Append(input, copied, found - copied);
                sb.Append(replacement);
                copied = after;
            }
            cursor = after;
        }
        if (sb == null) return input;
        sb.Append(input, copied, input.Length - copied);
        return sb.ToString();
    }

    private static string SanitizeRegistryString(string input) {
        if (string.IsNullOrEmpty(input)) return input;
        string output = input;
        output = ReplaceIgnoreCase(output, EnvProgramFilesX86, "%ProgramFiles(x86)%");
        output = ReplaceIgnoreCase(output, EnvProgramFiles, "%ProgramFiles%");
        output = ReplaceIgnoreCase(output, EnvProgramData, "%ProgramData%");
        output = ReplaceIgnoreCase(output, UserDesktopPath, @"%USERPROFILE%\Desktop");
        output = ReplaceIgnoreCase(output, EnvUserProfile, "%USERPROFILE%");
        output = ReplaceIgnoreCase(output, EnvWindows, "%SystemRoot%");
        output = ReplaceDriveRoot(output, EnvSystemDrive, "%SystemDrive%");
        return output;
    }

    private string ParseValueData(RegistryKey key, string valName) {
        RegistryValueKind kind = key.GetValueKind(valName);
        object data = key.GetValue(valName, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
        if (data == null) throw new IOException("El valor de registro desaparecio durante el snapshot.");

            // Conversion y escritura en formato .REG. El saneamiento usa un
            // reemplazador ordinal cacheado; no crea Regex/lambdas por valor.
        switch (kind) {
                case RegistryValueKind.DWord:
                    return "dword:" + ((int)data).ToString("x8");

                // REG_QWORD serializado correctamente como hex(b) (little-endian de 8 bytes).
                // Sin este case, los valores QWORD (usados por Adobe, VS, JetBrains, etc.)
                // caian al default y se escribian como REG_SZ, corrompiendose al importar.
                case RegistryValueKind.QWord:
                    // RegistryKey devuelve REG_QWORD como Int64. La conversion
                    // unchecked conserva el patron binario aunque el bit alto este activo.
                    ulong qwordVal = unchecked((ulong)(long)data);
                    byte[] qBytes  = BitConverter.GetBytes(qwordVal);
                    return "hex(b):" + BitConverter.ToString(qBytes).Replace("-", ",").ToLower();

                case RegistryValueKind.String:
                case RegistryValueKind.ExpandString:
                    string originalString  = (string)data;
                    string sanitizedString = SanitizeRegistryString(originalString);

                    if (originalString != sanitizedString || kind == RegistryValueKind.ExpandString) {
                        byte[] strBytes = System.Text.Encoding.Unicode.GetBytes(sanitizedString);
                        return "hex(2):" + BitConverter.ToString(strBytes).Replace("-", ",").ToLower() + ",00,00";
                    }

                    // Los saltos de linea/NUL no son validos dentro de un literal
                    // entre comillas del formato .reg. REG_SZ binario evita partir la
                    // entrada en varias lineas y AdminImagenOffline reconoce hex(1).
                    if (sanitizedString.IndexOfAny(new char[] { '\r', '\n', '\0' }) >= 0) {
                        byte[] rawStringBytes = System.Text.Encoding.Unicode.GetBytes(sanitizedString);
                        return "hex(1):" + BitConverter.ToString(rawStringBytes).Replace("-", ",").ToLower() + ",00,00";
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
                        string safeStr = SanitizeRegistryString(str);
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
    }

    public void ScanRegistryTree(RegistryKey root, string currentPath) {
        if (IsRegExcluded(currentPath)) {
            Interlocked.Increment(ref RegistryMetrics.BranchesExcluded);
            return;
        }
        string absPath = root.Name + "\\" + currentPath;
        try {
            using (RegistryKey key = root.OpenSubKey(currentPath, false)) {
                if (key == null) {
                    RecordRegistryScanError(absPath);
                    return;
                }
                var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (string vName in key.GetValueNames()) {
                    if (IsRegistryValueExcluded(absPath, vName)) {
                        Interlocked.Increment(ref RegistryMetrics.ValuesExcluded);
                        continue;
                    }
                    try {
                        values[vName] = ParseValueData(key, vName);
                        Interlocked.Increment(ref RegistryMetrics.ValuesScanned);
                    } catch {
                        RecordRegistryScanError(absPath);
                        return;
                    }
                }
                RegSnapshot[absPath] = values;
                ReportRegistryProgress();

                foreach (string subKey in key.GetSubKeyNames()) {
                    ScanRegistryTree(root, currentPath + "\\" + subKey);
                }
            }
        } catch {
            RecordRegistryScanError(absPath);
        }
    }

    private string BuildRegistryScanSummaryLine(Stopwatch stopwatch,
                                                long baseKeys, long baseValues,
                                                long baseBranchesExcluded, long baseValuesExcluded,
                                                long baseErrors) {
        long keys = Math.Max(0L, Interlocked.Read(ref RegistryMetrics.KeysScanned) - baseKeys);
        long values = Math.Max(0L, Interlocked.Read(ref RegistryMetrics.ValuesScanned) - baseValues);
        long branchesExcluded = Math.Max(0L, Interlocked.Read(ref RegistryMetrics.BranchesExcluded) - baseBranchesExcluded);
        long valuesExcluded = Math.Max(0L, Interlocked.Read(ref RegistryMetrics.ValuesExcluded) - baseValuesExcluded);
        long errors = Math.Max(0L, Interlocked.Read(ref RegistryMetrics.Errors) - baseErrors);
        return string.Format("[+] {0:N0} claves | {1:N0} valores | ramas excl {2:N0} | valores omit {3:N0} | errores {4:N0} | {5}",
            keys, values, branchesExcluded, valuesExcluded, errors,
            FormatProgressElapsed(stopwatch.Elapsed, false));
    }

    private void WriteRegistryScanProgress(string label, Stopwatch stopwatch,
                                           long baseKeys, long baseValues,
                                           long baseBranchesExcluded, long baseValuesExcluded,
                                           long baseErrors, char spinner,
                                           ref int previousLineLength) {
        try {
            int width = Console.WindowWidth;
            if (width < 20) return;

            long keys = Math.Max(0L, Interlocked.Read(ref RegistryMetrics.KeysScanned) - baseKeys);
            long values = Math.Max(0L, Interlocked.Read(ref RegistryMetrics.ValuesScanned) - baseValues);
            long branchesExcluded = Math.Max(0L, Interlocked.Read(ref RegistryMetrics.BranchesExcluded) - baseBranchesExcluded);
            long valuesExcluded = Math.Max(0L, Interlocked.Read(ref RegistryMetrics.ValuesExcluded) - baseValuesExcluded);
            long errors = Math.Max(0L, Interlocked.Read(ref RegistryMetrics.Errors) - baseErrors);
            string suffix;

            if (width >= 140) {
                suffix = string.Format(" [{0}] {1:N0} claves | {2:N0} valores | excl {3:N0}/{4:N0} | errores {5:N0} | {6}",
                    spinner, keys, values, branchesExcluded, valuesExcluded, errors,
                    FormatProgressElapsed(stopwatch.Elapsed, false));
            } else if (width >= 100) {
                suffix = string.Format(" [{0}] C:{1:N0} V:{2:N0} X:{3:N0}/{4:N0} E:{5:N0} {6}",
                    spinner, keys, values, branchesExcluded, valuesExcluded, errors,
                    FormatProgressElapsed(stopwatch.Elapsed, false));
            } else {
                suffix = string.Format(" [{0}] C:{1:N0} V:{2:N0} E:{3:N0} {4}",
                    spinner, keys, values, errors, FormatProgressElapsed(stopwatch.Elapsed, true));
            }

            WriteScanProgressLine("Registro", label, suffix, ref previousLineLength);
        } catch {
            // La retroalimentacion es auxiliar: nunca debe interrumpir la captura.
        }
    }

    public void ScanRegistryTarget(RegistryKey root, string currentPath, string label) {
        Stopwatch sw = Stopwatch.StartNew();
        long baseKeys = Interlocked.Read(ref RegistryMetrics.KeysScanned);
        long baseValues = Interlocked.Read(ref RegistryMetrics.ValuesScanned);
        long baseBranchesExcluded = Interlocked.Read(ref RegistryMetrics.BranchesExcluded);
        long baseValuesExcluded = Interlocked.Read(ref RegistryMetrics.ValuesExcluded);
        long baseErrors = Interlocked.Read(ref RegistryMetrics.Errors);
        object progressSync = new object();
        Timer progressTimer = null;
        int progressStopped = 0;
        int spinnerIndex = 0;
        int previousLineLength = 0;
        char[] spinnerFrames = new char[] { '|', '/', '-', '\\' };
        string displayLabel = string.IsNullOrWhiteSpace(label) ? root.Name + "\\" + currentPath : label;

        try {
            if (CanRenderScanProgress()) {
                progressTimer = new Timer(delegate {
                    if (Interlocked.CompareExchange(ref progressStopped, 0, 0) != 0) return;
                    lock (progressSync) {
                        if (Interlocked.CompareExchange(ref progressStopped, 0, 0) != 0) return;
                        char frame = spinnerFrames[spinnerIndex++ % spinnerFrames.Length];
                        WriteRegistryScanProgress(displayLabel, sw, baseKeys, baseValues,
                                                  baseBranchesExcluded, baseValuesExcluded,
                                                  baseErrors, frame, ref previousLineLength);
                    }
                }, null, 500, 750);
            }

            ScanRegistryTree(root, currentPath);
        } finally {
            Interlocked.Exchange(ref progressStopped, 1);
            if (progressTimer != null) progressTimer.Dispose();
            lock (progressSync) { }

            sw.Stop();
            LastRegistryScanSummaryLine = BuildRegistryScanSummaryLine(sw, baseKeys, baseValues,
                baseBranchesExcluded, baseValuesExcluded, baseErrors);
            Interlocked.Add(ref RegistryMetrics.ElapsedMilliseconds, sw.ElapsedMilliseconds);

            if (CanRenderScanProgress()) {
                lock (progressSync) {
                    RestoreScanStatusLine("Registro", displayLabel, ref previousLineLength);
                }
            }
        }
    }

    private static bool IsRegistryPathUncertain(DiffEngine engine, string path) {
        foreach (string failedPath in engine.RegScanErrors) {
            if (path.Equals(failedPath, StringComparison.OrdinalIgnoreCase) ||
                path.StartsWith(failedPath + @"\", StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    private static bool IsRegistryPathUncertain(DiffEngine pre, DiffEngine post, string path) {
        return IsRegistryPathUncertain(pre, path) || IsRegistryPathUncertain(post, path);
    }

    private const string TaskCacheRegistryPrefix =
        @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache";
    private const string TaskCacheTasksRegistryPrefix =
        @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks";
    private const string TaskCacheTreeRegistryPrefix =
        @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree";
    private static readonly string[] HklmClassesClsidRegistryPrefixes = new string[] {
        @"HKEY_LOCAL_MACHINE\SOFTWARE\Classes\CLSID\",
        @"HKEY_LOCAL_MACHINE\SOFTWARE\Classes\WOW6432Node\CLSID\"
    };

    private static bool IsRegistryKeyAtOrBelow(string keyPath, string prefix) {
        return keyPath.Equals(prefix, StringComparison.OrdinalIgnoreCase) ||
               keyPath.StartsWith(prefix + @"\", StringComparison.OrdinalIgnoreCase);
    }

    private static bool TryGetDirectHklmClsidRoot(string keyPath, out string clsidRoot,
                                                   out string clsidToken) {
        clsidRoot = null;
        clsidToken = null;
        if (string.IsNullOrEmpty(keyPath)) return false;

        string matchedPrefix = null;
        foreach (string prefix in HklmClassesClsidRegistryPrefixes) {
            if (keyPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) {
                matchedPrefix = prefix;
                break;
            }
        }
        if (matchedPrefix == null) return false;

        string remainder = keyPath.Substring(matchedPrefix.Length);
        int separator = remainder.IndexOf('\\');
        string segment = separator >= 0 ? remainder.Substring(0, separator) : remainder;
        Guid parsed;
        if (string.IsNullOrEmpty(segment) || !Guid.TryParse(segment, out parsed)) return false;

        clsidRoot = matchedPrefix + segment;
        clsidToken = parsed.ToString("D");
        return true;
    }

    private static bool ContainsRegistryToken(string input, string token) {
        return !string.IsNullOrEmpty(input) && !string.IsNullOrEmpty(token) &&
               input.IndexOf(token, StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static bool HasNewOrModifiedRegistryReference(DiffEngine pre, DiffEngine post,
                                                           string token) {
        foreach (var postKey in post.RegSnapshot) {
            Dictionary<string, string> preValues;
            bool isNewKey = !pre.RegSnapshot.TryGetValue(postKey.Key, out preValues);
            bool keyReferencesToken = ContainsRegistryToken(postKey.Key, token);
            if (isNewKey && keyReferencesToken) return true;

            foreach (var postValue in postKey.Value) {
                string oldValue;
                bool isNewOrModified = isNewKey || preValues == null ||
                    !preValues.TryGetValue(postValue.Key, out oldValue) || oldValue != postValue.Value;
                if (!isNewOrModified) continue;
                if (keyReferencesToken || ContainsRegistryToken(postValue.Key, token) ||
                    ContainsRegistryToken(postValue.Value, token)) return true;
            }
        }
        return false;
    }

    private static bool HasNewOrModifiedRegistryReferenceOutsideRoot(DiffEngine pre, DiffEngine post,
                                                                      string token, string excludedRoot) {
        foreach (var postKey in post.RegSnapshot) {
            if (IsRegistryKeyAtOrBelow(postKey.Key, excludedRoot)) continue;

            Dictionary<string, string> preValues;
            bool isNewKey = !pre.RegSnapshot.TryGetValue(postKey.Key, out preValues);
            bool keyReferencesToken = ContainsRegistryToken(postKey.Key, token);
            if (isNewKey && keyReferencesToken) return true;

            foreach (var postValue in postKey.Value) {
                string oldValue;
                bool isNewOrModified = isNewKey || preValues == null ||
                    !preValues.TryGetValue(postValue.Key, out oldValue) || oldValue != postValue.Value;
                if (!isNewOrModified) continue;
                if (keyReferencesToken || ContainsRegistryToken(postValue.Key, token) ||
                    ContainsRegistryToken(postValue.Value, token)) return true;
            }
        }
        return false;
    }

    private static bool HasRegistryMutationBelowRoot(DiffEngine pre, DiffEngine post, string root) {
        string descendantPrefix = root + @"\";
        foreach (var postKey in post.RegSnapshot) {
            if (!postKey.Key.StartsWith(descendantPrefix, StringComparison.OrdinalIgnoreCase)) continue;
            Dictionary<string, string> preValues;
            if (!pre.RegSnapshot.TryGetValue(postKey.Key, out preValues)) return true;
            foreach (var postValue in postKey.Value) {
                string oldValue;
                if (!preValues.TryGetValue(postValue.Key, out oldValue) || oldValue != postValue.Value) return true;
            }
            foreach (var preValue in preValues) {
                if (!postKey.Value.ContainsKey(preValue.Key)) return true;
            }
        }
        foreach (var preKey in pre.RegSnapshot) {
            if (preKey.Key.StartsWith(descendantPrefix, StringComparison.OrdinalIgnoreCase) &&
                !post.RegSnapshot.ContainsKey(preKey.Key)) return true;
        }
        return false;
    }

    // Un CLSID nuevo o existente cuyo unico cambio directo es AppID, sin servidor
    // COM, referencia externa ni clave AppID correlacionada, no es atribuible con
    // seguridad al instalador. Se conserva para auditoria y no se exporta.
    private static bool IsUncorrelatedAppIdOnlyClsidMutation(DiffEngine pre, DiffEngine post,
                                                              string keyPath) {
        string clsidRoot;
        string clsidToken;
        if (!TryGetDirectHklmClsidRoot(keyPath, out clsidRoot, out clsidToken) ||
            !keyPath.Equals(clsidRoot, StringComparison.OrdinalIgnoreCase)) return false;

        Dictionary<string, string> postValues;
        if (!post.RegSnapshot.TryGetValue(keyPath, out postValues)) return false;
        Dictionary<string, string> preValues;
        pre.RegSnapshot.TryGetValue(keyPath, out preValues);

        bool appIdChanged = false;
        string appIdToken = null;
        foreach (var postValue in postValues) {
            string oldValue;
            bool changed = preValues == null || !preValues.TryGetValue(postValue.Key, out oldValue) ||
                           oldValue != postValue.Value;
            if (!changed) continue;
            if (!postValue.Key.Equals("AppID", StringComparison.OrdinalIgnoreCase)) return false;

            string decodedAppId;
            Guid parsedAppId;
            if (!TryDecodeQuotedRegistryString(postValue.Value, out decodedAppId) ||
                !Guid.TryParse(decodedAppId, out parsedAppId)) return false;
            appIdToken = parsedAppId.ToString("D");
            appIdChanged = true;
        }
        if (!appIdChanged) return false;

        if (preValues != null) {
            foreach (var preValue in preValues) {
                if (!postValues.ContainsKey(preValue.Key)) return false;
            }
        }
        if (HasRegistryMutationBelowRoot(pre, post, clsidRoot)) return false;
        if (HasNewOrModifiedRegistryReferenceOutsideRoot(pre, post, clsidToken, clsidRoot)) return false;
        if (HasNewOrModifiedRegistryReferenceOutsideRoot(pre, post, appIdToken, clsidRoot)) return false;
        return true;
    }

    private static string GetRegistryDeletionAuditRoot(string keyPath) {
        if (string.IsNullOrWhiteSpace(keyPath)) return null;
        foreach (string rawRoot in RegistryDeletionAuditPaths) {
            if (string.IsNullOrWhiteSpace(rawRoot)) continue;
            string root = rawRoot.Trim().TrimEnd('\\');
            if (IsRegistryKeyAtOrBelow(keyPath, root)) return root;
        }
        return null;
    }

    // Las altas y modificaciones COM/WINEVT correlacionadas siguen siendo
    // desplegables. Las eliminaciones completas de CLSID sin referencia y las
    // ramas declaradas por politica se conservan como evidencia auditOnly.
    public static List<string> GetAuditOnlyRegistryKeyDeletions(DiffEngine pre, DiffEngine post) {
        HashSet<string> candidates = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        Dictionary<string, string> tokens = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        HashSet<string> resultSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var preKey in pre.RegSnapshot) {
            if (post.RegSnapshot.ContainsKey(preKey.Key) ||
                IsRegistryPathUncertain(pre, post, preKey.Key)) continue;

            string policyRoot = GetRegistryDeletionAuditRoot(preKey.Key);
            if (!string.IsNullOrEmpty(policyRoot)) {
                // Si desaparecio la raiz declarada, una sola entrada representa
                // todo el arbol. Si la raiz sigue presente, conserva como
                // evidencia la rama descendiente realmente eliminada.
                if (pre.RegSnapshot.ContainsKey(policyRoot) &&
                    !post.RegSnapshot.ContainsKey(policyRoot) &&
                    !IsRegistryPathUncertain(pre, post, policyRoot)) {
                    resultSet.Add(policyRoot);
                } else {
                    resultSet.Add(preKey.Key);
                }
                continue;
            }

            string clsidRoot;
            string clsidToken;
            if (!TryGetDirectHklmClsidRoot(preKey.Key, out clsidRoot, out clsidToken) ||
                !pre.RegSnapshot.ContainsKey(clsidRoot) || post.RegSnapshot.ContainsKey(clsidRoot)) continue;
            candidates.Add(clsidRoot);
            tokens[clsidRoot] = clsidToken;
        }

        foreach (string clsidRoot in candidates) {
            if (!HasNewOrModifiedRegistryReference(pre, post, tokens[clsidRoot])) resultSet.Add(clsidRoot);
        }
        List<string> ordered = new List<string>(resultSet);
        ordered.Sort(StringComparer.OrdinalIgnoreCase);
        List<string> result = new List<string>();
        foreach (string path in ordered) {
            if (!IsAtOrBelowAnyRegistryKey(path, result)) result.Add(path);
        }
        return result;
    }

    private static bool IsAtOrBelowAnyRegistryKey(string keyPath, List<string> roots) {
        foreach (string root in roots) {
            if (IsRegistryKeyAtOrBelow(keyPath, root)) return true;
        }
        return false;
    }

    private static bool TryDecodeQuotedRegistryString(string serialized, out string value) {
        value = null;
        if (string.IsNullOrEmpty(serialized) || serialized.Length < 2 ||
            serialized[0] != '"' || serialized[serialized.Length - 1] != '"') return false;

        StringBuilder decoded = new StringBuilder(serialized.Length - 2);
        for (int i = 1; i < serialized.Length - 1; i++) {
            char current = serialized[i];
            if (current == '\\' && i + 1 < serialized.Length - 1) {
                decoded.Append(serialized[++i]);
            } else {
                decoded.Append(current);
            }
        }
        value = decoded.ToString();
        return true;
    }

    private static bool TryDecodeHexRegistryString(string serialized, out string value) {
        value = null;
        if (string.IsNullOrEmpty(serialized)) return false;

        string prefix;
        if (serialized.StartsWith("hex(1):", StringComparison.OrdinalIgnoreCase)) {
            prefix = "hex(1):";
        } else if (serialized.StartsWith("hex(2):", StringComparison.OrdinalIgnoreCase)) {
            prefix = "hex(2):";
        } else {
            return false;
        }

        string payload = serialized.Substring(prefix.Length);
        if (payload.Length == 0) {
            value = string.Empty;
            return true;
        }

        string[] tokens = payload.Split(new char[] { ',' }, StringSplitOptions.RemoveEmptyEntries);
        byte[] bytes = new byte[tokens.Length];
        try {
            for (int i = 0; i < tokens.Length; i++) {
                bytes[i] = Convert.ToByte(tokens[i].Trim(), 16);
            }
        } catch {
            return false;
        }

        if ((bytes.Length % 2) != 0) return false;
        value = Encoding.Unicode.GetString(bytes).TrimEnd('\0');
        return true;
    }

    private static bool TryDecodeSerializedRegistryString(string serialized, out string value) {
        return TryDecodeQuotedRegistryString(serialized, out value) ||
               TryDecodeHexRegistryString(serialized, out value);
    }

    private static bool TryGetRegistryStringValue(Dictionary<string, string> values,
                                                   string valueName, out string value) {
        value = null;
        if (values == null) return false;
        string serialized;
        return values.TryGetValue(valueName, out serialized) &&
               TryDecodeSerializedRegistryString(serialized, out value);
    }

    private static bool TryNormalizeTaskRelativePath(string taskPath, out string relativeTaskPath) {
        relativeTaskPath = null;
        if (string.IsNullOrWhiteSpace(taskPath)) return false;
        string normalized = Environment.ExpandEnvironmentVariables(taskPath).Replace('/', '\\').Trim();
        string windowsDirectory = Environment.GetEnvironmentVariable("WINDIR");
        if (string.IsNullOrWhiteSpace(windowsDirectory)) {
            windowsDirectory = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        }
        if (string.IsNullOrWhiteSpace(windowsDirectory)) return false;

        string taskRoot = Path.Combine(windowsDirectory, "System32", "Tasks").TrimEnd('\\') + @"\";
        bool hasDriveRoot = normalized.Length >= 3 && Char.IsLetter(normalized[0]) &&
                            normalized[1] == ':' && normalized[2] == '\\';
        if (hasDriveRoot) {
            if (!normalized.StartsWith(taskRoot, StringComparison.OrdinalIgnoreCase)) return false;
            normalized = normalized.Substring(taskRoot.Length);
        } else {
            // TaskCache guarda normalmente rutas logicas como \Microsoft\Office\Tarea.
            // Esa barra inicial no es una raiz de disco y debe retirarse. Una ruta UNC,
            // en cambio, nunca es una ruta valida dentro de System32\Tasks.
            if (normalized.StartsWith(@"\\", StringComparison.Ordinal)) return false;
            normalized = normalized.TrimStart('\\');
        }
        if (string.IsNullOrWhiteSpace(normalized) || normalized.EndsWith(@"\", StringComparison.Ordinal)) return false;
        string[] taskSegments = normalized.Split(new char[] { '\\' }, StringSplitOptions.None);
        foreach (string segment in taskSegments) {
            if (string.IsNullOrEmpty(segment) || segment.Equals(".", StringComparison.Ordinal) ||
                segment.Equals("..", StringComparison.Ordinal) || segment.IndexOf(':') >= 0) return false;
        }
        relativeTaskPath = normalized;
        return true;
    }

    private static bool TryGetCorrelatedNewScheduledTask(DiffEngine pre, DiffEngine post,
                                                          string taskKeyPath,
                                                          out string treeKeyPath,
                                                          out string taskFilePath) {
        treeKeyPath = null;
        taskFilePath = null;
        string taskPrefix = TaskCacheTasksRegistryPrefix + @"\";
        if (!taskKeyPath.StartsWith(taskPrefix, StringComparison.OrdinalIgnoreCase) ||
            pre.RegSnapshot.ContainsKey(taskKeyPath)) return false;

        string taskId = taskKeyPath.Substring(taskPrefix.Length);
        if (string.IsNullOrEmpty(taskId) || taskId.IndexOf('\\') >= 0) return false;

        Dictionary<string, string> taskValues;
        string taskPath;
        if (!post.RegSnapshot.TryGetValue(taskKeyPath, out taskValues) ||
            !TryGetRegistryStringValue(taskValues, "Path", out taskPath) ||
            string.IsNullOrWhiteSpace(taskPath)) return false;

        string relativeTaskPath;
        if (!TryNormalizeTaskRelativePath(taskPath, out relativeTaskPath)) return false;
        treeKeyPath = TaskCacheTreeRegistryPrefix + @"\" + relativeTaskPath;
        if (pre.RegSnapshot.ContainsKey(treeKeyPath)) return false;

        Dictionary<string, string> treeValues;
        string treeTaskId;
        if (!post.RegSnapshot.TryGetValue(treeKeyPath, out treeValues) ||
            !TryGetRegistryStringValue(treeValues, "Id", out treeTaskId) ||
            !string.Equals(taskId, treeTaskId, StringComparison.OrdinalIgnoreCase)) return false;

        string windowsDirectory = Environment.GetEnvironmentVariable("WINDIR");
        if (string.IsNullOrWhiteSpace(windowsDirectory)) {
            windowsDirectory = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        }
        if (string.IsNullOrWhiteSpace(windowsDirectory)) return false;

        taskFilePath = Path.Combine(windowsDirectory, "System32", "Tasks", relativeTaskPath);
        string postFingerprint;
        if (!post.FileSnapshot.TryGetValue(taskFilePath, out postFingerprint) ||
            string.IsNullOrEmpty(postFingerprint) || IsDirectoryFingerprint(postFingerprint)) return false;

        string preFingerprint;
        return !pre.FileSnapshot.TryGetValue(taskFilePath, out preFingerprint) ||
               !AreFileFingerprintsEquivalent(preFingerprint, postFingerprint);
    }

    private static bool TryGetCorrelatedScheduledTaskMutation(DiffEngine pre, DiffEngine post,
                                                               string taskKeyPath,
                                                               out string treeKeyPath,
                                                               out string taskFilePath) {
        treeKeyPath = null;
        taskFilePath = null;
        string taskPrefix = TaskCacheTasksRegistryPrefix + @"\";
        if (!taskKeyPath.StartsWith(taskPrefix, StringComparison.OrdinalIgnoreCase)) return false;

        string taskId = taskKeyPath.Substring(taskPrefix.Length);
        if (string.IsNullOrEmpty(taskId) || taskId.IndexOf('\\') >= 0) return false;

        Dictionary<string, string> taskValues;
        string taskPath;
        if (!post.RegSnapshot.TryGetValue(taskKeyPath, out taskValues) ||
            !TryGetRegistryStringValue(taskValues, "Path", out taskPath) ||
            string.IsNullOrWhiteSpace(taskPath)) return false;

        string relativeTaskPath;
        if (!TryNormalizeTaskRelativePath(taskPath, out relativeTaskPath)) return false;
        treeKeyPath = TaskCacheTreeRegistryPrefix + @"\" + relativeTaskPath;
        Dictionary<string, string> treeValues;
        string treeTaskId;
        if (!post.RegSnapshot.TryGetValue(treeKeyPath, out treeValues) ||
            !TryGetRegistryStringValue(treeValues, "Id", out treeTaskId) ||
            !string.Equals(taskId, treeTaskId, StringComparison.OrdinalIgnoreCase)) return false;

        string windowsDirectory = Environment.GetEnvironmentVariable("WINDIR");
        if (string.IsNullOrWhiteSpace(windowsDirectory)) {
            windowsDirectory = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        }
        if (string.IsNullOrWhiteSpace(windowsDirectory)) return false;

        taskFilePath = Path.Combine(windowsDirectory, "System32", "Tasks", relativeTaskPath);
        string postFingerprint;
        if (!post.FileSnapshot.TryGetValue(taskFilePath, out postFingerprint) ||
            string.IsNullOrEmpty(postFingerprint) || IsDirectoryFingerprint(postFingerprint)) return false;

        string preFingerprint;
        return !pre.FileSnapshot.TryGetValue(taskFilePath, out preFingerprint) ||
               !AreFileFingerprintsEquivalent(preFingerprint, postFingerprint);
    }

    private static bool TryGetTaskCacheIndexTaskId(string keyPath, out string taskId) {
        taskId = null;
        string prefix = TaskCacheRegistryPrefix + @"\";
        if (!keyPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return false;

        string remainder = keyPath.Substring(prefix.Length);
        string[] segments = remainder.Split(new char[] { '\\' }, StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length != 2 ||
            segments[0].Equals("Tasks", StringComparison.OrdinalIgnoreCase) ||
            segments[0].Equals("Tree", StringComparison.OrdinalIgnoreCase)) return false;

        Guid parsedTaskId;
        if (!Guid.TryParse(segments[1], out parsedTaskId)) return false;
        taskId = segments[1];
        return true;
    }

    private static bool IsCorrelatedNewTaskCacheIndexKey(DiffEngine pre, DiffEngine post,
                                                          string indexKeyPath) {
        string taskId;
        if (pre.RegSnapshot.ContainsKey(indexKeyPath) ||
            !TryGetTaskCacheIndexTaskId(indexKeyPath, out taskId)) return false;

        string correlatedTree;
        string correlatedFile;
        return TryGetCorrelatedNewScheduledTask(pre, post,
            TaskCacheTasksRegistryPrefix + @"\" + taskId,
            out correlatedTree, out correlatedFile);
    }

    private static bool IsCorrelatedNewTaskTreeKey(DiffEngine pre, DiffEngine post,
                                                    string treeKeyPath) {
        if (!IsRegistryKeyAtOrBelow(treeKeyPath, TaskCacheTreeRegistryPrefix) ||
            pre.RegSnapshot.ContainsKey(treeKeyPath)) return false;

        Dictionary<string, string> values;
        string taskId;
        if (post.RegSnapshot.TryGetValue(treeKeyPath, out values) &&
            TryGetRegistryStringValue(values, "Id", out taskId)) {
            string correlatedTree;
            string correlatedFile;
            return TryGetCorrelatedNewScheduledTask(pre, post,
                TaskCacheTasksRegistryPrefix + @"\" + taskId,
                out correlatedTree, out correlatedFile) &&
                string.Equals(correlatedTree, treeKeyPath, StringComparison.OrdinalIgnoreCase);
        }

        string descendantPrefix = treeKeyPath + @"\";
        foreach (var candidate in post.RegSnapshot) {
            if (!candidate.Key.StartsWith(descendantPrefix, StringComparison.OrdinalIgnoreCase) ||
                pre.RegSnapshot.ContainsKey(candidate.Key) ||
                !TryGetRegistryStringValue(candidate.Value, "Id", out taskId)) continue;

            string correlatedTree;
            string correlatedFile;
            if (TryGetCorrelatedNewScheduledTask(pre, post,
                    TaskCacheTasksRegistryPrefix + @"\" + taskId,
                    out correlatedTree, out correlatedFile) &&
                correlatedTree.StartsWith(descendantPrefix, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    private static bool ShouldExportTaskCachePostKey(DiffEngine pre, DiffEngine post,
                                                      string keyPath, bool isNewKey) {
        if (!IsRegistryKeyAtOrBelow(keyPath, TaskCacheRegistryPrefix)) return true;

        if (IsRegistryKeyAtOrBelow(keyPath, TaskCacheTasksRegistryPrefix)) {
            string correlatedTree;
            string correlatedFile;
            return TryGetCorrelatedScheduledTaskMutation(pre, post, keyPath,
                out correlatedTree, out correlatedFile);
        }
        if (IsRegistryKeyAtOrBelow(keyPath, TaskCacheTreeRegistryPrefix)) {
            Dictionary<string, string> values;
            string taskId;
            if (post.RegSnapshot.TryGetValue(keyPath, out values) &&
                TryGetRegistryStringValue(values, "Id", out taskId)) {
                string correlatedTree;
                string correlatedFile;
                return TryGetCorrelatedScheduledTaskMutation(pre, post,
                    TaskCacheTasksRegistryPrefix + @"\" + taskId,
                    out correlatedTree, out correlatedFile) &&
                    string.Equals(correlatedTree, keyPath, StringComparison.OrdinalIgnoreCase);
            }

            string descendantPrefix = keyPath + @"\";
            foreach (var candidate in post.RegSnapshot) {
                if (!candidate.Key.StartsWith(descendantPrefix, StringComparison.OrdinalIgnoreCase) ||
                    !TryGetRegistryStringValue(candidate.Value, "Id", out taskId)) continue;
                string correlatedTree;
                string correlatedFile;
                if (TryGetCorrelatedScheduledTaskMutation(pre, post,
                        TaskCacheTasksRegistryPrefix + @"\" + taskId,
                        out correlatedTree, out correlatedFile) &&
                    correlatedTree.StartsWith(descendantPrefix, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }
        string indexTaskId;
        if (!TryGetTaskCacheIndexTaskId(keyPath, out indexTaskId)) return false;
        string indexTree;
        string indexFile;
        return TryGetCorrelatedScheduledTaskMutation(pre, post,
            TaskCacheTasksRegistryPrefix + @"\" + indexTaskId,
            out indexTree, out indexFile);
    }

    private static bool HasRegistryMutationAtKey(DiffEngine pre, DiffEngine post, string keyPath) {
        Dictionary<string, string> postValues;
        if (!post.RegSnapshot.TryGetValue(keyPath, out postValues)) return false;
        Dictionary<string, string> preValues;
        if (!pre.RegSnapshot.TryGetValue(keyPath, out preValues)) return true;
        foreach (var value in postValues) {
            string oldValue;
            if (!preValues.TryGetValue(value.Key, out oldValue) || oldValue != value.Value) return true;
        }
        foreach (var value in preValues) {
            if (!postValues.ContainsKey(value.Key)) return true;
        }
        return false;
    }

    public static List<string> GetAuditOnlyRegistryMutations(DiffEngine pre, DiffEngine post) {
        List<string> result = new List<string>();
        foreach (var postKey in post.RegSnapshot) {
            if (IsRegistryPathUncertain(pre, post, postKey.Key)) continue;
            bool isNewKey = !pre.RegSnapshot.ContainsKey(postKey.Key);

            if (IsRegistryKeyAtOrBelow(postKey.Key, TaskCacheRegistryPrefix) &&
                HasRegistryMutationAtKey(pre, post, postKey.Key) &&
                !ShouldExportTaskCachePostKey(pre, post, postKey.Key, isNewKey)) {
                result.Add("TaskCache no correlacionado: " + postKey.Key);
            }
            if (IsUncorrelatedAppIdOnlyClsidMutation(pre, post, postKey.Key)) {
                result.Add("COM AppID no correlacionado: " + postKey.Key);
            }
        }
        foreach (var preKey in pre.RegSnapshot) {
            if (IsRegistryKeyAtOrBelow(preKey.Key, TaskCacheRegistryPrefix) &&
                !post.RegSnapshot.ContainsKey(preKey.Key) &&
                !IsRegistryPathUncertain(pre, post, preKey.Key)) {
                result.Add("TaskCache eliminado (solo auditoria): " + preKey.Key);
            }
        }
        result.Sort(StringComparer.OrdinalIgnoreCase);
        return result;
    }

    // --- Motor Diferencial Completo (Nuevas, Modificadas y ELIMINADAS) ---
    public static void GenerateRegFile(DiffEngine pre, DiffEngine post, string outputPath) {
        List<string> auditOnlyKeyDeletions = GetAuditOnlyRegistryKeyDeletions(pre, post);
        using (StreamWriter writer = new StreamWriter(outputPath, false, System.Text.Encoding.Unicode)) {
            writer.WriteLine("Windows Registry Editor Version 5.00");
            writer.WriteLine("; ==================================================");
            writer.WriteLine("; Generado por DeltaPack Dual-Engine");
            writer.WriteLine("; ==================================================");

            // 1. Procesar Claves Nuevas, Modificadas y Valores Eliminados
            foreach (var postKey in post.RegSnapshot) {
                string keyPath = postKey.Key;
                if (IsRegistryPathUncertain(pre, post, keyPath)) continue;
                bool isNewKey = !pre.RegSnapshot.ContainsKey(keyPath);
                if (!ShouldExportTaskCachePostKey(pre, post, keyPath, isNewKey)) continue;
                if (IsUncorrelatedAppIdOnlyClsidMutation(pre, post, keyPath)) continue;
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
                if (IsRegistryPathUncertain(pre, post, preKey.Key)) continue;
                if (IsRegistryKeyAtOrBelow(preKey.Key, TaskCacheRegistryPrefix)) continue;
                if (IsAtOrBelowAnyRegistryKey(preKey.Key, auditOnlyKeyDeletions)) continue;
                if (!post.RegSnapshot.ContainsKey(preKey.Key)) {
                    writer.WriteLine("\n[-" + preKey.Key + "]");
                }
            }
        }
    }

    // --- MOTOR ARCHIVOS ---
    // ConcurrentDictionary permite escritura segura desde los hilos paralelos
    // de ScanDirectoryParallel y lectura concurrente durante el diferencial.
    public ConcurrentDictionary<string, string> FileSnapshot = new ConcurrentDictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    // Los reparse points requieren recrear tipo y destino mediante APIs NTFS;
    // no deben desaparecer silenciosamente del resultado. El descriptor RP1
    // conserva el buffer NTFS completo para poder reproducir tags de Microsoft,
    // junctions y symlinks sin convertirlos en archivos ordinarios.
    public ConcurrentDictionary<string, string> ReparsePointSnapshot = new ConcurrentDictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    public class ReparsePointChange {
        public string Operation = "";
        public string Path = "";
        public string Kind = "";
        public string Tag = "";
        public string DescriptorSha256 = "";
        public string Descriptor = "";
        public bool Reproducible = false;
        public string Reason = "";
    }

    public class ReparseCopyResult {
        public string Tag = "";
        public string DescriptorSha256 = "";
        public bool IsDirectory = false;
        public bool MetadataPreserved = true;
        public string MetadataWarning = "";
    }

    // Archivos o subarboles que no pudieron leerse. El diferencial omite estas
    // rutas en lugar de asumir que fueron creadas, modificadas o eliminadas.
    public ConcurrentDictionary<string, byte> FileScanUncertainPaths = new ConcurrentDictionary<string, byte>(StringComparer.OrdinalIgnoreCase);
    public ConcurrentDictionary<string, string> FileScanFailureDetails = new ConcurrentDictionary<string, string>(StringComparer.OrdinalIgnoreCase);

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
        public long FilesVerifiedByUsn = 0;
        public long FilesRecoveredByVss = 0;
        public long FilesWithUsn = 0;
        public long FilesUsnFallback = 0;
        public long FilesByMetadata = 0;
        public long FilesFallbackSize = 0;
        public long FilesSkippedByExclusion = 0;
        public long FilesSkippedByReparsePoint = 0;
        public long FilesSkippedByAccessDenied = 0;
        public long FilesSkippedByIoError = 0;
        public long FilesSkippedByOtherError = 0;

        public long HashBytesRead = 0;
        public long HashBytesAvoidedByUsn = 0;
        public long ElapsedMilliseconds = 0;

        public long FilesFingerprinted {
            get { return FilesHashed + FilesVerifiedByUsn + FilesByMetadata + FilesFallbackSize; }
        }
        public long FilesSkipped {
            get { return FilesSkippedByExclusion + FilesSkippedByReparsePoint + FilesSkippedByAccessDenied + FilesSkippedByIoError + FilesSkippedByOtherError; }
        }
        public long DirectoriesSkipped {
            get { return DirectoriesSkippedByExclusion + DirectoriesSkippedByReparsePoint + DirectoriesSkippedByAccessDenied + DirectoriesSkippedByIoError + DirectoriesSkippedByOtherError; }
        }
    }

    public FileScanMetrics ScanMetrics = new FileScanMetrics();
    public string LastScanSummaryLine = "";

    public void ResetScanMetrics() {
        ScanMetrics = new FileScanMetrics();
    }

    public static long HashThresholdBytes = 512 * 1024L;
    public static bool HashAllFiles = true; // Fidelidad offline: SHA256 sin limite de tamano.
    public static bool UseUsnOptimization = true;
    public static int FileScanMaxAttempts = 3;
    public static int FileScanRetryDelayMilliseconds = 200;
    public static string VssFallbackDrive = "";
    public static string VssFallbackDeviceObject = "";
    private const int HashBufferSize = 1024 * 1024;

    // En el snapshot final apunta al motor base. Solo se reutiliza un SHA256 si
    // el sello USN completo coincide; de lo contrario se relee el archivo.
    public DiffEngine BaselineForReuse = null;

    public static int MaxScanParallelism = 0;

    public static int GetEffectiveParallelism() {
        int dop = MaxScanParallelism;
        if (dop <= 0) dop = Math.Min(4, Environment.ProcessorCount);
        if (dop < 1) dop = 1;
        return dop;
    }

    private bool IsFileExcluded(string path) {
        if (string.IsNullOrEmpty(path)) return true;
        if (PreparedFileExclusionCount != FileExclusions.Count) PrepareExclusionMatchers();

        foreach (string extension in PreparedFileExtensionRules) {
            if (path.EndsWith(extension, StringComparison.OrdinalIgnoreCase)) return true;
        }
        foreach (string subtree in PreparedFileSubtreeRules) {
            int matchIndex = path.IndexOf(subtree, StringComparison.OrdinalIgnoreCase);
            while (matchIndex >= 0) {
                int matchEnd = matchIndex + subtree.Length;
                if (matchEnd == path.Length || path[matchEnd] == '\\' || path[matchEnd] == '/') return true;
                matchIndex = path.IndexOf(subtree, matchIndex + 1, StringComparison.OrdinalIgnoreCase);
            }
        }
        foreach (string fragment in PreparedFileFragmentRules) {
            if (path.IndexOf(fragment, StringComparison.OrdinalIgnoreCase) >= 0) return true;
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

    public static bool IsDirectoryFingerprint(string fingerprint) {
        return !string.IsNullOrEmpty(fingerprint) &&
               (fingerprint.Equals("DIR", StringComparison.Ordinal) ||
                fingerprint.StartsWith("DIR;", StringComparison.Ordinal));
    }

    private string ComputeDirectoryFingerprint(string path) {
        try {
            DirectoryInfo info = new DirectoryInfo(path);
            string securityHash;
            DirectorySecurity security = info.GetAccessControl(
                AccessControlSections.Access | AccessControlSections.Owner | AccessControlSections.Group);
            byte[] descriptor = security.GetSecurityDescriptorBinaryForm();
            using (SHA256 sha = SHA256.Create()) {
                securityHash = BitConverter.ToString(sha.ComputeHash(descriptor)).Replace("-", "").ToLowerInvariant();
            }
            return "DIR;CT:" + info.CreationTimeUtc.Ticks +
                   ";WT:" + info.LastWriteTimeUtc.Ticks +
                   ";ATTR:" + ((int)info.Attributes).ToString() +
                   ";SD:" + securityHash;
        } catch (Exception ex) {
            RecordFileScanFailure(path, ex, true);
            return string.Empty;
        }
    }

    private const uint GENERIC_READ = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const uint FSCTL_GET_REPARSE_POINT = 0x000900A8;
    private const uint FSCTL_SET_REPARSE_POINT = 0x000900A4;
    private const uint FSCTL_QUERY_USN_JOURNAL = 0x000900F4;
    private const uint FSCTL_READ_FILE_USN_DATA = 0x000900EB;
    private const int MAX_REPARSE_BUFFER_SIZE = 16 * 1024;
    private const uint TOKEN_QUERY = 0x0008;
    private const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    private const uint SE_PRIVILEGE_ENABLED = 0x00000002;
    private const int ERROR_NOT_ALL_ASSIGNED = 1300;

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID_AND_ATTRIBUTES {
        public LUID Luid;
        public uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_PRIVILEGES {
        public uint PrivilegeCount;
        public LUID_AND_ATTRIBUTES Privileges;
    }

    public class PrivilegeEnableResult {
        public string Name = "";
        public bool Enabled = false;
        public int ErrorCode = 0;
        public string Message = "";
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(
        IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool LookupPrivilegeValue(
        string systemName, string name, out LUID luid);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AdjustTokenPrivileges(
        IntPtr tokenHandle, bool disableAllPrivileges,
        ref TOKEN_PRIVILEGES newState, int bufferLength,
        IntPtr previousState, IntPtr returnLength);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll")]
    private static extern void SetLastError(uint errorCode);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes,
        uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetVolumeInformation(
        string rootPathName, StringBuilder volumeNameBuffer, uint volumeNameSize,
        out uint volumeSerialNumber, out uint maximumComponentLength,
        out uint fileSystemFlags, StringBuilder fileSystemNameBuffer, uint fileSystemNameSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(
        SafeFileHandle device, uint controlCode, IntPtr inBuffer, int inBufferSize,
        byte[] outBuffer, int outBufferSize, out int bytesReturned, IntPtr overlapped);

    [DllImport("kernel32.dll", EntryPoint = "DeviceIoControl", SetLastError = true)]
    private static extern bool DeviceIoControlSet(
        SafeFileHandle device, uint controlCode, byte[] inBuffer, int inBufferSize,
        IntPtr outBuffer, int outBufferSize, out int bytesReturned, IntPtr overlapped);

    private static PrivilegeEnableResult EnableProcessPrivilege(string privilegeName) {
        PrivilegeEnableResult result = new PrivilegeEnableResult();
        result.Name = privilegeName ?? "";

        IntPtr tokenHandle = IntPtr.Zero;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES,
                              out tokenHandle)) {
            result.ErrorCode = Marshal.GetLastWin32Error();
            result.Message = "No se pudo abrir el token del proceso.";
            return result;
        }

        try {
            LUID luid;
            if (!LookupPrivilegeValue(null, privilegeName, out luid)) {
                result.ErrorCode = Marshal.GetLastWin32Error();
                result.Message = "El privilegio no existe o no pudo resolverse.";
                return result;
            }

            TOKEN_PRIVILEGES state = new TOKEN_PRIVILEGES();
            state.PrivilegeCount = 1;
            state.Privileges = new LUID_AND_ATTRIBUTES();
            state.Privileges.Luid = luid;
            state.Privileges.Attributes = SE_PRIVILEGE_ENABLED;

            SetLastError(0);
            bool adjusted = AdjustTokenPrivileges(tokenHandle, false, ref state, 0,
                                                   IntPtr.Zero, IntPtr.Zero);
            int error = Marshal.GetLastWin32Error();
            if (!adjusted) {
                result.ErrorCode = error;
                result.Message = "AdjustTokenPrivileges fallo.";
                return result;
            }
            if (error == ERROR_NOT_ALL_ASSIGNED) {
                result.ErrorCode = error;
                result.Message = "El token no contiene el privilegio solicitado.";
                return result;
            }
            if (error != 0) {
                result.ErrorCode = error;
                result.Message = "Windows no confirmo la habilitacion del privilegio.";
                return result;
            }

            result.Enabled = true;
            result.Message = "Habilitado";
            return result;
        } finally {
            if (tokenHandle != IntPtr.Zero) CloseHandle(tokenHandle);
        }
    }

    public static PrivilegeEnableResult[] EnableRequiredCapturePrivileges() {
        string[] required = new string[] {
            "SeBackupPrivilege",
            "SeRestorePrivilege",
            "SeCreateSymbolicLinkPrivilege"
        };
        List<PrivilegeEnableResult> results = new List<PrivilegeEnableResult>();
        foreach (string privilegeName in required) {
            results.Add(EnableProcessPrivilege(privilegeName));
        }
        return results.ToArray();
    }

    private static byte[] ReadRawReparsePoint(string path) {
        uint flags = FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS;
        using (SafeFileHandle handle = CreateFile(path, 0,
                   FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                   IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero)) {
            if (handle == null || handle.IsInvalid) {
                throw new IOException("No se pudo abrir el reparse point. Win32=" + Marshal.GetLastWin32Error());
            }

            byte[] buffer = new byte[MAX_REPARSE_BUFFER_SIZE];
            int bytesReturned;
            if (!DeviceIoControl(handle, FSCTL_GET_REPARSE_POINT, IntPtr.Zero, 0,
                                 buffer, buffer.Length, out bytesReturned, IntPtr.Zero)) {
                throw new IOException("FSCTL_GET_REPARSE_POINT fallo. Win32=" + Marshal.GetLastWin32Error());
            }
            if (bytesReturned < 8 || bytesReturned > buffer.Length) {
                throw new InvalidDataException("Descriptor de reparse point con longitud invalida: " + bytesReturned);
            }

            int declaredLength = BitConverter.ToUInt16(buffer, 4) + 8;
            if (declaredLength < 8 || declaredLength > bytesReturned) {
                throw new InvalidDataException("Descriptor de reparse point truncado.");
            }

            byte[] exact = new byte[declaredLength];
            Buffer.BlockCopy(buffer, 0, exact, 0, declaredLength);
            return exact;
        }
    }

    private static string GetSha256Hex(byte[] data) {
        using (SHA256 sha = SHA256.Create()) {
            return BitConverter.ToString(sha.ComputeHash(data)).Replace("-", "").ToLowerInvariant();
        }
    }

    private static string BuildReparseDescriptor(string path, bool isDirectory) {
        byte[] raw = ReadRawReparsePoint(path);
        uint tag = BitConverter.ToUInt32(raw, 0);
        return "RP1;KIND:" + (isDirectory ? "DIR" : "FILE") +
               ";TAG:0x" + tag.ToString("X8") +
               ";DATA:" + Convert.ToBase64String(raw);
    }

    private static bool TryParseReparseDescriptor(string descriptor, out bool isDirectory,
                                                   out uint tag, out byte[] raw,
                                                   out string reason) {
        isDirectory = false;
        tag = 0;
        raw = null;
        reason = "";
        if (string.IsNullOrEmpty(descriptor) ||
            !descriptor.StartsWith("RP1;", StringComparison.Ordinal)) {
            reason = "El snapshot no contiene un descriptor RP1 reproducible.";
            return false;
        }

        string[] fields = descriptor.Split(new char[] { ';' }, StringSplitOptions.RemoveEmptyEntries);
        string kindValue = null;
        string tagValue = null;
        string dataValue = null;
        foreach (string field in fields) {
            if (field.StartsWith("KIND:", StringComparison.Ordinal)) kindValue = field.Substring(5);
            else if (field.StartsWith("TAG:", StringComparison.Ordinal)) tagValue = field.Substring(4);
            else if (field.StartsWith("DATA:", StringComparison.Ordinal)) dataValue = field.Substring(5);
        }

        if (kindValue == "DIR") isDirectory = true;
        else if (kindValue == "FILE") isDirectory = false;
        else {
            reason = "Tipo de reparse point invalido.";
            return false;
        }

        if (string.IsNullOrEmpty(tagValue) || !tagValue.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ||
            !UInt32.TryParse(tagValue.Substring(2), System.Globalization.NumberStyles.HexNumber,
                            System.Globalization.CultureInfo.InvariantCulture, out tag)) {
            reason = "Tag de reparse point invalido.";
            return false;
        }

        try { raw = Convert.FromBase64String(dataValue ?? ""); }
        catch {
            reason = "Buffer base64 del reparse point invalido.";
            return false;
        }

        if (raw.Length < 8 || raw.Length > MAX_REPARSE_BUFFER_SIZE ||
            BitConverter.ToUInt32(raw, 0) != tag ||
            BitConverter.ToUInt16(raw, 4) + 8 != raw.Length) {
            reason = "Buffer NTFS del reparse point inconsistente.";
            return false;
        }
        return true;
    }

    private void RecordReparsePoint(string path, bool isDirectory) {
        if (string.IsNullOrEmpty(path)) return;
        try {
            ReparsePointSnapshot[path] = BuildReparseDescriptor(path, isDirectory);
        } catch (Exception ex) {
            ReparsePointSnapshot[path] = "UNREADABLE;KIND:" + (isDirectory ? "DIR" : "FILE") +
                                         ";ERROR:" + ex.GetType().Name;
            FileScanUncertainPaths[path] = 0;
        }
    }

    public static ReparseCopyResult CopyReparsePoint(string sourcePath, string destPath,
                                                      string expectedDescriptor) {
        bool isDirectory;
        uint expectedTag;
        byte[] expectedRaw;
        string reason;
        if (!TryParseReparseDescriptor(expectedDescriptor, out isDirectory, out expectedTag,
                                       out expectedRaw, out reason)) {
            throw new InvalidDataException(reason);
        }

        FileAttributes sourceAttributes = File.GetAttributes(sourcePath);
        bool sourceIsDirectory = (sourceAttributes & FileAttributes.Directory) == FileAttributes.Directory;
        if ((sourceAttributes & FileAttributes.ReparsePoint) != FileAttributes.ReparsePoint ||
            sourceIsDirectory != isDirectory) {
            throw new IOException("El tipo del reparse point cambio despues del snapshot final.");
        }

        string currentDescriptor = BuildReparseDescriptor(sourcePath, isDirectory);
        if (!string.Equals(currentDescriptor, expectedDescriptor, StringComparison.Ordinal)) {
            throw new IOException("El reparse point cambio despues del snapshot final.");
        }

        string parent = Path.GetDirectoryName(destPath);
        if (!string.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);
        if (File.Exists(destPath) || Directory.Exists(destPath)) {
            throw new IOException("El destino del reparse point ya existe: " + destPath);
        }

        if (isDirectory) {
            Directory.CreateDirectory(destPath);
        } else {
            using (FileStream placeholder = new FileStream(destPath, FileMode.CreateNew,
                       FileAccess.Write, FileShare.Read | FileShare.Write | FileShare.Delete)) { }
        }

        try {
            uint flags = FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS;
            using (SafeFileHandle handle = CreateFile(destPath, GENERIC_WRITE,
                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero)) {
                if (handle == null || handle.IsInvalid) {
                    throw new IOException("No se pudo abrir el destino del reparse point. Win32=" + Marshal.GetLastWin32Error());
                }
                int bytesReturned;
                if (!DeviceIoControlSet(handle, FSCTL_SET_REPARSE_POINT,
                                        expectedRaw, expectedRaw.Length,
                                        IntPtr.Zero, 0, out bytesReturned, IntPtr.Zero)) {
                    throw new IOException("FSCTL_SET_REPARSE_POINT fallo. Win32=" + Marshal.GetLastWin32Error());
                }
            }
        } catch {
            try {
                if (isDirectory) Directory.Delete(destPath, false);
                else File.Delete(destPath);
            } catch { }
            throw;
        }

        ReparseCopyResult result = new ReparseCopyResult();
        result.Tag = "0x" + expectedTag.ToString("X8");
        result.DescriptorSha256 = GetSha256Hex(expectedRaw);
        result.IsDirectory = isDirectory;
        // FileInfo/DirectoryInfo pueden seguir el destino del enlace y terminar
        // modificando el archivo real. El descriptor se conserva exactamente;
        // ACL y timestamps del objeto enlace se heredan del Staging y se auditan.
        result.MetadataPreserved = false;
        result.MetadataWarning = "Descriptor NTFS exacto; ACL/timestamps del objeto enlace heredados de Staging para evitar seguir el destino.";
        return result;
    }

    private readonly ConcurrentDictionary<string, string> VolumeUsnIdentityCache =
        new ConcurrentDictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    private bool TryGetVolumeUsnIdentity(string filePath, out string identity) {
        identity = null;
        string root;
        try { root = Path.GetPathRoot(filePath); }
        catch { return false; }
        if (string.IsNullOrEmpty(root) || root.StartsWith(@"\\", StringComparison.Ordinal)) return false;

        string cached;
        if (VolumeUsnIdentityCache.TryGetValue(root, out cached)) {
            if (cached.Length == 0) return false;
            identity = cached;
            return true;
        }

        string resolved = "";
        try {
            uint serial, maxComponent, flags;
            StringBuilder volumeName = new StringBuilder(260);
            StringBuilder fileSystemName = new StringBuilder(64);
            if (!GetVolumeInformation(root, volumeName, (uint)volumeName.Capacity,
                                      out serial, out maxComponent, out flags,
                                      fileSystemName, (uint)fileSystemName.Capacity) ||
                !fileSystemName.ToString().Equals("NTFS", StringComparison.OrdinalIgnoreCase)) {
                VolumeUsnIdentityCache[root] = "";
                return false;
            }

            string volumeDevice = @"\\.\" + root.TrimEnd('\\', '/');
            using (SafeFileHandle volume = CreateFile(volumeDevice, GENERIC_READ,
                    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                    IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero)) {
                if (volume == null || volume.IsInvalid) {
                    VolumeUsnIdentityCache[root] = "";
                    return false;
                }
                byte[] data = new byte[80];
                int returned;
                if (!DeviceIoControl(volume, FSCTL_QUERY_USN_JOURNAL, IntPtr.Zero, 0,
                                     data, data.Length, out returned, IntPtr.Zero) || returned < 56) {
                    VolumeUsnIdentityCache[root] = "";
                    return false;
                }
                ulong journalId = BitConverter.ToUInt64(data, 0);
                resolved = serial.ToString("x8") + ":" + journalId.ToString("x16");
            }
        } catch {
            resolved = "";
        }

        VolumeUsnIdentityCache[root] = resolved;
        if (resolved.Length == 0) return false;
        identity = resolved;
        return true;
    }

    private static bool TryReadFileUsn(SafeFileHandle handle, out string fileId, out long usn) {
        fileId = null;
        usn = 0;
        if (handle == null || handle.IsInvalid) return false;
        try {
            byte[] data = new byte[1024];
            int returned;
            if (!DeviceIoControl(handle, FSCTL_READ_FILE_USN_DATA, IntPtr.Zero, 0,
                                 data, data.Length, out returned, IntPtr.Zero) || returned < 60) return false;
            ushort major = BitConverter.ToUInt16(data, 4);
            int fileIdLength;
            int usnOffset;
            if (major == 2) {
                fileIdLength = 8;
                usnOffset = 24;
            } else if (major == 3 || major == 4) {
                if (returned < 76) return false;
                fileIdLength = 16;
                usnOffset = 40;
            } else {
                return false;
            }
            fileId = BitConverter.ToString(data, 8, fileIdLength).Replace("-", "").ToLowerInvariant();
            usn = BitConverter.ToInt64(data, usnOffset);
            return true;
        } catch {
            return false;
        }
    }

    private static string GetFingerprintToken(string fingerprint, string prefix) {
        if (string.IsNullOrEmpty(fingerprint)) return null;
        int start = fingerprint.IndexOf(prefix, StringComparison.OrdinalIgnoreCase);
        if (start < 0 || (start > 0 && fingerprint[start - 1] != ';')) return null;
        start += prefix.Length;
        int end = fingerprint.IndexOf(';', start);
        if (end < 0) end = fingerprint.Length;
        return fingerprint.Substring(start, end - start);
    }

    public static string GetSha256FromFingerprint(string fingerprint) {
        string value = GetFingerprintToken(fingerprint, "SHA256:");
        return value != null && value.Length == 64 ? value.ToLowerInvariant() : null;
    }

    private static string GetUsnFromFingerprint(string fingerprint) {
        return GetFingerprintToken(fingerprint, "USN:");
    }

    private static bool TryGetLengthFromFingerprint(string fingerprint, out long length) {
        length = 0;
        string value = GetFingerprintToken(fingerprint, "LEN:");
        return value != null && long.TryParse(value, out length) && length >= 0;
    }

    private static string GetUsnJournalScope(string usnStamp) {
        if (string.IsNullOrEmpty(usnStamp)) return null;
        int first = usnStamp.IndexOf(':');
        if (first < 0) return null;
        int second = usnStamp.IndexOf(':', first + 1);
        if (second < 0) return null;
        return usnStamp.Substring(0, second);
    }

    private static string BuildUsnFingerprint(string usnStamp, string hash, long length) {
        return "USN:" + usnStamp + ";SHA256:" + hash + ";LEN:" + length;
    }

    private static bool AreFileFingerprintsEquivalent(string before, string after) {
        if (string.Equals(before, after, StringComparison.OrdinalIgnoreCase)) return true;
        long beforeLength, afterLength;
        if (TryGetLengthFromFingerprint(before, out beforeLength) &&
            TryGetLengthFromFingerprint(after, out afterLength) && beforeLength != afterLength) return false;
        string beforeUsn = GetUsnFromFingerprint(before);
        string afterUsn = GetUsnFromFingerprint(after);
        if (beforeUsn != null && afterUsn != null) {
            if (string.Equals(beforeUsn, afterUsn, StringComparison.OrdinalIgnoreCase)) return true;
            string beforeScope = GetUsnJournalScope(beforeUsn);
            string afterScope = GetUsnJournalScope(afterUsn);
            // Mismo diario y distinto USN/ID: hubo cambio de datos o metadatos.
            if (beforeScope != null && string.Equals(beforeScope, afterScope, StringComparison.OrdinalIgnoreCase)) return false;
            // Diario recreado/cambiado: el post hace SHA completo y se compara contenido.
        }
        string beforeHash = GetSha256FromFingerprint(before);
        string afterHash = GetSha256FromFingerprint(after);
        return beforeHash != null && afterHash != null &&
               string.Equals(beforeHash, afterHash, StringComparison.OrdinalIgnoreCase);
    }

    // Clasifica una mutacion sin rebajar la seguridad de SafeUSN. Esta API se usa
    // para separar cambios de metadatos en rutas protegidas de reemplazos reales:
    // solo dos SHA256 presentes e iguales pueden considerarse MetadataOnly.
    public static string GetFileMutationKind(DiffEngine pre, DiffEngine post, string path) {
        if (pre == null || post == null || string.IsNullOrWhiteSpace(path)) return "Unknown";

        string before;
        string after;
        bool hasBefore = pre.FileSnapshot.TryGetValue(path, out before);
        bool hasAfter = post.FileSnapshot.TryGetValue(path, out after);

        if (!hasBefore && hasAfter) return "Added";
        if (hasBefore && !hasAfter) return "Deleted";
        if (!hasBefore || !hasAfter) return "Unknown";
        bool beforeDirectory = IsDirectoryFingerprint(before);
        bool afterDirectory = IsDirectoryFingerprint(after);
        if (beforeDirectory || afterDirectory) {
            if (beforeDirectory && afterDirectory) {
                return string.Equals(before, after, StringComparison.Ordinal) ? "Unchanged" : "DirectoryMetadataChanged";
            }
            return "TypeChanged";
        }
        if (AreFileFingerprintsEquivalent(before, after)) return "Unchanged";

        string beforeHash = GetSha256FromFingerprint(before);
        string afterHash = GetSha256FromFingerprint(after);
        if (beforeHash == null || afterHash == null) return "Unknown";
        return string.Equals(beforeHash, afterHash, StringComparison.OrdinalIgnoreCase)
            ? "MetadataOnly"
            : "ContentChanged";
    }

    private void RecordFileScanFailure(string path, Exception error, bool isDirectory) {
        if (!string.IsNullOrEmpty(path)) {
            FileScanUncertainPaths[path] = 0;
            string evidence = "";
            try {
                if (isDirectory) {
                    DirectoryInfo directoryInfo = new DirectoryInfo(path);
                    if (directoryInfo.Exists) {
                        evidence = ";WT=" + directoryInfo.LastWriteTimeUtc.Ticks.ToString() +
                                   ";ATTR=" + ((int)directoryInfo.Attributes).ToString();
                    }
                } else {
                    FileInfo fileInfo = new FileInfo(path);
                    if (fileInfo.Exists) {
                        evidence = ";LEN=" + fileInfo.Length.ToString() +
                                   ";WT=" + fileInfo.LastWriteTimeUtc.Ticks.ToString() +
                                   ";ATTR=" + ((int)fileInfo.Attributes).ToString();
                    }
                }
            } catch { }
            string message = error == null ? "Error no especificado" : error.Message;
            if (message == null) message = "";
            message = message.Replace("\r", " ").Replace("\n", " ");
            string typeName = error == null ? "Unknown" : error.GetType().Name;
            int hresult = error == null ? 0 : error.HResult;
            FileScanFailureDetails[path] = "TYPE=" + typeName +
                                           ";HRESULT=" + hresult.ToString() +
                                           evidence + ";MESSAGE=" + message;
        }

        if (isDirectory) {
            if (error is UnauthorizedAccessException) Interlocked.Increment(ref ScanMetrics.DirectoriesSkippedByAccessDenied);
            else if (error is IOException) Interlocked.Increment(ref ScanMetrics.DirectoriesSkippedByIoError);
            else Interlocked.Increment(ref ScanMetrics.DirectoriesSkippedByOtherError);
        } else {
            if (error is UnauthorizedAccessException) Interlocked.Increment(ref ScanMetrics.FilesSkippedByAccessDenied);
            else if (error is IOException) Interlocked.Increment(ref ScanMetrics.FilesSkippedByIoError);
            else Interlocked.Increment(ref ScanMetrics.FilesSkippedByOtherError);
        }
    }

    private string ComputeFingerprintOnce(string filePath) {
        FileInfo fi = new FileInfo(filePath);
        if (HashAllFiles || fi.Length < HashThresholdBytes) {
            using (FileStream fs = new FileStream(filePath, FileMode.Open, FileAccess.Read,
                                                  FileShare.ReadWrite | FileShare.Delete,
                                                  HashBufferSize, FileOptions.SequentialScan)) {
                string volumeIdentity = null;
                string fileId = null;
                long initialUsn = 0;
                bool hasUsn = UseUsnOptimization && HashAllFiles &&
                              TryGetVolumeUsnIdentity(filePath, out volumeIdentity) &&
                              TryReadFileUsn(fs.SafeFileHandle, out fileId, out initialUsn);
                bool usedUsnFallback = false;
                string usnStamp = hasUsn
                    ? volumeIdentity + ":" + fileId + ":" + unchecked((ulong)initialUsn).ToString("x16")
                    : null;

                if (hasUsn) {
                    string baselineFingerprint;
                    if (BaselineForReuse != null &&
                        BaselineForReuse.FileSnapshot.TryGetValue(filePath, out baselineFingerprint)) {
                        string baselineUsn = GetUsnFromFingerprint(baselineFingerprint);
                        if (string.Equals(baselineUsn, usnStamp, StringComparison.OrdinalIgnoreCase)) {
                            string baselineHash = GetSha256FromFingerprint(baselineFingerprint);
                            long baselineLength;
                            if (baselineHash != null &&
                                TryGetLengthFromFingerprint(baselineFingerprint, out baselineLength) &&
                                baselineLength == fi.Length) {
                                Interlocked.Increment(ref ScanMetrics.FilesWithUsn);
                                Interlocked.Increment(ref ScanMetrics.FilesVerifiedByUsn);
                                Interlocked.Add(ref ScanMetrics.HashBytesAvoidedByUsn, fi.Length);
                                return BuildUsnFingerprint(usnStamp, baselineHash, fi.Length);
                            }
                        } else {
                            string baselineScope = GetUsnJournalScope(baselineUsn);
                            string currentScope = GetUsnJournalScope(usnStamp);
                            usedUsnFallback = baselineUsn == null || baselineScope == null ||
                                !string.Equals(baselineScope, currentScope, StringComparison.OrdinalIgnoreCase);
                        }
                    }
                } else if (UseUsnOptimization && HashAllFiles) {
                    usedUsnFallback = true;
                }

                string hashHex;
                using (SHA256 sha = SHA256.Create()) {
                    fs.Position = 0;
                    hashHex = BitConverter.ToString(sha.ComputeHash(fs)).Replace("-", "").ToLowerInvariant();
                }

                fi.Refresh();
                if (!fi.Exists || fi.Length != fs.Length) {
                    throw new IOException("El archivo cambio de tamano durante el calculo SHA256.");
                }
                if (hasUsn) {
                    string finalFileId;
                    long finalUsn;
                    if (!TryReadFileUsn(fs.SafeFileHandle, out finalFileId, out finalUsn) ||
                        !string.Equals(finalFileId, fileId, StringComparison.OrdinalIgnoreCase) ||
                        finalUsn != initialUsn) {
                        throw new IOException("El archivo cambio durante el calculo SHA256 (USN inestable).");
                    }
                    Interlocked.Increment(ref ScanMetrics.FilesWithUsn);
                }
                if (usedUsnFallback) Interlocked.Increment(ref ScanMetrics.FilesUsnFallback);
                Interlocked.Increment(ref ScanMetrics.FilesHashed);
                Interlocked.Add(ref ScanMetrics.HashBytesRead, fi.Length);
                if (hasUsn) return BuildUsnFingerprint(usnStamp, hashHex, fi.Length);
                return "SHA256:" + hashHex + ";LEN:" + fi.Length;
            }
        }

        Interlocked.Increment(ref ScanMetrics.FilesByMetadata);
        return "META:" + fi.LastWriteTimeUtc.Ticks + ";LEN:" + fi.Length;
    }

    private static bool TryMapToVssPath(string filePath, out string vssPath) {
        vssPath = null;
        if (string.IsNullOrWhiteSpace(filePath) ||
            string.IsNullOrWhiteSpace(VssFallbackDrive) ||
            string.IsNullOrWhiteSpace(VssFallbackDeviceObject)) return false;
        string root;
        try { root = Path.GetPathRoot(filePath); }
        catch { return false; }
        if (string.IsNullOrWhiteSpace(root) ||
            !root.TrimEnd('\\').Equals(VssFallbackDrive.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) return false;
        string relative = filePath.Substring(root.Length).TrimStart('\\', '/');
        vssPath = VssFallbackDeviceObject.TrimEnd('\\') + "\\" + relative;
        return true;
    }

    private string ComputeFingerprintFromVss(string vssPath) {
        FileInfo fi = new FileInfo(vssPath);
        using (FileStream fs = new FileStream(vssPath, FileMode.Open, FileAccess.Read,
                                              FileShare.ReadWrite | FileShare.Delete,
                                              HashBufferSize, FileOptions.SequentialScan))
        using (SHA256 sha = SHA256.Create()) {
            string hashHex = BitConverter.ToString(sha.ComputeHash(fs)).Replace("-", "").ToLowerInvariant();
            fi.Refresh();
            if (!fi.Exists || fi.Length != fs.Length) {
                throw new IOException("El archivo VSS cambio de tamano durante el calculo SHA256.");
            }
            Interlocked.Increment(ref ScanMetrics.FilesHashed);
            Interlocked.Increment(ref ScanMetrics.FilesRecoveredByVss);
            Interlocked.Add(ref ScanMetrics.HashBytesRead, fi.Length);
            return "SHA256:" + hashHex + ";LEN:" + fi.Length;
        }
    }

    private string ComputeFingerprint(string filePath) {
        Exception lastError = null;
        int attempts = Math.Max(1, FileScanMaxAttempts);
        for (int attempt = 1; attempt <= attempts; attempt++) {
            try {
                return ComputeFingerprintOnce(filePath);
            } catch (Exception ex) {
                lastError = ex;
                if (attempt < attempts && FileScanRetryDelayMilliseconds > 0) {
                    Thread.Sleep(FileScanRetryDelayMilliseconds * attempt);
                }
            }
        }

        string vssPath;
        if (TryMapToVssPath(filePath, out vssPath)) {
            try {
                return ComputeFingerprintFromVss(vssPath);
            } catch (Exception ex) {
                lastError = new IOException("Fallo en lectura directa y en rescate VSS: " + ex.Message, lastError);
            }
        }

        RecordFileScanFailure(filePath, lastError, false);
        return string.Empty;
    }

    private static bool CanRenderScanProgress() {
        try {
            return !Console.IsOutputRedirected && Console.WindowWidth > 20;
        } catch {
            return false;
        }
    }

    private static string FormatProgressBytes(long bytes, bool compact) {
        if (bytes < 0) bytes = 0;
        double value = bytes;
        string unit = compact ? "B" : " B";
        if (bytes >= 1024L * 1024L * 1024L) {
            value = bytes / (1024.0 * 1024.0 * 1024.0);
            unit = compact ? "G" : " GB";
        } else if (bytes >= 1024L * 1024L) {
            value = bytes / (1024.0 * 1024.0);
            unit = compact ? "M" : " MB";
        } else if (bytes >= 1024L) {
            value = bytes / 1024.0;
            unit = compact ? "K" : " KB";
        }
        return value.ToString(value >= 100 ? "0" : value >= 10 ? "0.0" : "0.00") + unit;
    }

    private static string FormatProgressElapsed(TimeSpan elapsed, bool compact) {
        long seconds = Math.Max(0L, (long)elapsed.TotalSeconds);
        long hours = seconds / 3600;
        long minutes = (seconds % 3600) / 60;
        long remainingSeconds = seconds % 60;
        if (compact && hours == 0) return string.Format("{0:D2}:{1:D2}", minutes, remainingSeconds);
        return string.Format("{0:D2}:{1:D2}:{2:D2}", hours, minutes, remainingSeconds);
    }

    private static string FitScanPath(string path, int available) {
        if (available <= 0) return "";
        if (string.IsNullOrEmpty(path)) return "";
        if (path.Length <= available) return path;
        if (available <= 3) return path.Substring(path.Length - available);
        return "..." + path.Substring(path.Length - (available - 3));
    }

    private static void ClearCurrentConsoleLine(int width) {
        if (width < 2) return;
        Console.Write("\r");
        Console.Write(new string(' ', width - 1));
        Console.Write("\r");
    }

    private static void WriteScanProgressLine(string verb, string subject, string suffix,
                                              ref int previousLineLength) {
        int width = Console.WindowWidth;
        if (width < 20) return;

        string prefix = " -> " + (string.IsNullOrEmpty(verb) ? "Escaneando" : verb) + " ";
        int availableForSubject = Math.Max(0, width - prefix.Length - suffix.Length - 2);
        string line = prefix + FitScanPath(subject, availableForSubject) + suffix + " ";
        if (line.Length >= width) line = line.Substring(0, width - 1);

        ConsoleColor originalColor = Console.ForegroundColor;
        try {
            Console.ForegroundColor = ConsoleColor.DarkGray;
            if (previousLineLength <= 0) {
                // La linea inicial la imprime PowerShell y puede contener texto extra
                // que el temporizador aun no conoce (por ejemplo, el modo de la raiz).
                ClearCurrentConsoleLine(width);
                Console.Write(line);
            } else {
                Console.Write("\r" + line);
            }
            if (previousLineLength > 0 && previousLineLength > line.Length) {
                Console.Write(new string(' ', previousLineLength - line.Length));
                Console.Write("\r" + line);
            }
        } finally {
            Console.ForegroundColor = originalColor;
        }
        previousLineLength = line.Length;
    }

    private static void RestoreScanStatusLine(string verb, string subject,
                                              ref int previousLineLength) {
        try {
            int width = Console.WindowWidth;
            if (width < 20) return;

            string prefix = " -> " + (string.IsNullOrEmpty(verb) ? "Escaneando" : verb) + " ";
            // Se reservan seis caracteres para que PowerShell pueda anexar [OK]
            // o [ERROR] sin provocar un salto de linea inesperado.
            int availableForSubject = Math.Max(0, width - prefix.Length - 6);
            string line = prefix + FitScanPath(subject, availableForSubject) + " ";
            if (line.Length >= width) line = line.Substring(0, width - 1);

            ConsoleColor originalColor = Console.ForegroundColor;
            try {
                Console.ForegroundColor = ConsoleColor.DarkGray;
                // Limpiar toda la fila también cuando el escaneo termina antes del
                // primer tick (previousLineLength == 0). Así no quedan caracteres
                // de la etiqueta inicial cuando PowerShell agrega [OK]/[ERROR].
                ClearCurrentConsoleLine(width);
                Console.Write(line);
            } finally {
                Console.ForegroundColor = originalColor;
            }
            previousLineLength = line.Length;
        } catch {
            // Restaurar la linea es solo presentacion; el escaneo ya termino.
        }
    }

    private string BuildFileScanSummaryLine(Stopwatch stopwatch,
                                            long baseDirectories, long baseFiles,
                                            long baseHashed, long baseUsn,
                                            long baseBytesRead, long baseBytesAvoided) {
        long directories = Math.Max(0L, Interlocked.Read(ref ScanMetrics.DirectoriesScanned) - baseDirectories);
        long files = Math.Max(0L, Interlocked.Read(ref ScanMetrics.FilesIndexed) - baseFiles);
        long hashed = Math.Max(0L, Interlocked.Read(ref ScanMetrics.FilesHashed) - baseHashed);
        long usn = Math.Max(0L, Interlocked.Read(ref ScanMetrics.FilesVerifiedByUsn) - baseUsn);
        long bytesRead = Math.Max(0L, Interlocked.Read(ref ScanMetrics.HashBytesRead) - baseBytesRead);
        long bytesAvoided = Math.Max(0L, Interlocked.Read(ref ScanMetrics.HashBytesAvoidedByUsn) - baseBytesAvoided);
        return string.Format("[+] {0:N0} dirs | {1:N0} arch | SHA {2:N0} | USN {3:N0} | leido {4} | evitado {5} | {6}",
            directories, files, hashed, usn,
            FormatProgressBytes(bytesRead, false), FormatProgressBytes(bytesAvoided, false),
            FormatProgressElapsed(stopwatch.Elapsed, false));
    }

    private void WriteScanProgress(string path, string verb, Stopwatch stopwatch,
                                   long baseDirectories, long baseFiles, long baseHashed,
                                   long baseUsn, long baseBytesRead, long baseBytesAvoided,
                                   char spinner, ref int previousLineLength) {
        try {
            int width = Console.WindowWidth;
            if (width < 20) return;

            long directories = Math.Max(0L, Interlocked.Read(ref ScanMetrics.DirectoriesScanned) - baseDirectories);
            long files = Math.Max(0L, Interlocked.Read(ref ScanMetrics.FilesIndexed) - baseFiles);
            long hashed = Math.Max(0L, Interlocked.Read(ref ScanMetrics.FilesHashed) - baseHashed);
            long usn = Math.Max(0L, Interlocked.Read(ref ScanMetrics.FilesVerifiedByUsn) - baseUsn);
            long bytesRead = Math.Max(0L, Interlocked.Read(ref ScanMetrics.HashBytesRead) - baseBytesRead);
            long bytesAvoided = Math.Max(0L, Interlocked.Read(ref ScanMetrics.HashBytesAvoidedByUsn) - baseBytesAvoided);
            string suffix;

            if (width >= 140) {
                suffix = string.Format(" [{0}] {1:N0} dirs | {2:N0} arch | SHA {3:N0} | USN {4:N0} | leido {5} | evitado {6} | {7}",
                    spinner, directories, files, hashed, usn,
                    FormatProgressBytes(bytesRead, false), FormatProgressBytes(bytesAvoided, false),
                    FormatProgressElapsed(stopwatch.Elapsed, false));
            } else if (width >= 100) {
                suffix = string.Format(" [{0}] F:{1:N0} SHA:{2:N0} USN:{3:N0} R:{4} E:{5} {6}",
                    spinner, files, hashed, usn,
                    FormatProgressBytes(bytesRead, true), FormatProgressBytes(bytesAvoided, true),
                    FormatProgressElapsed(stopwatch.Elapsed, false));
            } else {
                suffix = string.Format(" [{0}] F:{1:N0} H:{2:N0} U:{3:N0} {4} {5}",
                    spinner, files, hashed, usn, FormatProgressBytes(bytesRead, true),
                    FormatProgressElapsed(stopwatch.Elapsed, true));
            }

            WriteScanProgressLine(verb, path, suffix, ref previousLineLength);
        } catch {
            // La retroalimentacion es auxiliar: nunca debe interrumpir la captura.
        }
    }

    public void ScanDirectory(string path) {
        ScanDirectory(path, "Escaneando");
    }

    public void ScanDirectory(string path, string verb) {
        RunFileScanOperation(path, verb, delegate {
            if (!Directory.Exists(path)) return;
            PrepareExclusionMatchers();
            if (IsReparsePoint(path)) {
                RecordReparsePoint(path, true);
                Interlocked.Increment(ref ScanMetrics.DirectoriesSkippedByReparsePoint);
                return;
            }
            string rootFingerprint = ComputeDirectoryFingerprint(path);
            if (!string.IsNullOrEmpty(rootFingerprint)) FileSnapshot[path] = rootFingerprint;
            ScanDirectoryTree(path);
        });
    }

    // Cubre archivos y carpetas ubicados directamente en la raiz de la unidad sin
    // volver a recorrer Windows, Program Files, ProgramData y Users. En el snapshot
    // final solo desciende por carpetas de raiz que no existian en el snapshot base;
    // asi se captura, por ejemplo, C:\MiAplicacion\... sin duplicar el escaneo completo.
    public void ScanDriveRoot(string rootPath, string verb, bool recurseNewDirectories) {
        RunFileScanOperation(rootPath, verb, delegate {
            if (!Directory.Exists(rootPath)) return;
            PrepareExclusionMatchers();

            List<string> newDirectories = new List<string>();
            Interlocked.Increment(ref ScanMetrics.DirectoriesScanned);
            try {
                foreach (string entry in Directory.EnumerateFileSystemEntries(rootPath)) {
                    FileAttributes attributes;
                    try {
                        attributes = File.GetAttributes(entry);
                    } catch (Exception ex) {
                        bool directoryHint = false;
                        try { directoryHint = Directory.Exists(entry); } catch { }
                        RecordFileScanFailure(entry, ex, directoryHint);
                        continue;
                    }

                    bool isDirectory = (attributes & FileAttributes.Directory) == FileAttributes.Directory;
                    bool isReparse = (attributes & FileAttributes.ReparsePoint) == FileAttributes.ReparsePoint;
                    if (isDirectory) {
                        Interlocked.Increment(ref ScanMetrics.DirectoriesDiscovered);
                        if (IsFileExcluded(entry)) {
                            Interlocked.Increment(ref ScanMetrics.DirectoriesSkippedByExclusion);
                            continue;
                        }
                        if (isReparse) {
                            RecordReparsePoint(entry, true);
                            Interlocked.Increment(ref ScanMetrics.DirectoriesSkippedByReparsePoint);
                            continue;
                        }

                        string directoryFingerprint = ComputeDirectoryFingerprint(entry);
                        if (!string.IsNullOrEmpty(directoryFingerprint)) FileSnapshot[entry] = directoryFingerprint;
                        if (recurseNewDirectories && BaselineForReuse != null &&
                            !BaselineForReuse.FileSnapshot.ContainsKey(entry)) {
                            newDirectories.Add(entry);
                        }
                    } else {
                        Interlocked.Increment(ref ScanMetrics.FilesDiscovered);
                        if (IsFileExcluded(entry)) {
                            Interlocked.Increment(ref ScanMetrics.FilesSkippedByExclusion);
                            continue;
                        }
                        if (isReparse) {
                            RecordReparsePoint(entry, false);
                            Interlocked.Increment(ref ScanMetrics.FilesSkippedByReparsePoint);
                            continue;
                        }

                        string fp = ComputeFingerprint(entry);
                        if (!string.IsNullOrEmpty(fp)) {
                            FileSnapshot[entry] = fp;
                            Interlocked.Increment(ref ScanMetrics.FilesIndexed);
                        }
                    }
                }
            } catch (Exception ex) {
                RecordFileScanFailure(rootPath, ex, true);
            }

            foreach (string newDirectory in newDirectories) {
                ScanDirectoryTree(newDirectory);
            }
        });
    }

    private void RunFileScanOperation(string path, string verb, Action scanAction) {
        Stopwatch sw = Stopwatch.StartNew();
        long baseDirectories = Interlocked.Read(ref ScanMetrics.DirectoriesScanned);
        long baseFiles = Interlocked.Read(ref ScanMetrics.FilesIndexed);
        long baseHashed = Interlocked.Read(ref ScanMetrics.FilesHashed);
        long baseUsn = Interlocked.Read(ref ScanMetrics.FilesVerifiedByUsn);
        long baseBytesRead = Interlocked.Read(ref ScanMetrics.HashBytesRead);
        long baseBytesAvoided = Interlocked.Read(ref ScanMetrics.HashBytesAvoidedByUsn);
        object progressSync = new object();
        Timer progressTimer = null;
        int progressStopped = 0;
        int spinnerIndex = 0;
        int previousLineLength = 0;
        char[] spinnerFrames = new char[] { '|', '/', '-', '\\' };
        try {
            if (CanRenderScanProgress()) {
                progressTimer = new Timer(delegate {
                    if (Interlocked.CompareExchange(ref progressStopped, 0, 0) != 0) return;
                    lock (progressSync) {
                        if (Interlocked.CompareExchange(ref progressStopped, 0, 0) != 0) return;
                        char frame = spinnerFrames[spinnerIndex++ % spinnerFrames.Length];
                        WriteScanProgress(path, verb, sw, baseDirectories, baseFiles, baseHashed,
                                          baseUsn, baseBytesRead, baseBytesAvoided, frame,
                                          ref previousLineLength);
                    }
                }, null, 500, 750);
            }
            scanAction();
        } finally {
            Interlocked.Exchange(ref progressStopped, 1);
            if (progressTimer != null) progressTimer.Dispose();
            lock (progressSync) { }

            sw.Stop();
            LastScanSummaryLine = BuildFileScanSummaryLine(sw, baseDirectories, baseFiles,
                baseHashed, baseUsn, baseBytesRead, baseBytesAvoided);
            Interlocked.Add(ref ScanMetrics.ElapsedMilliseconds, sw.ElapsedMilliseconds);

            if (CanRenderScanProgress()) {
                lock (progressSync) {
                    RestoreScanStatusLine(verb, path, ref previousLineLength);
                }
            }
        }
    }

    private void ScanDirectoryTree(string path) {
        int fileWorkerCount = GetEffectiveParallelism();
        int directoryWorkerCount = Math.Min(2, fileWorkerCount);
        BlockingCollection<string> directoryQueue = new BlockingCollection<string>();
        BlockingCollection<string> fileQueue = new BlockingCollection<string>();
        long pendingDirectories = 1;
        directoryQueue.Add(path);

        Task[] fileWorkers = new Task[fileWorkerCount];
        for (int i = 0; i < fileWorkers.Length; i++) {
            fileWorkers[i] = Task.Factory.StartNew(delegate {
                foreach (string file in fileQueue.GetConsumingEnumerable()) {
                    try {
                        string fp = ComputeFingerprint(file);
                        if (!string.IsNullOrEmpty(fp)) {
                            FileSnapshot[file] = fp;
                            Interlocked.Increment(ref ScanMetrics.FilesIndexed);
                        }
                    } catch (Exception ex) {
                        RecordFileScanFailure(file, ex, false);
                    }
                }
            }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        }

        Task[] directoryWorkers = new Task[directoryWorkerCount];
        for (int i = 0; i < directoryWorkers.Length; i++) {
            directoryWorkers[i] = Task.Factory.StartNew(delegate {
                foreach (string dir in directoryQueue.GetConsumingEnumerable()) {
                    try {
                        ScanOneDirectory(dir, directoryQueue, fileQueue, ref pendingDirectories);
                    } finally {
                        if (Interlocked.Decrement(ref pendingDirectories) == 0) {
                            directoryQueue.CompleteAdding();
                            fileQueue.CompleteAdding();
                        }
                    }
                }
            }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        }

        Task.WaitAll(directoryWorkers);
        Task.WaitAll(fileWorkers);
        directoryQueue.Dispose();
        fileQueue.Dispose();
    }

    private void ScanOneDirectory(string path, BlockingCollection<string> directoryQueue,
                                  BlockingCollection<string> fileQueue, ref long pendingDirectories) {
        if (IsFileExcluded(path)) {
            Interlocked.Increment(ref ScanMetrics.DirectoriesSkippedByExclusion);
            return;
        }
        if (IsReparsePoint(path)) {
            RecordReparsePoint(path, true);
            Interlocked.Increment(ref ScanMetrics.DirectoriesSkippedByReparsePoint);
            return;
        }

        try {
            Interlocked.Increment(ref ScanMetrics.DirectoriesScanned);
            foreach (string entry in Directory.EnumerateFileSystemEntries(path)) {
                FileAttributes attributes;
                try {
                    attributes = File.GetAttributes(entry);
                } catch (Exception ex) {
                    bool directoryHint = false;
                    try { directoryHint = Directory.Exists(entry); } catch { }
                    RecordFileScanFailure(entry, ex, directoryHint);
                    continue;
                }

                bool isDirectory = (attributes & FileAttributes.Directory) == FileAttributes.Directory;
                bool isReparse = (attributes & FileAttributes.ReparsePoint) == FileAttributes.ReparsePoint;
                if (isDirectory) {
                    Interlocked.Increment(ref ScanMetrics.DirectoriesDiscovered);
                    if (IsFileExcluded(entry)) {
                        Interlocked.Increment(ref ScanMetrics.DirectoriesSkippedByExclusion);
                        continue;
                    }
                    if (isReparse) {
                        RecordReparsePoint(entry, true);
                        Interlocked.Increment(ref ScanMetrics.DirectoriesSkippedByReparsePoint);
                        continue;
                    }
                    string directoryFingerprint = ComputeDirectoryFingerprint(entry);
                    if (!string.IsNullOrEmpty(directoryFingerprint)) FileSnapshot[entry] = directoryFingerprint;
                    Interlocked.Increment(ref pendingDirectories);
                    directoryQueue.Add(entry);
                } else {
                    Interlocked.Increment(ref ScanMetrics.FilesDiscovered);
                    if (IsFileExcluded(entry)) {
                        Interlocked.Increment(ref ScanMetrics.FilesSkippedByExclusion);
                        continue;
                    }
                    if (isReparse) {
                        RecordReparsePoint(entry, false);
                        Interlocked.Increment(ref ScanMetrics.FilesSkippedByReparsePoint);
                        continue;
                    }
                    fileQueue.Add(entry);
                }
            }
        } catch (Exception ex) {
            RecordFileScanFailure(path, ex, true);
        }
    }

    public class FileCopyResult {
        public string HashHex = "";
        public bool MetadataPreserved = true;
        public string MetadataWarning = "";
    }

    // File.Copy usa la primitiva nativa de Windows y conserva streams NTFS. Despues
    // restauramos explicitamente ACL, propietario, grupo, atributos y timestamps.
    public static FileCopyResult CopyAndHash(string sourcePath, string destPath) {
        FileCopyResult result = new FileCopyResult();
        File.Copy(sourcePath, destPath, true);
        FileInfo sourceInfo = new FileInfo(sourcePath);
        FileInfo destInfo = new FileInfo(destPath);
        FileAttributes sourceAttributes = sourceInfo.Attributes;

        using (SHA256 sha = SHA256.Create())
        using (FileStream fs = new FileStream(destPath, FileMode.Open, FileAccess.Read,
                                               FileShare.ReadWrite | FileShare.Delete,
                                               HashBufferSize, FileOptions.SequentialScan)) {
            result.HashHex = BitConverter.ToString(sha.ComputeHash(fs)).Replace("-", "").ToLowerInvariant();
        }

        List<string> warnings = new List<string>();
        // Primero restauramos metadatos mutables. Aplicar una ACL restrictiva
        // antes puede retirar al propio proceso el derecho de escribirlos. Ademas,
        // File.Copy conserva ReadOnly y .NET Framework no permite restaurar los
        // timestamps de un destino de solo lectura: lo neutralizamos de forma
        // temporal y restauramos exactamente los atributos del origen al final.
        try {
            FileAttributes destAttributes = File.GetAttributes(destPath);
            if ((destAttributes & FileAttributes.ReadOnly) != 0) {
                FileAttributes writableAttributes = destAttributes & ~FileAttributes.ReadOnly;
                if (writableAttributes == 0) writableAttributes = FileAttributes.Normal;
                File.SetAttributes(destPath, writableAttributes);
            }
        } catch (Exception ex) { warnings.Add("preparar atributos: " + ex.Message); }

        try {
            File.SetCreationTimeUtc(destPath, sourceInfo.CreationTimeUtc);
            File.SetLastWriteTimeUtc(destPath, sourceInfo.LastWriteTimeUtc);
            File.SetLastAccessTimeUtc(destPath, sourceInfo.LastAccessTimeUtc);
        } catch (Exception ex) { warnings.Add("timestamps: " + ex.Message); }

        try {
            File.SetAttributes(destPath, sourceAttributes);
        } catch (Exception ex) { warnings.Add("restaurar atributos: " + ex.Message); }

        // La seguridad queda al final para que sea el estado definitivo del
        // objeto. SeRestorePrivilege se habilita y valida antes de Staging.
        try {
            FileSecurity security = sourceInfo.GetAccessControl(
                AccessControlSections.Access | AccessControlSections.Owner | AccessControlSections.Group);
            destInfo.SetAccessControl(security);
        } catch (Exception ex) { warnings.Add("ACL/propietario: " + ex.Message); }

        result.MetadataPreserved = warnings.Count == 0;
        result.MetadataWarning = string.Join(" | ", warnings.ToArray());
        return result;
    }

    public static string CreateDirectoryWithMetadata(string sourcePath, string destPath) {
        Directory.CreateDirectory(destPath);
        DirectoryInfo sourceInfo = new DirectoryInfo(sourcePath);
        DirectoryInfo destInfo = new DirectoryInfo(destPath);
        FileAttributes sourceAttributes = sourceInfo.Attributes;
        List<string> warnings = new List<string>();
        try {
            FileAttributes destAttributes = File.GetAttributes(destPath);
            if ((destAttributes & FileAttributes.ReadOnly) != 0) {
                FileAttributes writableAttributes = destAttributes & ~FileAttributes.ReadOnly;
                if (writableAttributes == 0) writableAttributes = FileAttributes.Normal;
                File.SetAttributes(destPath, writableAttributes);
            }
        } catch (Exception ex) { warnings.Add("preparar atributos: " + ex.Message); }

        try {
            Directory.SetCreationTimeUtc(destPath, sourceInfo.CreationTimeUtc);
            Directory.SetLastWriteTimeUtc(destPath, sourceInfo.LastWriteTimeUtc);
            Directory.SetLastAccessTimeUtc(destPath, sourceInfo.LastAccessTimeUtc);
        } catch (Exception ex) { warnings.Add("timestamps: " + ex.Message); }

        try {
            File.SetAttributes(destPath, sourceAttributes);
        } catch (Exception ex) { warnings.Add("restaurar atributos: " + ex.Message); }

        try {
            DirectorySecurity security = sourceInfo.GetAccessControl(
                AccessControlSections.Access | AccessControlSections.Owner | AccessControlSections.Group);
            destInfo.SetAccessControl(security);
        } catch (Exception ex) { warnings.Add("ACL/propietario: " + ex.Message); }
        return string.Join(" | ", warnings.ToArray());
    }

    // Los objetos redirigidos desde el perfil de captura no deben conservar el
    // SID del usuario capturador. Se aplica una ACL de plantilla compatible con
    // Users\Default; el servicio de perfiles asignara el SID del nuevo usuario
    // al materializar cada perfil.
    public static string ApplyPortableProfileSecurity(string path, bool isDirectory) {
        try {
            SecurityIdentifier systemSid = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            SecurityIdentifier adminsSid = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            SecurityIdentifier usersSid = new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null);
            FileSystemRights full = FileSystemRights.FullControl;
            FileSystemRights read = FileSystemRights.ReadAndExecute | FileSystemRights.Synchronize;

            if (isDirectory) {
                DirectorySecurity security = new DirectorySecurity();
                security.SetAccessRuleProtection(true, false);
                InheritanceFlags inherit = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
                security.AddAccessRule(new FileSystemAccessRule(systemSid, full, inherit, PropagationFlags.None, AccessControlType.Allow));
                security.AddAccessRule(new FileSystemAccessRule(adminsSid, full, inherit, PropagationFlags.None, AccessControlType.Allow));
                security.AddAccessRule(new FileSystemAccessRule(usersSid, read, inherit, PropagationFlags.None, AccessControlType.Allow));
                security.SetOwner(systemSid);
                new DirectoryInfo(path).SetAccessControl(security);
            } else {
                FileSecurity security = new FileSecurity();
                security.SetAccessRuleProtection(true, false);
                security.AddAccessRule(new FileSystemAccessRule(systemSid, full, AccessControlType.Allow));
                security.AddAccessRule(new FileSystemAccessRule(adminsSid, full, AccessControlType.Allow));
                security.AddAccessRule(new FileSystemAccessRule(usersSid, read, AccessControlType.Allow));
                security.SetOwner(systemSid);
                new FileInfo(path).SetAccessControl(security);
            }
            return "";
        } catch (Exception ex) {
            return ex.Message;
        }
    }

    public class FileDiffResult : System.Collections.Generic.IEnumerable<string> {
        public List<string> NewFiles      = new List<string>();  // archivos no presentes en Pre
        public List<string> ModifiedFiles = new List<string>();  // archivos con fingerprint distinto
        public List<string> NewDirs       = new List<string>();  // carpetas nuevas (para staging)
        public List<string> ModifiedDirs  = new List<string>();  // carpetas con ACL/atributos/timestamps distintos
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
            foreach (var d in ModifiedDirs)  yield return d;
        }
        System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() { return GetEnumerator(); }
    }

    public static FileDiffResult GetFileDifferences(DiffEngine pre, DiffEngine post) {
        var result = new FileDiffResult();
        foreach (var kvp in post.FileSnapshot) {
            if (IsFilePathUncertain(pre, kvp.Key) || IsFilePathUncertain(post, kvp.Key)) continue;
            bool isDir = IsDirectoryFingerprint(kvp.Value);
            bool isNew = !pre.FileSnapshot.ContainsKey(kvp.Key);
            if (isNew) {
                if (isDir) result.NewDirs.Add(kvp.Key);
                else       result.NewFiles.Add(kvp.Key);
            } else if (isDir) {
                if (!string.Equals(pre.FileSnapshot[kvp.Key], kvp.Value, StringComparison.Ordinal)) {
                    result.ModifiedDirs.Add(kvp.Key);
                }
            } else if (!AreFileFingerprintsEquivalent(pre.FileSnapshot[kvp.Key], kvp.Value)) {
                result.ModifiedFiles.Add(kvp.Key);
            }
        }
        return result;
    }

    public static List<ReparsePointChange> GetChangedReparsePointRecords(DiffEngine pre,
                                                                          DiffEngine post) {
        List<ReparsePointChange> changed = new List<ReparsePointChange>();
        foreach (var item in post.ReparsePointSnapshot) {
            string before;
            string operation = null;
            if (!pre.ReparsePointSnapshot.TryGetValue(item.Key, out before)) operation = "add";
            else if (!string.Equals(before, item.Value, StringComparison.Ordinal)) operation = "replace";
            if (operation == null) continue;

            bool isDirectory;
            uint tag;
            byte[] raw;
            string reason;
            bool reproducible = TryParseReparseDescriptor(item.Value, out isDirectory, out tag,
                                                           out raw, out reason);
            if (operation == "add" && pre.FileSnapshot.ContainsKey(item.Key)) {
                reproducible = false;
                reason = "La ruta cambio de archivo/directorio ordinario a reparse point; requiere una eliminacion previa al WIM que este schema no ejecuta.";
            }
            ReparsePointChange record = new ReparsePointChange();
            record.Operation = operation;
            record.Path = item.Key;
            record.Kind = isDirectory ? "directory" : "file";
            record.Tag = reproducible ? "0x" + tag.ToString("X8") : "unknown";
            record.DescriptorSha256 = reproducible ? GetSha256Hex(raw) : "";
            record.Descriptor = item.Value;
            record.Reproducible = reproducible;
            record.Reason = reproducible ? "" : reason;
            changed.Add(record);
        }
        foreach (var item in pre.ReparsePointSnapshot) {
            if (post.ReparsePointSnapshot.ContainsKey(item.Key)) continue;
            bool isDirectory;
            uint tag;
            byte[] raw;
            string reason;
            bool parsed = TryParseReparseDescriptor(item.Value, out isDirectory, out tag,
                                                     out raw, out reason);
            bool replacedByOrdinaryPath = post.FileSnapshot.ContainsKey(item.Key);
            ReparsePointChange record = new ReparsePointChange();
            record.Operation = "delete";
            record.Path = item.Key;
            record.Kind = parsed && isDirectory ? "directory" : "file";
            record.Tag = parsed ? "0x" + tag.ToString("X8") : "unknown";
            record.DescriptorSha256 = parsed ? GetSha256Hex(raw) : "";
            record.Descriptor = item.Value;
            record.Reproducible = !replacedByOrdinaryPath;
            record.Reason = replacedByOrdinaryPath ?
                "La ruta cambio de reparse point a archivo/directorio ordinario; requiere una eliminacion previa al WIM que este schema no ejecuta." : "";
            changed.Add(record);
        }
        changed.Sort(delegate(ReparsePointChange left, ReparsePointChange right) {
            return StringComparer.OrdinalIgnoreCase.Compare(left.Path, right.Path);
        });
        return changed;
    }

    public static List<string> GetChangedReparsePoints(DiffEngine pre, DiffEngine post) {
        List<string> changed = new List<string>();
        foreach (ReparsePointChange record in GetChangedReparsePointRecords(pre, post)) {
            string operation = record.Operation == "add" ? "Added" :
                               record.Operation == "replace" ? "Changed" : "Deleted";
            string detail = operation + ": " + record.Path;
            if (!record.Reproducible) detail += " [UNSUPPORTED]";
            else if (record.Operation != "delete") detail += " [" + record.Tag + "]";
            changed.Add(detail);
        }
        return changed;
    }

    // Detecta archivos/carpetas presentes en Pre pero ausentes en Post (eliminados
    // por el instalador). Un WIM es aditivo y no puede representar una eliminacion, por lo que esta
    // lista no se copia al paquete; se devuelve para documentarla en el reporte y dar visibilidad
    // de lo que el instalador borro del sistema base.
    public static List<string> GetDeletedFiles(DiffEngine pre, DiffEngine post) {
        List<string> deleted = new List<string>();
        foreach (var kvp in pre.FileSnapshot) {
            if (IsFilePathUncertain(pre, kvp.Key) || IsFilePathUncertain(post, kvp.Key)) continue;
            if (!post.FileSnapshot.ContainsKey(kvp.Key)) {
                deleted.Add(kvp.Key);
            }
        }
        return deleted;
    }

    private static bool IsFilePathUncertain(DiffEngine engine, string path) {
        if (string.IsNullOrEmpty(path)) return false;
        string cursor = path.TrimEnd('\\', '/');
        while (!string.IsNullOrEmpty(cursor)) {
            if (engine.FileScanUncertainPaths.ContainsKey(cursor)) return true;
            int slash = cursor.LastIndexOf('\\');
            if (slash <= 2) break;
            cursor = cursor.Substring(0, slash);
        }
        return false;
    }

    // =================================================================
    //  SISTEMA DE SERIALIZACION BINARIA (SUPERVIVENCIA A REINICIOS)
    // =================================================================
    public void SaveState(string filePath) {
        using (FileStream fs = new FileStream(filePath, FileMode.Create))
        using (BinaryWriter bw = new BinaryWriter(fs, System.Text.Encoding.UTF8)) {
            bw.Write(0x44504445); // DPDE
            bw.Write(6);          // version del formato (detalle de fallos de lectura)

            // 1. Guardar Archivos
            bw.Write(FileSnapshot.Count);
            foreach (var kvp in FileSnapshot) {
                bw.Write(kvp.Key);
                bw.Write(kvp.Value);
            }

            bw.Write(FileScanUncertainPaths.Count);
            foreach (var kvp in FileScanUncertainPaths) bw.Write(kvp.Key);

            bw.Write(FileScanFailureDetails.Count);
            foreach (var kvp in FileScanFailureDetails) {
                bw.Write(kvp.Key);
                bw.Write(kvp.Value ?? "");
            }

            bw.Write(ReparsePointSnapshot.Count);
            foreach (var kvp in ReparsePointSnapshot) {
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


            bw.Write(RegScanErrors.Count);
            foreach (string path in RegScanErrors) bw.Write(path);
        }
    }

    private static int ReadSafeCount(BinaryReader br, string label, int maxValue) {
        int count = br.ReadInt32();
        if (count < 0 || count > maxValue) throw new InvalidDataException("Conteo invalido en snapshot (" + label + "): " + count);
        return count;
    }

    public static DiffEngine LoadState(string filePath) {
        DiffEngine engine = new DiffEngine();
        using (FileStream fs = new FileStream(filePath, FileMode.Open))
        using (BinaryReader br = new BinaryReader(fs, System.Text.Encoding.UTF8)) {
            int marker = br.ReadInt32();
            if (marker != 0x44504445) throw new InvalidDataException("Cabecera de snapshot invalida. Inicia una captura nueva.");
            int stateVersion = ReadSafeCount(br, "version", 6);
            if (stateVersion != 6) throw new InvalidDataException("El snapshot no usa el formato requerido por esta compilacion. Inicia una captura nueva.");
            int fileCount = ReadSafeCount(br, "archivos", 10000000);

            // 1. Cargar Archivos
            for (int i = 0; i < fileCount; i++) {
                string key = br.ReadString();
                string val = br.ReadString();
                engine.FileSnapshot[key] = val;
            }

            int uncertainCount = ReadSafeCount(br, "rutas de archivos inciertas", 10000000);
            for (int i = 0; i < uncertainCount; i++) engine.FileScanUncertainPaths[br.ReadString()] = 0;

            int failureDetailCount = ReadSafeCount(br, "detalles de fallos de archivos", 10000000);
            for (int i = 0; i < failureDetailCount; i++) {
                engine.FileScanFailureDetails[br.ReadString()] = br.ReadString();
            }

            int reparseCount = ReadSafeCount(br, "reparse points", 10000000);
            for (int i = 0; i < reparseCount; i++) {
                engine.ReparsePointSnapshot[br.ReadString()] = br.ReadString();
            }

            // 2. Cargar Registro
            int regCount = ReadSafeCount(br, "claves de registro", 5000000);
            for (int i = 0; i < regCount; i++) {
                string keyPath = br.ReadString();
                int valCount = ReadSafeCount(br, "valores de registro", 1000000);
                var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                for (int j = 0; j < valCount; j++) {
                    values[br.ReadString()] = br.ReadString();
                }
                engine.RegSnapshot[keyPath] = values;
            }

            int regErrorCount = ReadSafeCount(br, "errores de registro", 5000000);
            for (int i = 0; i < regErrorCount; i++) engine.RegScanErrors.Add(br.ReadString());
            if (fs.Position != fs.Length) throw new InvalidDataException("El snapshot contiene datos no reconocidos. Inicia una captura nueva.");
        }
        return engine;
    }
}
