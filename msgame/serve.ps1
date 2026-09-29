$root = $PSScriptRoot
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add('http://127.0.0.1:8177/')
$listener.Start()
Write-Output "serving $root on http://127.0.0.1:8177/"
while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  try {
    $p = [System.Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath)
    if ($p -eq '/') { $p = '/union-flag.html' }
    $rel = $p -replace '/', '\'
    $file = Join-Path $root $rel.Substring(1)
    if ((Test-Path $file -PathType Leaf) -and ($file.StartsWith($root))) {
      $bytes = [System.IO.File]::ReadAllBytes($file)
      $ctype = 'text/html; charset=utf-8'
      if ($file -like '*.js') { $ctype = 'text/javascript' }
      elseif ($file -like '*.css') { $ctype = 'text/css' }
      $ctx.Response.ContentType = $ctype
      $ctx.Response.ContentLength64 = $bytes.Length
      $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } else {
      $ctx.Response.StatusCode = 404
      $b = [System.Text.Encoding]::UTF8.GetBytes('not found')
      $ctx.Response.OutputStream.Write($b, 0, $b.Length)
    }
  } catch {
    try { $ctx.Response.StatusCode = 500 } catch {}
  } finally {
    try { $ctx.Response.OutputStream.Close() } catch {}
  }
}
