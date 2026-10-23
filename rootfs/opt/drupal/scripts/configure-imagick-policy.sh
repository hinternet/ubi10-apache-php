#!/usr/bin/env bash
# Build-time only. Enables SVG in the ImageMagick 7 policy and proves
# Imagick can rasterize SVG to PNG24 the way Drupal callers do
# (readImageBlob + FILTER_LANCZOS + setImageFormat("png24")).
# PDF / PostScript / MVG / MSVG stay denied. Resource caps are pinned here so
# a later ImageMagick RPM policy cannot loosen disk or area. Do not run this
# from the entrypoint: the root filesystem is read-only in the OpenShift example.
set -euo pipefail

marker="ubi10-apache-php: SVG"

shopt -s nullglob
policies=(/etc/ImageMagick-*/policy.xml)
if ((${#policies[@]} == 0)); then
    echo "ImageMagick policy.xml not found" >&2
    exit 1
fi

for policy in "${policies[@]}"; do
    if grep -q "${marker}" "${policy}"; then
        continue
    fi
    tmp="$(mktemp)"
    # mktemp is mode 0600. ImageMagick reads this file as the container UID.
    awk -v marker="${marker}" '
        /<\/policymap>/ && !inserted {
            print "  <!-- " marker " via librsvg. Ghostscript, MSVG, and URL coders stay denied. -->"
            print "  <policy domain=\"coder\" rights=\"read|write\" pattern=\"SVG\" />"
            print "  <policy domain=\"coder\" rights=\"none\" pattern=\"{MVG,MSVG,MSL,TEXT,EPS,PS,PS2,PS3,PDF,XPS,HTTP,HTTPS,URL}\" />"
            print "  <policy domain=\"path\" rights=\"none\" pattern=\"@*\" />"
            print "  <policy domain=\"resource\" name=\"memory\" value=\"256MiB\" />"
            print "  <policy domain=\"resource\" name=\"map\" value=\"512MiB\" />"
            print "  <policy domain=\"resource\" name=\"disk\" value=\"1GiB\" />"
            print "  <policy domain=\"resource\" name=\"area\" value=\"128MP\" />"
            print "  <policy domain=\"resource\" name=\"width\" value=\"16KP\" />"
            print "  <policy domain=\"resource\" name=\"height\" value=\"16KP\" />"
            print "  <policy domain=\"resource\" name=\"time\" value=\"60\" />"
            inserted=1
        }
        { print }
    ' "${policy}" > "${tmp}"
    mv "${tmp}" "${policy}"
    chmod 644 "${policy}"
    echo "patched ${policy}"
done

# Last matching policy wins. These lines must be in the appended block even
# when the marker was already present from an earlier run of this script.
for policy in "${policies[@]}"; do
    grep -q 'pattern="{MVG,MSVG,MSL,TEXT,EPS,PS,PS2,PS3,PDF,XPS,HTTP,HTTPS,URL}"' "${policy}" \
        || { echo "coder deny list missing in ${policy}" >&2; exit 1; }
    grep -q 'name="disk" value="1GiB"' "${policy}" \
        || { echo "disk cap missing in ${policy}" >&2; exit 1; }
    grep -q 'name="area" value="128MP"' "${policy}" \
        || { echo "area cap missing in ${policy}" >&2; exit 1; }
    grep -q 'name="memory" value="256MiB"' "${policy}" \
        || { echo "memory cap missing in ${policy}" >&2; exit 1; }
    grep -q 'name="map" value="512MiB"' "${policy}" \
        || { echo "map cap missing in ${policy}" >&2; exit 1; }
done

linked=0
while IFS= read -r -d '' coder; do
    if grep -a -q 'librsvg' "${coder}"; then
        linked=1
        echo "svg coder uses librsvg: ${coder}"
        break
    fi
done < <(find /usr/lib64 /usr/lib -path '*ImageMagick*' -name 'svg.so' -print0 2>/dev/null || true)
if [[ "${linked}" -ne 1 ]]; then
    echo "SVG coder is not linked to librsvg (internal MSVG is not enough)" >&2
    exit 1
fi

php <<'PHP'
<?php
$svg = '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32">'
    . '<rect width="32" height="32" fill="#ff0000"/>'
    . '<text x="4" y="20" font-size="12" fill="#00aa00">OK</text>'
    . '</svg>';
$im = new Imagick();
$im->readImageBlob($svg);
if (!defined('Imagick::FILTER_LANCZOS')) {
    fwrite(STDERR, "Imagick::FILTER_LANCZOS missing\n");
    exit(1);
}
$im->resizeImage(32, 32, Imagick::FILTER_LANCZOS, 1);
$im->setImageFormat('png24');
$blob = $im->getImageBlob();
if (!str_starts_with($blob, "\x89PNG")) {
    fwrite(STDERR, "SVG did not become a PNG\n");
    exit(1);
}
try {
    $pdf = new Imagick();
    $pdf->readImageBlob("%PDF-1.4\n");
    fwrite(STDERR, "PDF coder accepted a document\n");
    exit(1);
} catch (ImagickException $e) {
    $message = $e->getMessage();
    if (stripos($message, 'security policy') === false && stripos($message, 'not authorized') === false) {
        fwrite(STDERR, "PDF failure was not a policy denial: {$message}\n");
        exit(1);
    }
}
$msvg_tmp = tempnam(sys_get_temp_dir(), 'msvg');
if ($msvg_tmp === false) {
    fwrite(STDERR, "could not create MSVG probe\n");
    exit(1);
}
try {
    if (file_put_contents($msvg_tmp, $svg) === false) {
        fwrite(STDERR, "could not write MSVG probe\n");
        exit(1);
    }
    try {
        $msvg = new Imagick();
        // Content sniffing treats this blob as SVG. The msvg: prefix selects
        // the internal coder, which must stay denied while SVG (librsvg) is allowed.
        $msvg->readImage('msvg:' . $msvg_tmp);
        fwrite(STDERR, "MSVG coder accepted a document\n");
        exit(1);
    } catch (ImagickException $e) {
        $message = $e->getMessage();
        if (stripos($message, 'security policy') === false && stripos($message, 'not authorized') === false) {
            fwrite(STDERR, "MSVG failure was not a policy denial: {$message}\n");
            exit(1);
        }
    }
} finally {
    unlink($msvg_tmp);
}
fwrite(STDOUT, "imagick svg->png24 ok\n");
PHP
