#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${QL_CAMERA_INSTALL_DIR:-/opt/ql-camera}"
DATA_DIR="${QL_CAMERA_DATA_DIR:-/var/lib/ql-camera}"
MEDIA_DIR="${QL_CAMERA_MEDIA_DIR:-/srv/ql-camera/media}"
DEFAULT_RELEASE_REPOSITORY="pqminh-4/QL_Camera_Releases"
RELEASE_REPOSITORY="${QL_CAMERA_RELEASE_REPOSITORY:-${QL_CAMERA_REPOSITORY:-$DEFAULT_RELEASE_REPOSITORY}}"
SOURCE_DIR="${QL_CAMERA_SOURCE_DIR:-}"
AGENT_GROUP_ID="${QL_CAMERA_AGENT_GID:-1999}"
INSTALL_MODE="source"
RELEASE_API_IMAGE=""
RELEASE_WEB_IMAGE=""

cleanup_items=()
cleanup() {
  for item in "${cleanup_items[@]:-}"; do
    rm -rf -- "$item"
  done
}
trap cleanup EXIT

fail() {
  printf 'Lỗi: %s\n' "$1" >&2
  exit 1
}

note() {
  printf '\n[QL Camera] %s\n' "$1"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Hãy chạy installer bằng sudo."
}

