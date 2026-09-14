# Isolated OS-query microbenchmark. Not native proposal latency or a game FPS test.
[CmdletBinding()]
param([ValidateRange(5,100)][int]$Repeats = 20)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class Tpf2mpQueryCost {
  [StructLayout(LayoutKind.Sequential)] public struct MemoryInfo {
    public IntPtr Base, AllocationBase;
    public uint AllocationProtect;
    public ushort PartitionId;
    public UIntPtr RegionSize;
    public uint State, Protect, Type;
  }
  [DllImport("kernel32.dll", SetLastError=true)] static extern UIntPtr VirtualQuery(
    IntPtr address, out MemoryInfo info, UIntPtr length);
  public static double Run(int edges, int checks) {
    var length=(UIntPtr)Marshal.SizeOf(typeof(MemoryInfo));
    if(IntPtr.Size!=8 || length.ToUInt64()!=48) throw new InvalidOperationException("x64 MEMORY_BASIC_INFORMATION required");
    IntPtr data = Marshal.AllocHGlobal(edges * 120);
    try {
      // Commit and touch the full allocation before timing.
      for (int i=0; i<edges * 120; i+=4096) Marshal.WriteByte(data, i, 0);
      var watch = Stopwatch.StartNew();
      for (int i=0; i<edges; ++i) for (int j=0; j<checks; ++j) {
        MemoryInfo info;
        if (VirtualQuery(IntPtr.Add(data, i*120+j*4), out info, length) == UIntPtr.Zero)
          throw new InvalidOperationException("VirtualQuery failed");
      }
      return watch.Elapsed.TotalMilliseconds;
    } finally { Marshal.FreeHGlobal(data); }
  }
}
'@
[void][Tpf2mpQueryCost]::Run(128,21)
$rows = foreach ($edges in @(1,16,128,1024,8192)) {
    foreach ($checks in @(21,1)) {
        $values = @(for ($i=0; $i -lt $Repeats; $i++) { [Tpf2mpQueryCost]::Run($edges,$checks) }) | Sort-Object
        [ordered]@{ edges=$edges; queriesPerRecord=$checks; repeats=$Repeats
            medianMs=$values[[int][Math]::Floor($values.Count/2)]
            minimumMs=$values[0]; maximumMs=$values[-1] }
    }
}
[ordered]@{ scope='isolated VirtualQuery call cost; not complete decoder timing; one-check variant is not a validated replacement'
    rows=@($rows) } | ConvertTo-Json -Depth 4
