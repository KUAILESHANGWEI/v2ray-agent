#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
TARGET_REPO="${TARGET_REPO:-KUAILESHANGWEI/v2ray-agent}"
API_ROOT="https://api.github.com"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

auth_header=(-H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

api_get() {
  curl -fsSL "${auth_header[@]}" "$1"
}

ensure_release() {
  local tag=$1
  local title=$2
  local prerelease=${3:-false}
  local release_json

  if release_json="$(api_get "${API_ROOT}/repos/${TARGET_REPO}/releases/tags/${tag}" 2>/dev/null)"; then
    jq -r '.id' <<<"${release_json}"
    return
  fi

  curl -fsSL -X POST "${auth_header[@]}" \
    "${API_ROOT}/repos/${TARGET_REPO}/releases" \
    -d "$(jq -nc --arg tag "${tag}" --arg name "${title}" --argjson prerelease "${prerelease}" '{tag_name:$tag,name:$name,prerelease:$prerelease}')" |
    jq -r '.id'
}

asset_exists() {
  local release_id=$1
  local name=$2
  api_get "${API_ROOT}/repos/${TARGET_REPO}/releases/${release_id}/assets?per_page=100" |
    jq -e --arg name "${name}" '.[]|select(.name==$name)' >/dev/null
}

upload_asset() {
  local release_id=$1
  local file=$2
  local name
  name="$(basename "${file}")"

  if asset_exists "${release_id}" "${name}"; then
    echo "asset exists: ${name}"
    return
  fi

  curl -fsSL -X POST "${auth_header[@]}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"${file}" \
    "https://uploads.github.com/repos/${TARGET_REPO}/releases/${release_id}/assets?name=${name}" >/dev/null
  echo "uploaded: ${name}"
}

download_and_upload() {
  local release_id=$1
  local url=$2
  local name=$3
  local file="${TMP_DIR}/${name}"
  if asset_exists "${release_id}" "${name}"; then
    echo "asset exists: ${name}"
    return
  fi
  curl -fL --retry 5 --retry-delay 2 --retry-all-errors -o "${file}" "${url}"
  upload_asset "${release_id}" "${file}"
}

sync_release() {
  local source_repo=$1
  local tag_prefix=$2
  local limit=${3:-1}
  local releases

  releases="$(api_get "${API_ROOT}/repos/${source_repo}/releases?per_page=20")"
  jq -c --argjson limit "${limit}" 'map(select(.draft|not))[:$limit][]' <<<"${releases}" |
    while read -r release; do
      local upstream_tag mirror_tag release_id prerelease
      upstream_tag="$(jq -r '.tag_name' <<<"${release}")"
      prerelease="$(jq -r '.prerelease' <<<"${release}")"
      mirror_tag="${tag_prefix}${upstream_tag}"
      release_id="$(ensure_release "${mirror_tag}" "Mirror ${source_repo} ${upstream_tag}" "${prerelease}")"
      jq -r '.assets[] | @base64' <<<"${release}" |
        while read -r encoded; do
          local asset name url
          asset="$(base64 -d <<<"${encoded}")"
          name="$(jq -r '.name' <<<"${asset}")"
          url="$(jq -r '.browser_download_url' <<<"${asset}")"
          download_and_upload "${release_id}" "${url}" "${name}"
        done
    done
}

sync_release_matching() {
  local source_repo=$1
  local tag_prefix=$2
  local prerelease_filter=$3
  local asset_regex=$4
  local limit=${5:-1}
  local releases

  releases="$(api_get "${API_ROOT}/repos/${source_repo}/releases?per_page=30")"
  jq -c --argjson limit "${limit}" --argjson prerelease "${prerelease_filter}" 'map(select(.draft|not) | select(.prerelease==$prerelease))[:$limit][]' <<<"${releases}" |
    while read -r release; do
      local upstream_tag mirror_tag release_id prerelease
      upstream_tag="$(jq -r '.tag_name' <<<"${release}")"
      prerelease="$(jq -r '.prerelease' <<<"${release}")"
      mirror_tag="${tag_prefix}${upstream_tag}"
      release_id="$(ensure_release "${mirror_tag}" "Mirror ${source_repo} ${upstream_tag}" "${prerelease}")"
      jq -r --arg regex "${asset_regex}" '.assets[] | select(.name|test($regex)) | @base64' <<<"${release}" |
        while read -r encoded; do
          local asset name url
          asset="$(base64 -d <<<"${encoded}")"
          name="$(jq -r '.name' <<<"${asset}")"
          url="$(jq -r '.browser_download_url' <<<"${asset}")"
          download_and_upload "${release_id}" "${url}" "${name}"
        done
    done
}

sync_single_url_release() {
  local mirror_tag=$1
  local title=$2
  shift 2
  local release_id
  release_id="$(ensure_release "${mirror_tag}" "${title}" false)"
  while [[ $# -gt 0 ]]; do
    download_and_upload "${release_id}" "$1" "$2"
    shift 2
  done
}

sync_release "mack-a/v2ray-agent" "mirror-mack-a-v2ray-agent-" 1
sync_release_matching "SagerNet/sing-box" "mirror-SagerNet-sing-box-" false '^sing-box-.*-linux-(amd64|arm64)\\.tar\\.gz$'
sync_release_matching "SagerNet/sing-box" "mirror-SagerNet-sing-box-" true '^sing-box-.*-linux-(amd64|arm64)\\.tar\\.gz$'
sync_release_matching "XTLS/Xray-core" "mirror-XTLS-Xray-core-" false '^Xray-linux-(64|arm64-v8a)\\.zip$' 5
sync_release_matching "XTLS/Xray-core" "mirror-XTLS-Xray-core-" true '^Xray-linux-(64|arm64-v8a)\\.zip$'
sync_release_matching "Loyalsoldier/v2ray-rules-dat" "mirror-Loyalsoldier-v2ray-rules-dat-" false '^(geoip|geosite)\\.dat$'
sync_release_matching "XTLS/RealiTLScanner" "mirror-XTLS-RealiTLScanner-" false '^RealiTLScanner-linux-64$'
sync_release_matching "v2fly/v2ray-core" "mirror-v2fly-v2ray-core-" false '^v2ray-linux-(64|arm64-v8a)\\.zip$' 5
sync_release_matching "apernet/hysteria" "mirror-apernet-hysteria-" false '^hysteria-linux-(amd64|arm64)$'
sync_release_matching "apernet/hysteria" "mirror-apernet-hysteria-" true '^hysteria-linux-(amd64|arm64)$'
sync_release_matching "EAimTY/tuic" "mirror-EAimTY-tuic-" false '(x86_64|aarch64)-unknown-linux-musl$'

sync_single_url_release "mirror-badafans-warp-reg-v1.0" "Mirror badafans/warp-reg v1.0" \
  "https://github.com/badafans/warp-reg/releases/download/v1.0/main-linux-amd64" "main-linux-amd64" \
  "https://github.com/badafans/warp-reg/releases/download/v1.0/main-linux-arm64" "main-linux-arm64" \
  "https://github.com/badafans/warp-reg/releases/download/v1.0/main-linux-arm" "main-linux-arm"

sync_single_url_release "mirror-Johnshall-sing-geosite-latest" "Mirror Johnshall/sing-geosite latest" \
  "https://github.com/Johnshall/sing-geosite/releases/latest/download/geosite.db" "geosite.db"

sync_single_url_release "mirror-v2fly-domain-list-community-latest" "Mirror v2fly/domain-list-community latest" \
  "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat_plain.yml" "dlc.dat_plain.yml"

sync_single_url_release "mirror-ylx2016-Linux-NetSpeed-master" "Mirror ylx2016/Linux-NetSpeed scripts" \
  "https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcp.sh" "tcp.sh" \
  "https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcpx.sh" "tcpx.sh"

sync_single_url_release "mirror-MetaCubeX-meta-rules-dat-release" "Mirror MetaCubeX/meta-rules-dat release files" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geoip.dat" "geoip.dat" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geosite.dat" "geosite.dat" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geoip.metadb" "geoip.metadb" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/country.mmdb" "country.mmdb"

sync_single_url_release "mirror-MetaCubeX-metacubexd-gh-pages" "Mirror MetaCubeX/metacubexd gh-pages" \
  "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip" "gh-pages.zip"

sync_single_url_release "mirror-MetaCubeX-meta-rules-dat-sing" "Mirror MetaCubeX sing rule sets" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-ads-all.srs" "geosite-category-ads-all.srs" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/telegram.srs" "geosite-telegram.srs" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/telegram.srs" "geoip-telegram.srs" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/youtube.srs" "geosite-youtube.srs" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/netflix.srs" "geosite-netflix.srs" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/netflix.srs" "geoip-netflix.srs" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/openai@ads.srs" "openai@ads.srs" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/openai.srs" "geosite-openai.srs" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/apple.srs" "geosite-apple.srs" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/google.srs" "geosite-google.srs" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/google.srs" "geoip-google.srs" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/microsoft.srs" "geosite-microsoft.srs" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/geolocation-!cn.srs" "geosite-geolocation-!cn.srs" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/github.srs" "geosite-github.srs" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/private.srs" "geosite-private.srs" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/cn.srs" "geosite-cn.srs" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/private.srs" "geoip-private.srs" \
  "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cn.srs" "geoip-cn.srs"

sync_single_url_release "mirror-Loyalsoldier-clash-rules-release" "Mirror Loyalsoldier clash rules" \
  "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/reject.txt" "reject.txt" \
  "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/proxy.txt" "proxy.txt" \
  "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/direct.txt" "direct.txt" \
  "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/private.txt" "private.txt" \
  "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/gfw.txt" "gfw.txt" \
  "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/greatfire.txt" "greatfire.txt" \
  "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/tld-not-cn.txt" "tld-not-cn.txt" \
  "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/telegramcidr.txt" "telegramcidr.txt" \
  "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/applications.txt" "applications.txt"

sync_single_url_release "mirror-blackmatrix7-ios-rule-script-clash" "Mirror blackmatrix7 Clash rule YAML" \
  "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Lan/Lan.yaml" "Lan.yaml" \
  "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Disney/Disney.yaml" "Disney.yaml" \
  "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Netflix/Netflix.yaml" "Netflix.yaml" \
  "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/YouTube/YouTube.yaml" "YouTube.yaml" \
  "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/HBO/HBO.yaml" "HBO.yaml" \
  "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/OpenAI/OpenAI.yaml" "OpenAI.yaml" \
  "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Claude/Claude.yaml" "Claude.yaml" \
  "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Bing/Bing.yaml" "Bing.yaml" \
  "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Google/Google.yaml" "Google.yaml" \
  "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/GitHub/GitHub.yaml" "GitHub.yaml" \
  "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Spotify/Spotify.yaml" "Spotify.yaml" \
  "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/ChinaMax/ChinaMax_Domain.yaml" "ChinaMax_Domain.yaml" \
  "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/ChinaMax/ChinaMax_IP_No_IPv6.yaml" "ChinaMax_IP_No_IPv6.yaml"
