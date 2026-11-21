#Requires -Version 5.1
<#
.SYNOPSIS
  Disable exclusive mode on Fast Track Duo endpoints via MMDevice IPropertyStore.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
  $maxTries = 8
  for ($try = 1; $try -le $maxTries; $try++) {
    Write-Host ("Elevating (UAC / PIN)... attempt {0}/{1}" -f $try, $maxTries)
    try {
      $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
      ) -PassThru -Wait -ErrorAction Stop
      exit $p.ExitCode
    } catch {
      Write-Host 'UAC cancelled — requesting again...'
      Start-Sleep -Seconds 1
    }
  }
  throw 'Elevation failed after repeated UAC prompts. Approve the UAC dialog (PIN OK).'
}

# Discover Duo endpoint GUIDs from MMDevices (readable) by VID/name blob
$duoGuids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($role in @('Render', 'Capture')) {
  $root = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$role"
  if (-not (Test-Path $root)) { continue }
  Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
    $propsPath = Join-Path $_.PSPath 'Properties'
    if (-not (Test-Path $propsPath)) { return }
    $props = Get-ItemProperty $propsPath -ErrorAction SilentlyContinue
    if ($null -eq $props) { return }
    $blob = @($props.PSObject.Properties | ForEach-Object { [string]$_.Value }) -join ' '
    if ($blob -match 'VID_0B0F|PID_2036|Fast Track Duo|Avid Fast Track Duo') {
      [void]$duoGuids.Add($_.PSChildName.Trim('{}'))
      Write-Host ("Found Duo MMDevice {0} {1}" -f $role, $_.PSChildName)
    }
  }
}
if ($duoGuids.Count -eq 0) {
  Write-Host 'No Duo endpoints found in MMDevices.'
  exit 3
}
$guidList = ($duoGuids -join ',')

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public static class DuoExclusive2 {
  const int CLSCTX_INPROC_SERVER = 1;
  const int STGM_READWRITE = 2;
  const int DEVICE_STATE_ACTIVE = 1;
  static readonly Guid CLSID_MMDeviceEnumerator = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
  static readonly Guid IID_IMMDeviceEnumerator = new Guid("A95664D2-9614-4F35-A746-DE8DB63617E6");

  [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumerator {
    int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IntPtr devices);
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IntPtr endpoint);
    int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IntPtr device);
    int RegisterEndpointNotificationCallback(IntPtr client);
    int UnregisterEndpointNotificationCallback(IntPtr client);
  }

  [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceCollection {
    int GetCount(out uint count);
    int Item(uint index, out IntPtr device);
  }

  [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDevice {
    int Activate(ref Guid iid, int dwClsCtx, IntPtr act, out IntPtr ppv);
    int OpenPropertyStore(int stgmAccess, out IntPtr properties);
    int GetId(out IntPtr id);
    int GetState(out int state);
  }

  [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPropertyStore {
    int GetCount(out uint cProps);
    int GetAt(uint iProp, out PROPERTYKEY pkey);
    int GetValue(ref PROPERTYKEY key, out PropVariant pv);
    int SetValue(ref PROPERTYKEY key, ref PropVariant pv);
    int Commit();
  }

  [StructLayout(LayoutKind.Sequential)]
  struct PROPERTYKEY { public Guid fmtid; public uint pid; }

  [StructLayout(LayoutKind.Explicit)]
  struct PropVariant {
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr pointerValue;
    [FieldOffset(8)] public uint uintValue;
  }

  [DllImport("ole32.dll")]
  static extern int CoCreateInstance(ref Guid clsid, IntPtr outer, int ctx, ref Guid iid, out IntPtr ppv);

  [DllImport("ole32.dll")]
  static extern void CoTaskMemFree(IntPtr pv);

  static PROPERTYKEY PK(string g, uint id) { return new PROPERTYKEY { fmtid = new Guid(g), pid = id }; }

  public static string Apply(string guidCsv) {
    var wanted = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    foreach (var g in guidCsv.Split(new[]{','}, StringSplitOptions.RemoveEmptyEntries))
      wanted.Add(g.Trim().Trim('{','}'));

    var sb = new StringBuilder();
    Guid clsid = CLSID_MMDeviceEnumerator;
    Guid iid = IID_IMMDeviceEnumerator;
    IntPtr pEnum;
    int hr = CoCreateInstance(ref clsid, IntPtr.Zero, CLSCTX_INPROC_SERVER, ref iid, out pEnum);
    if (hr != 0) return "CoCreateInstance failed 0x" + hr.ToString("X8");
    var enumer = (IMMDeviceEnumerator)Marshal.GetTypedObjectForIUnknown(pEnum, typeof(IMMDeviceEnumerator));
    Marshal.Release(pEnum);

    var keyExAllow = PK("b3f8fa53-0004-438e-9003-51a46e139bfc", 3);
    var keyExPri = PK("b3f8fa53-0004-438e-9003-51a46e139bfc", 4);
    var keySysFx = PK("1da5d803-d492-4edd-8c23-e0c0ffee7f0e", 5);

    int touched = 0;
    // Open by explicit MMDevice id — covers inactive/duplicate Duo endpoints too.
    string[] prefixes = new[] { "{0.0.0.00000000}.", "{0.0.1.00000000}." };
    foreach (var guid in wanted) {
      foreach (var prefix in prefixes) {
        string id = prefix + "{" + guid + "}";
        IntPtr pDev;
        hr = enumer.GetDevice(id, out pDev);
        if (hr != 0 || pDev == IntPtr.Zero) continue;
        var dev = (IMMDevice)Marshal.GetTypedObjectForIUnknown(pDev, typeof(IMMDevice));
        Marshal.Release(pDev);

        sb.AppendLine("Match id=" + id);
        IntPtr pStore;
        hr = dev.OpenPropertyStore(STGM_READWRITE, out pStore);
        if (hr != 0 || pStore == IntPtr.Zero) {
          sb.AppendLine("  OpenPropertyStore 0x" + hr.ToString("X8"));
          continue;
        }
        var store = (IPropertyStore)Marshal.GetTypedObjectForIUnknown(pStore, typeof(IPropertyStore));
        Marshal.Release(pStore);

        var zero = new PropVariant { vt = 19, uintValue = 0 };
        var one = new PropVariant { vt = 19, uintValue = 1 };
        int h1 = store.SetValue(ref keyExAllow, ref zero);
        int h2 = store.SetValue(ref keyExPri, ref zero);
        int h3 = store.SetValue(ref keySysFx, ref one);
        int hc = store.Commit();
        sb.AppendLine(string.Format("  allow=0x{0:X8} pri=0x{1:X8} sysfx=0x{2:X8} commit=0x{3:X8}", h1, h2, h3, hc));
        if (h1 == 0 && h2 == 0 && hc == 0) touched++;
      }
    }
    sb.AppendLine("touched_ok=" + touched);
    return sb.ToString();
  }
}
"@

$result = [DuoExclusive2]::Apply($guidList)
Write-Host $result
if ($result -notmatch 'touched_ok=[1-9]') { exit 2 }
exit 0
