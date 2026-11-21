#Requires -Version 5.1
<#
.SYNOPSIS
  Dump KS topology nodes for Fast Track Duo via IOCTL_KS_PROPERTY.
#>
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public static class KsTopo {
  public const int DIGCF_PRESENT = 0x2;
  public const int DIGCF_DEVICEINTERFACE = 0x10;
  public static readonly Guid GUID_KSCATEGORY_AUDIO = new Guid("6994AD04-93EF-11D0-A3CC-00A0C9223196");
  public static readonly Guid KSPROPSETID_Topology = new Guid("720D4AC0-7533-11D0-A5D6-28DB04C10000");
  public const int KSPROPERTY_TOPOLOGY_NODES = 1;
  public const int IOCTL_KS_PROPERTY = unchecked((int)0x002F0003); // CTL_CODE(0x2F,0,METHOD_NEITHER,FILE_ANY_ACCESS) approx
  // FILE_DEVICE_KS=0x2F, FUNCTION=0, METHOD_NEITHER=3, ACCESS=FILE_ANY_ACCESS=0
  // CTL_CODE = (DeviceType<<16) | (Access<<14) | (Function<<2) | Method
  // = 0x002F0000 | 0 | 0 | 3 = 0x002F0003

  [StructLayout(LayoutKind.Sequential)]
  public struct SP_DEVICE_INTERFACE_DATA {
    public int cbSize;
    public Guid InterfaceClassGuid;
    public int Flags;
    public IntPtr Reserved;
  }

  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)]
  public struct SP_DEVICE_INTERFACE_DETAIL_DATA {
    public int cbSize;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=1024)]
    public string DevicePath;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct KSPROPERTY {
    public Guid Set;
    public int Id;
    public int Flags;
  }

  [DllImport("setupapi.dll", CharSet=CharSet.Auto, SetLastError=true)]
  public static extern IntPtr SetupDiGetClassDevs(ref Guid ClassGuid, string Enumerator, IntPtr hwnd, int Flags);

  [DllImport("setupapi.dll", SetLastError=true)]
  public static extern bool SetupDiEnumDeviceInterfaces(IntPtr h, IntPtr data, ref Guid guid, int index, ref SP_DEVICE_INTERFACE_DATA iface);

  [DllImport("setupapi.dll", CharSet=CharSet.Auto, SetLastError=true)]
  public static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr h, ref SP_DEVICE_INTERFACE_DATA iface, ref SP_DEVICE_INTERFACE_DETAIL_DATA detail, int size, out int required, IntPtr devinfo);

  [DllImport("setupapi.dll", SetLastError=true)]
  public static extern bool SetupDiDestroyDeviceInfoList(IntPtr h);

  [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
  public static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr template);

  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool DeviceIoControl(IntPtr h, int code, IntPtr inBuf, int inSize, IntPtr outBuf, int outSize, out int returned, IntPtr overlapped);

  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool CloseHandle(IntPtr h);

  public static List<string> ListAudioPaths() {
    var list = new List<string>();
    var g = GUID_KSCATEGORY_AUDIO;
    IntPtr h = SetupDiGetClassDevs(ref g, null, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (h == IntPtr.Zero || h == new IntPtr(-1)) return list;
    try {
      for (int i = 0; i < 256; i++) {
        var iface = new SP_DEVICE_INTERFACE_DATA();
        iface.cbSize = Marshal.SizeOf(iface);
        if (!SetupDiEnumDeviceInterfaces(h, IntPtr.Zero, ref g, i, ref iface)) break;
        var detail = new SP_DEVICE_INTERFACE_DETAIL_DATA();
        detail.cbSize = IntPtr.Size == 8 ? 8 : 6;
        int req;
        if (!SetupDiGetDeviceInterfaceDetail(h, ref iface, ref detail, Marshal.SizeOf(detail), out req, IntPtr.Zero)) {
          continue;
        }
        list.Add(detail.DevicePath);
      }
    } finally { SetupDiDestroyDeviceInfoList(h); }
    return list;
  }

  public static string[] DumpNodes(string path) {
    IntPtr h = CreateFile(path, 0xC0000000 /*GENERIC_READ|WRITE*/, 3, IntPtr.Zero, 3 /*OPEN_EXISTING*/, 0x40000000 /*OVERLAPPED? no*/, IntPtr.Zero);
    // FILE_FLAG not needed; use 0 for flags
    if (h == new IntPtr(-1)) {
      h = CreateFile(path, 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
    }
    if (h == new IntPtr(-1)) return new[] { "CreateFile failed " + Marshal.GetLastWin32Error() };
    try {
      var prop = new KSPROPERTY();
      prop.Set = KSPROPSETID_Topology;
      prop.Id = KSPROPERTY_TOPOLOGY_NODES;
      prop.Flags = 1; // KSPROPERTY_TYPE_GET
      int propSize = Marshal.SizeOf(prop);
      IntPtr inBuf = Marshal.AllocHGlobal(propSize);
      Marshal.StructureToPtr(prop, inBuf, false);
      int outBytes = 64 * 16; // 64 GUIDs
      IntPtr outBuf = Marshal.AllocHGlobal(outBytes);
      try {
        int ret;
        // METHOD_NEITHER: pass pointers carefully — for managed, use DeviceIoControl with buffers
        bool ok = DeviceIoControl(h, unchecked((int)0x002F0003), inBuf, propSize, outBuf, outBytes, out ret, IntPtr.Zero);
        if (!ok) {
          int err = Marshal.GetLastWin32Error();
          // try IOCTL with FILE_ANY_ACCESS alternate calc
          return new[] { "DeviceIoControl failed err=" + err + " ret=" + ret };
        }
        int count = ret / 16;
        var names = new string[count];
        byte[] raw = new byte[ret];
        Marshal.Copy(outBuf, raw, 0, ret);
        for (int i = 0; i < count; i++) {
          byte[] g = new byte[16];
          Array.Copy(raw, i * 16, g, 0, 16);
          var guid = new Guid(g);
          names[i] = i + ": " + guid.ToString() + " " + NodeName(guid);
        }
        return names;
      } finally {
        Marshal.FreeHGlobal(inBuf);
        Marshal.FreeHGlobal(outBuf);
      }
    } finally { CloseHandle(h); }
  }

  static string NodeName(Guid g) {
    if (g == new Guid("3A5ACC00-C557-11CE-8D04-00AA0060F5BF")) return "VOLUME";
    if (g == new Guid("02B223C0-C557-11CE-8D04-00AA0060F5BF")) return "MUTE";
    if (g == new Guid("28BBD440-C557-11CE-8D04-00AA0060F5BF")) return "SUM";
    if (g == new Guid("35AFA6E6-C557-11CE-8D04-00AA0060F5BF")) return "MUX";
    if (g == new Guid("941C7AC0-C557-11CE-8D04-00AA0060F5BF")) return "SRC";
    if (g == new Guid("1864A4AE-0A66-11D2-B79A-00A0C9223196")) return "DAC";
    if (g == new Guid("4D837FE0-C555-11CE-8D04-00AA0060F5BF")) return "ADC";
    if (g == new Guid("1C22C56D-9879-4F5B-A2B9-A93A6BD47205")) return "SPEAKER";
    if (g == new Guid("DFF21CE1-F70F-11D0-B917-00A0C9223196")) return "SPEAKER_NODETYPE";
    return "";
  }
}
"@ -ErrorAction Stop

# Fix IOCTL - compute properly
# CTL_CODE(FILE_DEVICE_KS=0x2F, 0, METHOD_NEITHER=3, FILE_ANY_ACCESS=0) = 0x002F0003 — OK

Write-Host 'Enumerating KSCATEGORY_AUDIO interfaces...'
$paths = [KsTopo]::ListAudioPaths()
$duo = $paths | Where-Object { $_ -match 'VID_0B0F|PID_2036|0B0F|2036' }
if (-not $duo) {
  Write-Host 'No path matched VID_0B0F; dumping all paths (filter by hand):'
  $paths | ForEach-Object { Write-Host "  $_" }
  $duo = $paths
}

foreach ($p in $duo) {
  Write-Host ""
  Write-Host "=== $p ==="
  try {
    $nodes = [KsTopo]::DumpNodes($p)
    $nodes | ForEach-Object { Write-Host $_ }
  } catch {
    Write-Host "ERR: $_"
  }
}