preflight() {
  [[ "$INSTALL_DIR" == /* && "$INSTALL_DIR" != "/" ]] || fail "QL_CAMERA_INSTALL_DIR phải là đường dẫn tuyệt đối khác /."
  [[ "$DATA_DIR" == /* && "$DATA_DIR" != "/" ]] || fail "QL_CAMERA_DATA_DIR phải là đường dẫn tuyệt đối khác /."
  [[ "$MEDIA_DIR" == /* && "$MEDIA_DIR" != "/" ]] || fail "QL_CAMERA_MEDIA_DIR phải là đường dẫn tuyệt đối khác /."
  [[ -r /etc/os-release ]] || fail "Không nhận diện được hệ điều hành."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || fail "Bản đầu chỉ hỗ trợ Ubuntu Server."
  case "${VERSION_ID:-}" in
    24.04|26.04) ;;
    *) fail "Chỉ hỗ trợ Ubuntu 24.04 hoặc 26.04 LTS." ;;
  esac
  [[ "$(uname -m)" == "x86_64" ]] || fail "Bản đầu chỉ hỗ trợ amd64/x86_64."
  local available_kb
  available_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
  (( available_kb >= 15 * 1024 * 1024 )) || fail "Cần tối thiểu 15 GB trống để cài đặt."
}

install_docker() {
  local missing_tools=()
  local tool
  for tool in ca-certificates curl gnupg jq tar; do
    dpkg -s "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
  done
  if (( ${#missing_tools[@]} > 0 )); then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_tools[@]}"
  fi
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    systemctl enable --now docker
    return
  fi
  note "Cài Docker Engine và Compose từ repository chính thức"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg jq tar
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  source /etc/os-release
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker run --rm hello-world >/dev/null
}

copy_source_checkout() {
  local source="$1" target="$2"
  [[ "$(readlink -f "$source")" == "$(readlink -f "$target")" ]] && return
  (
    cd "$source"
    tar \
      --exclude=.git \
      --exclude=node_modules \
      --exclude='*/node_modules' \
      --exclude=dist \
      --exclude='*/dist' \
      --exclude=.cache \
      --exclude=.env \
      --exclude='.env.backup-*' \
      --exclude=secrets \
      --exclude=data \
      --exclude=storage \
      --exclude=infra/frigate/config.yml \
      --exclude=infra/coturn/turnserver.generated.conf \
      -cf - .
  ) | (
    cd "$target"
    tar -xf -
  )
}

release_asset_url() {
  local release_json="$1" asset_name="$2"
  jq -er --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$release_json" | head -n 1
}

verify_checksum() {
  local checksum_path="$1" asset_path="$2"
  local expected_name actual_name
  expected_name="$(basename "$asset_path")"
  actual_name="$(awk 'NF >= 2 { name=$2; sub(/^\*/, "", name); print name; exit }' "$checksum_path")"
  [[ "$actual_name" == "$expected_name" ]] || fail "Checksum không trỏ đúng asset ${expected_name}."
  (
    cd "$(dirname "$asset_path")"
    sha256sum --check --status "$(basename "$checksum_path")"
  ) || fail "Checksum không hợp lệ cho ${expected_name}."
}

validate_image_digest() {
  local image="$1"
  [[ "$image" =~ ^ghcr\.io/[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*@sha256:[a-f0-9]{64}$ ]]
}

validate_release_archive() {
  local archive_path="$1" entry archive_list
  archive_list="$(tar -tzf "$archive_path")" || fail "Không đọc được danh sách deploy bundle."
  while IFS= read -r entry; do
    [[ "$entry" != /* && "$entry" != ../* && "$entry" != */../* ]] || fail "Deploy bundle chứa đường dẫn không an toàn."
  done <<<"$archive_list"
  if grep -Eq '(^|/)(\.git|node_modules|dist|tests?|coverage|secrets|data|storage)(/|$)|\.(ts|tsx|go|map)$|(^|/)\.env$' <<<"$archive_list"; then
    fail "Deploy bundle chứa source, secret hoặc artifact không được phép."
  fi
}

download_source() {
  mkdir -p "$INSTALL_DIR"
  if [[ -n "$SOURCE_DIR" ]]; then
    [[ -f "$SOURCE_DIR/docker-compose.yml" ]] || fail "QL_CAMERA_SOURCE_DIR không trỏ tới source hợp lệ."
    copy_source_checkout "$SOURCE_DIR" "$INSTALL_DIR"
    INSTALL_MODE="source"
    return
  fi
  [[ "$RELEASE_REPOSITORY" != "pqminh-4/QL_Camera_Releases" ]] || fail "Installer chưa được gắn repository phát hành."
  [[ "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "QL_CAMERA_RELEASE_REPOSITORY phải có dạng owner/repository."
  local temp_dir release_json version bundle_name bundle_checksum_name agent_name agent_checksum_name manifest_name
  local bundle_url bundle_checksum_url agent_url agent_checksum_url manifest_url staging_dir
  temp_dir="$(mktemp -d)"
  cleanup_items+=("$temp_dir")
  release_json="$(curl -fsSL "https://api.github.com/repos/${RELEASE_REPOSITORY}/releases/latest")" || fail "Không tải được metadata release public."
  version="$(jq -er '.tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+([-.][0-9A-Za-z.-]+)?$"))' <<<"$release_json")" || fail "Release mới nhất không có tag phiên bản hợp lệ."
  bundle_name="ql-camera-deploy-bundle-${version}.tar.gz"
  bundle_checksum_name="${bundle_name}.sha256"
  agent_name="ql-camera-agent-linux-amd64"
  agent_checksum_name="${agent_name}.sha256"
  manifest_name="release-manifest.json"
  bundle_url="$(release_asset_url "$release_json" "$bundle_name")" || fail "Release thiếu deploy bundle."
  bundle_checksum_url="$(release_asset_url "$release_json" "$bundle_checksum_name")" || fail "Release thiếu checksum deploy bundle."
  agent_url="$(release_asset_url "$release_json" "$agent_name")" || fail "Release thiếu host-agent."
  agent_checksum_url="$(release_asset_url "$release_json" "$agent_checksum_name")" || fail "Release thiếu checksum host-agent."
  manifest_url="$(release_asset_url "$release_json" "$manifest_name")" || fail "Release thiếu manifest."
  note "Tải QL Camera ${version}"
  curl -fsSL "$bundle_url" -o "$temp_dir/$bundle_name"
  curl -fsSL "$bundle_checksum_url" -o "$temp_dir/$bundle_checksum_name"
  curl -fsSL "$agent_url" -o "$temp_dir/$agent_name"
  curl -fsSL "$agent_checksum_url" -o "$temp_dir/$agent_checksum_name"
  curl -fsSL "$manifest_url" -o "$temp_dir/$manifest_name"
  verify_checksum "$temp_dir/$bundle_checksum_name" "$temp_dir/$bundle_name"
  verify_checksum "$temp_dir/$agent_checksum_name" "$temp_dir/$agent_name"
  [[ "$(jq -er '.version' "$temp_dir/$manifest_name")" == "$version" ]] || fail "Phiên bản manifest không khớp release."
  [[ "$(jq -er '.commit | select(test("^[a-f0-9]{40}$"))' "$temp_dir/$manifest_name")" ]] || fail "Commit trong manifest không hợp lệ."
  RELEASE_API_IMAGE="$(jq -er '.images.api' "$temp_dir/$manifest_name")" || fail "Manifest thiếu image API."
  RELEASE_WEB_IMAGE="$(jq -er '.images.web' "$temp_dir/$manifest_name")" || fail "Manifest thiếu image web."
  validate_image_digest "$RELEASE_API_IMAGE" || fail "Image API không được ghim bằng GHCR digest hợp lệ."
  validate_image_digest "$RELEASE_WEB_IMAGE" || fail "Image web không được ghim bằng GHCR digest hợp lệ."
  validate_release_archive "$temp_dir/$bundle_name"
  staging_dir="$temp_dir/bundle"
  mkdir -p "$staging_dir"
  tar --no-same-owner --no-same-permissions -xzf "$temp_dir/$bundle_name" -C "$staging_dir"
  [[ -f "$staging_dir/docker-compose.yml" && -f "$staging_dir/apps/host-agent/ql-camera-agent.service" ]] || fail "Deploy bundle thiếu cấu hình runtime bắt buộc."
  # Xóa source legacy trong thư mục ứng dụng nhưng giữ nguyên secret, dữ liệu và cấu hình runtime.
  rm -rf -- "$INSTALL_DIR/apps" "$INSTALL_DIR/packages" "$INSTALL_DIR/deploy"
  copy_source_checkout "$staging_dir" "$INSTALL_DIR"
  install -D -m 0755 "$temp_dir/$agent_name" "$INSTALL_DIR/apps/host-agent/ql-camera-agent"
  INSTALL_MODE="release"
}

random_secret() {
  dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d '\n'
}

read_env_value() {
  local path="$1" key="$2"
  [[ -f "$path" ]] || return 1
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$path"
}

ensure_env_value() {
  local path="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$path" 2>/dev/null; then
    return
  fi
  printf '%s=%s\n' "$key" "$value" >>"$path"
}

set_env_value() {
  local path="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$path" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$path"
  else
    printf '%s=%s\n' "$key" "$value" >>"$path"
  fi
}

env_needs_update() {
  local path="$1"
  shift
  local key
  for key in "$@"; do
    grep -q "^${key}=" "$path" 2>/dev/null || return 0
  done
  return 1
}

generate_configuration() {
  note "Sinh secret và cấu hình local-first"
  umask 077
  mkdir -p "$INSTALL_DIR/secrets" "$DATA_DIR/runtime-secrets" "$DATA_DIR/frigate" "$MEDIA_DIR"
  [[ -s "$INSTALL_DIR/secrets/master_key" ]] || random_secret >"$INSTALL_DIR/secrets/master_key"
  [[ -s "$INSTALL_DIR/secrets/postgres_password" ]] || random_secret >"$INSTALL_DIR/secrets/postgres_password"
  [[ -s "$INSTALL_DIR/secrets/turn_shared_secret" ]] || random_secret >"$INSTALL_DIR/secrets/turn_shared_secret"
  [[ -s "$INSTALL_DIR/secrets/mqtt_password" ]] || random_secret >"$INSTALL_DIR/secrets/mqtt_password"
  local bootstrap_token expires_at mqtt_password rtsp_password turn_secret env_path api_image web_image
  env_path="$INSTALL_DIR/.env"
  bootstrap_token=""
  expires_at=""
  if [[ -s "$INSTALL_DIR/secrets/bootstrap_token.json" ]]; then
    bootstrap_token="$(jq -r '.token // empty' "$INSTALL_DIR/secrets/bootstrap_token.json")"
    expires_at="$(jq -r '.expiresAt // empty' "$INSTALL_DIR/secrets/bootstrap_token.json")"
  fi
  if [[ -z "$bootstrap_token" || -z "$expires_at" || "$(date -u -d "$expires_at" +%s 2>/dev/null || printf 0)" -le "$(date -u +%s)" ]]; then
    bootstrap_token="$(random_secret)"
    expires_at="$(date -u -d '+30 minutes' '+%Y-%m-%dT%H:%M:%SZ')"
    printf '{"token":"%s","expiresAt":"%s"}\n' "$bootstrap_token" "$expires_at" >"$INSTALL_DIR/secrets/bootstrap_token.json"
  fi
  mqtt_password="$(<"$INSTALL_DIR/secrets/mqtt_password")"
  rtsp_password="$(read_env_value "$env_path" FRIGATE_RTSP_PASSWORD || true)"
  [[ -n "$rtsp_password" ]] || rtsp_password="$(random_secret)"
  turn_secret="$(<"$INSTALL_DIR/secrets/turn_shared_secret")"
  if [[ -s "$INSTALL_DIR/secrets/mosquitto_passwords" ]]; then
    docker run --rm -v "$INSTALL_DIR/secrets:/work" eclipse-mosquitto:2.0.22 \
      mosquitto_passwd -b /work/mosquitto_passwords ql_camera "$mqtt_password"
  else
    docker run --rm -v "$INSTALL_DIR/secrets:/work" eclipse-mosquitto:2.0.22 \
      mosquitto_passwd -b -c /work/mosquitto_passwords ql_camera "$mqtt_password"
  fi
  local frigate_template coturn_template
  if [[ ! -s "$DATA_DIR/frigate/config.yml" ]]; then
    frigate_template="$(<"$INSTALL_DIR/infra/frigate/config.example.yml")"
    frigate_template="${frigate_template//\{FRIGATE_MQTT_PASSWORD\}/$mqtt_password}"
    printf '%s\n' "$frigate_template" >"$DATA_DIR/frigate/config.yml"
  fi
  if [[ ! -s "$INSTALL_DIR/infra/coturn/turnserver.generated.conf" ]]; then
    coturn_template="$(<"$INSTALL_DIR/infra/coturn/turnserver.conf")"
    coturn_template="${coturn_template//\{TURN_SHARED_SECRET\}/$turn_secret}"
    coturn_template="${coturn_template//\{TURN_REALM\}/ql-camera.local}"
    printf '%s\n' "$coturn_template" >"$INSTALL_DIR/infra/coturn/turnserver.generated.conf"
  fi
  touch "$env_path"
  api_image="${RELEASE_API_IMAGE:-ql-camera-api:local}"
  web_image="${RELEASE_WEB_IMAGE:-ql-camera-web:local}"
  local env_keys=(
    POSTGRES_DB POSTGRES_USER FRIGATE_RTSP_PASSWORD QL_CAMERA_DATA_DIR QL_CAMERA_MEDIA_DIR
    QL_CAMERA_DOMAIN QL_CAMERA_AGENT_GID QL_CAMERA_API_IMAGE QL_CAMERA_WEB_IMAGE WEB_PORT PUBLIC_ORIGIN TZ
  )
  if env_needs_update "$env_path" "${env_keys[@]}" && [[ -s "$env_path" ]]; then
    cp -a "$env_path" "$env_path.backup-$(date -u '+%Y%m%dT%H%M%SZ')"
  fi
  ensure_env_value "$env_path" POSTGRES_DB ql_camera
  ensure_env_value "$env_path" POSTGRES_USER ql_camera
  ensure_env_value "$env_path" FRIGATE_RTSP_PASSWORD "$rtsp_password"
  ensure_env_value "$env_path" QL_CAMERA_DATA_DIR "$DATA_DIR"
  ensure_env_value "$env_path" QL_CAMERA_MEDIA_DIR "$MEDIA_DIR"
  ensure_env_value "$env_path" QL_CAMERA_DOMAIN http://:80
  ensure_env_value "$env_path" QL_CAMERA_AGENT_GID "$AGENT_GROUP_ID"
  if [[ "$INSTALL_MODE" == "release" ]]; then
    set_env_value "$env_path" QL_CAMERA_API_IMAGE "$api_image"
    set_env_value "$env_path" QL_CAMERA_WEB_IMAGE "$web_image"
  else
    ensure_env_value "$env_path" QL_CAMERA_API_IMAGE "$api_image"
    ensure_env_value "$env_path" QL_CAMERA_WEB_IMAGE "$web_image"
  fi
  ensure_env_value "$env_path" WEB_PORT 8080
  ensure_env_value "$env_path" PUBLIC_ORIGIN http://localhost:8080
  ensure_env_value "$env_path" TZ Asia/Ho_Chi_Minh
  chmod 0700 "$INSTALL_DIR/secrets" "$DATA_DIR/frigate"
  chmod 0750 "$DATA_DIR/runtime-secrets"
  chmod 0600 "$INSTALL_DIR/secrets/"* "$INSTALL_DIR/.env" "$DATA_DIR/frigate/config.yml" "$INSTALL_DIR/infra/coturn/turnserver.generated.conf"
  # User Mosquitto trong image chính thức dùng UID/GID 1883 và chỉ cần quyền đọc file mật khẩu.
  chown 1883:1883 "$INSTALL_DIR/secrets/mosquitto_passwords"
  INSTALL_BOOTSTRAP_TOKEN="$bootstrap_token"
}

install_host_agent() {
  note "Cài host agent allowlist"
  if ! getent group ql-camera-agent >/dev/null; then
    groupadd --system --gid "$AGENT_GROUP_ID" ql-camera-agent
  fi
  if [[ ! -x "$INSTALL_DIR/apps/host-agent/ql-camera-agent" ]]; then
    [[ "$INSTALL_MODE" == "source" ]] || fail "Release không có host-agent đã xác minh."
    docker run --rm -v "$INSTALL_DIR/apps/host-agent:/src" -w /src golang:1.23-bookworm \
      go build -trimpath -ldflags="-s -w" -o /src/ql-camera-agent .
  fi
  install -D -m 0755 "$INSTALL_DIR/apps/host-agent/ql-camera-agent" /usr/local/lib/ql-camera/ql-camera-agent
  install -m 0644 "$INSTALL_DIR/apps/host-agent/ql-camera-agent.service" /etc/systemd/system/ql-camera-agent.service
  printf 'QL_CAMERA_PROJECT_DIR=%q\nQL_CAMERA_MEDIA_DIR=%q\n' "$INSTALL_DIR" "$MEDIA_DIR" >/etc/default/ql-camera-agent
  chmod 0644 /etc/default/ql-camera-agent
  systemctl daemon-reload
  systemctl enable --now ql-camera-agent.service
}

start_stack() {
  cd "$INSTALL_DIR"
  if [[ "$INSTALL_MODE" == "release" ]]; then
    note "Tải image đã phát hành và khởi động các service"
    docker compose pull postgres mosquitto frigate api web caddy
    docker compose up -d --no-build
  else
    note "Build source local và khởi động các service"
    docker compose pull postgres mosquitto frigate caddy
    docker compose up -d --build
  fi
  for _ in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:8080/api/v1/health >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done
  docker compose ps
  fail "API không khỏe sau 120 giây. Hãy kiểm tra docker compose logs api."
}

finish() {
  local lan_ip
  lan_ip="$(hostname -I | awk '{print $1}')"
  printf '\nQL Camera Home đã sẵn sàng.\n'
  printf 'Mở: http://%s:8080/#token=%s\n' "$lan_ip" "$INSTALL_BOOTSTRAP_TOKEN"
  printf 'Bootstrap token hết hạn sau 30 phút và chỉ dùng để tạo Owner đầu tiên.\n'
  printf 'Dữ liệu: %s\nBản ghi: %s\n' "$DATA_DIR" "$MEDIA_DIR"
}

main() {
  require_root
  preflight
  install_docker
  download_source
  generate_configuration
  install_host_agent
  start_stack
  finish
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
