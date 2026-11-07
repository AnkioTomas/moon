param(
    [string]$FontPath = "$env:WINDIR\Fonts\msyh.ttc",
    [Parameter(Mandatory = $true)][string]$OutputPath
)

$ErrorActionPreference = "Stop"
# Generate Unicode fingerprints on Windows; no font bytes or outlines are exported.
Add-Type -AssemblyName PresentationCore
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Windows.Media;

public class TaduFontIndex {
    readonly byte[] data;
    readonly Dictionary<string, int> tables = new Dictionary<string, int>();
    readonly int em, metrics;
    readonly bool longLoca;

    int U16(int p) { return data[p] * 256 + data[p + 1]; }
    int I16(int p) { int n = U16(p); return n >= 32768 ? n - 65536 : n; }
    int U32(int p) { return checked(U16(p) * 65536 + U16(p + 2)); }
    int Scaled(int n) { return (int)Math.Floor(n * 2048.0 / em + 0.5); }

    TaduFontIndex(string path) {
        data = File.ReadAllBytes(path);
        int face = Encoding.ASCII.GetString(data, 0, 4) == "ttcf" ? U32(12) : 0;
        for (int i = 0; i < U16(face + 4); i++) {
            int p = face + 12 + i * 16;
            tables[Encoding.ASCII.GetString(data, p, 4)] = U32(p + 8);
        }
        em = U16(tables["head"] + 18);
        longLoca = I16(tables["head"] + 50) == 1;
        metrics = U16(tables["hhea"] + 34);
    }

    int[] Axis(byte[] flags, ref int pos, int shortBit, int sameBit) {
        var values = new int[flags.Length];
        int current = 0;
        for (int i = 0; i < flags.Length; i++) {
            if ((flags[i] & shortBit) != 0) {
                int delta = data[pos++];
                current += (flags[i] & sameBit) != 0 ? delta : -delta;
            } else if ((flags[i] & sameBit) == 0) {
                current += I16(pos);
                pos += 2;
            }
            values[i] = current;
        }
        return values;
    }

    string Fingerprint(int gid) {
        int loc = tables["loca"] + gid * (longLoca ? 4 : 2);
        int from = longLoca ? U32(loc) : U16(loc) * 2;
        int to = longLoca ? U32(loc + 4) : U16(loc + 2) * 2;
        if (from == to) return null;
        int pos = tables["glyf"] + from;
        int contours = I16(pos);
        if (contours <= 0) return null;
        pos += 10;
        var ends = new int[contours];
        for (int i = 0; i < contours; i++, pos += 2) ends[i] = U16(pos);
        int count = ends[contours - 1] + 1;
        pos += U16(pos) + 2;
        var flags = new byte[count];
        for (int i = 0; i < count; i++) {
            byte flag = data[pos++];
            flags[i] = flag;
            if ((flag & 8) != 0) {
                int repeats = data[pos++];
                while (repeats-- > 0) flags[++i] = flag;
            }
        }
        int[] xs = Axis(flags, ref pos, 2, 16);
        int[] ys = Axis(flags, ref pos, 4, 32);
        var paths = new List<string>();
        int begin = 0;
        foreach (int end in ends) {
            var points = new List<string>();
            for (int i = begin; i <= end; i++) {
                points.Add((flags[i] & 1) + "," + Scaled(xs[i]) + "," + Scaled(ys[i]));
            }
            string best = null;
            for (int i = 0; i < points.Count; i++) {
                var rotated = new List<string>();
                for (int j = 0; j < points.Count; j++) rotated.Add(points[(i + j) % points.Count]);
                string value = String.Join(";", rotated);
                if (best == null || String.CompareOrdinal(value, best) < 0) best = value;
            }
            paths.Add(best);
            begin = end + 1;
        }
        paths.Sort(StringComparer.Ordinal);
        string shape = Scaled(U16(tables["hmtx"] + Math.Min(gid, metrics - 1) * 4))
            + "|" + String.Join("|", paths);
        using (var sha = SHA256.Create()) {
            return BitConverter.ToString(sha.ComputeHash(Encoding.ASCII.GetBytes(shape))).Replace("-", "").ToLowerInvariant();
        }
    }

    static int Canonical(int cp) {
        if ((cp >= 0xf900 && cp <= 0xfaff) || (cp >= 0x2f00 && cp <= 0x2fdf)) {
            string text = Char.ConvertFromUtf32(cp).Normalize(NormalizationForm.FormKC);
            if (text.Length == 1) return text[0];
        }
        return cp;
    }

    public static void Build(string path, string output) {
        var font = new TaduFontIndex(path);
        var face = new GlyphTypeface(new Uri(Path.GetFullPath(path)));
        var rows = new SortedDictionary<string, int>(StringComparer.Ordinal);
        var ambiguous = new HashSet<string>();
        foreach (var pair in face.CharacterToGlyphMap) {
            if (pair.Key < 32) continue;
            string hash = font.Fingerprint(pair.Value);
            if (hash == null || ambiguous.Contains(hash)) continue;
            int cp = Canonical(pair.Key);
            int old;
            if (rows.TryGetValue(hash, out old) && old != cp) {
                rows.Remove(hash);
                ambiguous.Add(hash);
            } else rows[hash] = cp;
        }
        // MTF1 + sorted records: full SHA-256 (32 bytes), Unicode (3 bytes, big-endian).
        using (var file = File.Create(output)) {
            file.Write(Encoding.ASCII.GetBytes("MTF1"), 0, 4);
            foreach (var row in rows) {
                for (int i = 0; i < row.Key.Length; i += 2) {
                    file.WriteByte(Convert.ToByte(row.Key.Substring(i, 2), 16));
                }
                file.WriteByte((byte)(row.Value >> 16));
                file.WriteByte((byte)(row.Value >> 8));
                file.WriteByte((byte)row.Value);
            }
        }
        Console.WriteLine("fingerprints={0}; ambiguous={1}", rows.Count, ambiguous.Count);
    }
}
'@ -ReferencedAssemblies PresentationCore, WindowsBase

[TaduFontIndex]::Build($FontPath, $OutputPath)
