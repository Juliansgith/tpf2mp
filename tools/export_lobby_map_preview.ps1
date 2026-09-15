[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceDirectory, [Parameter(Mandatory)][string]$OutputPath,
    [string]$PngPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (Test-Path -LiteralPath $OutputPath) { throw 'Refusing to overwrite preview evidence.' }
$bytes = [IO.File]::ReadAllBytes((Join-Path $EvidenceDirectory 'preview-native.rgba'))
if ($bytes.Length -lt 8 -or $bytes.Length -gt (1024*1024*4+8)) { throw 'Invalid native preview extent.' }
$width=[BitConverter]::ToUInt32($bytes,0); $height=[BitConverter]::ToUInt32($bytes,4)
if ($width -lt 1 -or $height -lt 1 -or $width -gt 1024 -or $height -gt 1024 -or $bytes.Length -ne (8+$width*$height*4)) {
    throw 'Invalid native preview dimensions.'
}
Add-Type -TypeDefinition @'
public static class Tpf2mpPreviewPixels {
    public static byte[] Bgra(byte[] source) {
        byte[] output = new byte[source.Length-8];
        for (int i=0; i<output.Length; i+=4) {
            output[i]=source[i+10]; output[i+1]=source[i+9];
            output[i+2]=source[i+8]; output[i+3]=source[i+11];
        }
        return output;
    }
}
'@
$source=New-Object Drawing.Bitmap([int]$width,[int]$height,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
$bitmap=$null; $graphics=$null; $locked=$null; $font=$null
try {
    $locked=$source.LockBits([Drawing.Rectangle]::new(0,0,$width,$height),[Drawing.Imaging.ImageLockMode]::WriteOnly,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bgra=[Tpf2mpPreviewPixels]::Bgra($bytes)
    [Runtime.InteropServices.Marshal]::Copy($bgra,0,$locked.Scan0,$bgra.Length)
    $source.UnlockBits($locked); $locked=$null
    $bitmap=New-Object Drawing.Bitmap(512,288,[Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics=[Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([Drawing.Color]::FromArgb(20,30,36))
    $graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $scale=[Math]::Min(512.0/$width,288.0/$height)
    $w=[int]($width*$scale); $h=[int]($height*$scale); $left=[int]((512-$w)/2); $top=[int]((288-$h)/2)
    $graphics.DrawImage($source,$left,$top,$w,$h)
    $font=New-Object Drawing.Font('Segoe UI',7,[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)
    # PS 5.1 returns the JSON array as one pipeline object; @() would wrap it
    # again, turning point.x into an array during the coordinate projection.
    $landmarks=Get-Content -LiteralPath (Join-Path $EvidenceDirectory 'preview-markers.json') -Raw | ConvertFrom-Json
    if ($landmarks.Count -gt 8192) { throw 'Too many native landmarks.' }
    foreach ($point in $landmarks) {
        if ($point.x -lt 0 -or $point.x -gt 1 -or $point.y -lt 0 -or $point.y -gt 1) { throw 'Invalid native landmark.' }
        $x=[int]($left+$point.x*$w); $y=[int]($top+$point.y*$h)
        if ($point.kind -eq 'town') {
            $graphics.FillEllipse([Drawing.Brushes]::Black,($x-3),($y-3),6,6)
            $graphics.FillEllipse([Drawing.Brushes]::White,($x-2),($y-2),4,4)
            $label=[string]$point.name
            $graphics.DrawString($label,$font,[Drawing.Brushes]::Black,[single]($x+4),[single]($y-2))
            $graphics.DrawString($label,$font,[Drawing.Brushes]::White,[single]($x+3),[single]($y-3))
        } else {
            $graphics.FillRectangle([Drawing.Brushes]::Black,($x-2),($y-2),5,5)
            $graphics.FillRectangle([Drawing.Brushes]::Orange,($x-1),($y-1),3,3)
        }
    }
    $graphics.Dispose(); $graphics=$null
    if ($PngPath) { $bitmap.Save([IO.Path]::GetFullPath($PngPath),[Drawing.Imaging.ImageFormat]::Png) }
    $locked=$bitmap.LockBits([Drawing.Rectangle]::new(0,0,512,288),[Drawing.Imaging.ImageLockMode]::ReadOnly,[Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $raw=New-Object byte[] (512*288*3)
    for ($row=0; $row -lt 288; $row++) {
        [Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($locked.Scan0,$row*$locked.Stride),$raw,$row*1536,1536)
    }
    $bitmap.UnlockBits($locked); $locked=$null
    [IO.File]::WriteAllBytes([IO.Path]::GetFullPath($OutputPath),$raw)
} finally {
    if ($graphics) { $graphics.Dispose() }
    if ($font) { $font.Dispose() }
    if ($bitmap) { $bitmap.Dispose() }
    $source.Dispose()
}
