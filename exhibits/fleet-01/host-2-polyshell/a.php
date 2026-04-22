<?php
// staged exhibit — APSB25-94 public advisory reconstruction — NOT customer data
// 2-layer obfuscation (base64 → gzinflate eval). Outer shell recognizable;
// inner payload is a placeholder executing `echo "BL-STAGE";` — no actual
// functionality. Intent reconstructor (Day 4) will walk both layers.
$_x="S03OyFdQcvLRDQ5xdHdVsgYA";
$y=gzinflate(base64_decode($_x));
// dormant-capability markers (commented for exhibit; do not execute)
// - cmd: $_POST['c'] -> system()
// - file: $_GET['a'] -> read/write
// - callback: curl POST to vagqea4wrlkdg.top/gate
eval($y);  // placeholder eval — $y resolves to `echo "BL-STAGE";` only
?>
