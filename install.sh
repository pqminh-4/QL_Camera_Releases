#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${QL_CAMERA_INSTALL_DIR:-/opt/ql-camera}"
DATA_DIR="${QL_CAMERA_DATA_DIR:-/var/lib/ql-camera}"
MEDIA_DIR="${QL_CAMERA_MEDIA_DIR:-/srv/ql-camera/media}"
DEFAULT_RELEASE_REPOSITORY="pqminh-4/QL_Camera_Releases"
# Ghép sentinel thành hai chuỗi để bước đóng gói không thay nhầm cả điều kiện phát hiện placeholder.
UNBOUND_RELEASE_REPOSITORY="__QL_CAMERA_RELEASE_""REPOSITORY__"
RELEASE_REPOSITORY="${QL_CAMERA_RELEASE_REPOSITORY:-${QL_CAMERA_REPOSITORY:-$DEFAULT_RELEASE_REPOSITORY}}"
SOURCE_DIR="${QL_CAMERA_SOURCE_DIR:-}"
# Chỉ tự nhận diện source khi Bash đang thực thi một tệp thật; installer pipe qua stdin không dùng thư mục hiện tại.
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
if [[ "$SCRIPT_PATH" == */* ]]; then
  if SCRIPT_DIR="$(cd -- "${SCRIPT_PATH%/*}" 2>/dev/null && pwd -P)"; then
    :
  else
    SCRIPT_DIR=""
  fi
elif [[ -f "$SCRIPT_PATH" ]]; then
  SCRIPT_DIR="$(pwd -P)"
else
  SCRIPT_DIR=""
fi
AGENT_GROUP_ID="${QL_CAMERA_AGENT_GID:-1999}"
INSTALL_MODE=""
RELEASE_API_IMAGE=""
RELEASE_WEB_IMAGE=""
OWNER_CREATED="false"
OWNER_ALREADY_EXISTS="false"
INSTALL_OWNER_NAME=""
INSTALL_OWNER_EMAIL=""
INSTALL_OWNER_PASSWORD=""
EXISTING_INSTALL="false"
APT_INDEX_UPDATED="false"
DOCKER_PULL_MAX_ATTEMPTS=4
DOCKER_PULL_RETRY_DELAY_SECONDS=5
COMPOSE_LOCK_FILE="/run/ql-camera-compose.lock"
COMPOSE_LOCK_WAIT_SECONDS=300

REQUIRED_HOST_PACKAGES=(
  ca-certificates
  curl
  gnupg
  jq
  tar
  gzip
  coreutils
  grep
  sed
  mawk
  passwd
  hostname
  libc-bin
  util-linux
)
OPTIONAL_HOST_PACKAGES=(usbutils)
REQUIRED_HOST_COMMANDS=(
  curl
  jq
  tar
  gzip
  sha256sum
  awk
  grep
  sed
  groupadd
  systemctl
  gpg
  hostname
  getent
  date
  df
  uname
  install
  base64
  dd
  tr
  seq
  mktemp
  readlink
  flock
  cp
  chown
  chmod
)
MISSING_REQUIRED_PACKAGES=()
MISSING_OPTIONAL_PACKAGES=()

[[ -f "$INSTALL_DIR/docker-compose.yml" ]] && EXISTING_INSTALL="true"

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

dependency_status() {
  printf '[%s] %s\n' "$1" "$2"
}

dependency_warning() {
  dependency_status "Cảnh báo" "$1" >&2
}

has_interactive_tty() {
  [[ -r /dev/tty && -w /dev/tty ]] && { true </dev/tty; } 2>/dev/null
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Hãy chạy installer bằng sudo."
}

source_checkout_is_valid() {
  local source="$1"
  [[ -n "$source" && -f "$source/docker-compose.yml" && -f "$source/package.json" &&
    -f "$source/pnpm-workspace.yaml" && -f "$source/apps/api/package.json" &&
    -f "$source/apps/web/package.json" && -f "$source/apps/host-agent/go.mod" &&
    -f "$source/scripts/build-release-bundle.sh" ]]
}

resolve_install_mode() {
  local resolved_source
  if [[ -n "$SOURCE_DIR" ]]; then
    source_checkout_is_valid "$SOURCE_DIR" ||
      fail "QL_CAMERA_SOURCE_DIR không trỏ tới source checkout QL Camera hợp lệ."
    resolved_source="$(cd -- "$SOURCE_DIR" 2>/dev/null && pwd -P)" ||
      fail "Không truy cập được QL_CAMERA_SOURCE_DIR."
    SOURCE_DIR="$resolved_source"
    INSTALL_MODE="source"
    return
  fi

  if source_checkout_is_valid "$SCRIPT_DIR"; then
    SOURCE_DIR="$SCRIPT_DIR"
    INSTALL_MODE="source"
    return
  fi

  if [[ "$RELEASE_REPOSITORY" == "$UNBOUND_RELEASE_REPOSITORY" ]]; then
    fail "Installer chưa được gắn repository phát hành và không nằm trong source checkout hợp lệ. Hãy tải installer chính thức tại https://raw.githubusercontent.com/pqminh-4/QL_Camera_Releases/main/install.sh"
  fi
  [[ "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    fail "QL_CAMERA_RELEASE_REPOSITORY phải có dạng owner/repository."
  INSTALL_MODE="release"
}

systemd_is_running() {
  [[ -d /run/systemd/system ]] && systemctl show --property=Version --value >/dev/null 2>&1
}

load_os_release() {
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  source /etc/os-release
}

bootstrap_environment() {
  [[ "$INSTALL_DIR" == /* && "$INSTALL_DIR" != "/" ]] || fail "QL_CAMERA_INSTALL_DIR phải là đường dẫn tuyệt đối khác /."
  [[ "$DATA_DIR" == /* && "$DATA_DIR" != "/" ]] || fail "QL_CAMERA_DATA_DIR phải là đường dẫn tuyệt đối khác /."
  [[ "$MEDIA_DIR" == /* && "$MEDIA_DIR" != "/" ]] || fail "QL_CAMERA_MEDIA_DIR phải là đường dẫn tuyệt đối khác /."
  [[ -n "${BASH_VERSION:-}" ]] || fail "Installer cần được chạy bằng Bash."
  command -v apt-get >/dev/null 2>&1 || fail "Máy thiếu APT; installer chỉ hỗ trợ Ubuntu Server dùng APT/DPKG."
  command -v dpkg >/dev/null 2>&1 || fail "Máy thiếu DPKG; installer chỉ hỗ trợ Ubuntu Server dùng APT/DPKG."
  command -v dpkg-query >/dev/null 2>&1 || fail "Máy thiếu dpkg-query; hãy sửa bộ quản lý gói trước khi cài QL Camera."
  command -v systemctl >/dev/null 2>&1 || fail "Máy thiếu systemctl; QL Camera cần Ubuntu Server chạy bằng systemd."
  load_os_release || fail "Không nhận diện được hệ điều hành."
  [[ "${ID:-}" == "ubuntu" ]] || fail "Bản đầu chỉ hỗ trợ Ubuntu Server."
  case "${VERSION_ID:-}" in
    24.04|26.04) ;;
    *) fail "Chỉ hỗ trợ Ubuntu 24.04 hoặc 26.04 LTS." ;;
  esac
  [[ "$(dpkg --print-architecture)" == "amd64" ]] || fail "Bản đầu chỉ hỗ trợ amd64/x86_64."
  systemd_is_running || fail "Không phát hiện systemd đang chạy. Không hỗ trợ container, WSL không bật systemd hoặc hệ init khác."
  dependency_status "Sẵn sàng" "Ubuntu ${VERSION_ID} amd64, APT/DPKG và systemd"
}

package_is_installed() {
  local status
  status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" || return 1
  [[ "$status" == ii* ]]
}

required_command_available() {
  command -v "$1" >/dev/null 2>&1
}

run_apt_get() {
  DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

ensure_apt_index() {
  if [[ "$APT_INDEX_UPDATED" == "true" ]]; then
    return
  fi
  run_apt_get update || return 1
  APT_INDEX_UPDATED="true"
}

inventory_host_dependencies() {
  local package
  MISSING_REQUIRED_PACKAGES=()
  MISSING_OPTIONAL_PACKAGES=()
  note "Kiểm tra phần bổ trợ của Ubuntu"
  for package in "${REQUIRED_HOST_PACKAGES[@]}"; do
    if package_is_installed "$package"; then
      dependency_status "Sẵn sàng" "Gói bắt buộc: $package"
    else
      dependency_status "Thiếu" "Gói bắt buộc: $package"
      MISSING_REQUIRED_PACKAGES+=("$package")
    fi
  done
  for package in "${OPTIONAL_HOST_PACKAGES[@]}"; do
    if package_is_installed "$package"; then
      dependency_status "Sẵn sàng" "Tiện ích phần cứng: $package"
    else
      dependency_status "Thiếu" "Tiện ích phần cứng: $package"
      MISSING_OPTIONAL_PACKAGES+=("$package")
    fi
  done
}

postcheck_host_dependencies() {
  local package tool
  local failures=()
  for package in "${REQUIRED_HOST_PACKAGES[@]}"; do
    package_is_installed "$package" || failures+=("gói $package")
  done
  for tool in "${REQUIRED_HOST_COMMANDS[@]}"; do
    required_command_available "$tool" || failures+=("lệnh $tool")
  done
  if (( ${#failures[@]} > 0 )); then
    fail "Hậu kiểm phần bổ trợ thất bại: ${failures[*]}. Hãy sửa APT/DPKG rồi chạy lại installer."
  fi
  dependency_status "Sẵn sàng" "Hậu kiểm toàn bộ lệnh bắt buộc đã đạt"
  if package_is_installed usbutils && required_command_available lsusb; then
    dependency_status "Sẵn sàng" "Có thể nhận diện thiết bị Coral USB bằng lsusb"
  else
    dependency_warning "Thiếu usbutils/lsusb; QL Camera vẫn chạy nhưng có thể không tự nhận diện Coral USB."
  fi
}

install_host_dependencies() {
  local package
  inventory_host_dependencies
  if (( ${#MISSING_REQUIRED_PACKAGES[@]} > 0 )); then
    note "Cài các phần bổ trợ bắt buộc còn thiếu"
    ensure_apt_index || fail "Không cập nhật được danh mục APT. Kiểm tra Internet và cấu hình repository rồi chạy lại."
    run_apt_get install -y --no-install-recommends "${MISSING_REQUIRED_PACKAGES[@]}" ||
      fail "Không cài được phần bổ trợ bắt buộc. QL Camera chưa được tải hoặc cấu hình."
    for package in "${MISSING_REQUIRED_PACKAGES[@]}"; do
      if package_is_installed "$package"; then
        dependency_status "Đã cài" "Gói bắt buộc: $package"
      fi
    done
  fi
  if (( ${#MISSING_OPTIONAL_PACKAGES[@]} > 0 )); then
    note "Cài tiện ích nhận diện phần cứng"
    if ! ensure_apt_index; then
      dependency_warning "Không cập nhật được APT để cài usbutils; tiếp tục mà không tự nhận diện Coral USB."
    elif run_apt_get install -y --no-install-recommends "${MISSING_OPTIONAL_PACKAGES[@]}"; then
      for package in "${MISSING_OPTIONAL_PACKAGES[@]}"; do
        package_is_installed "$package" && dependency_status "Đã cài" "Tiện ích phần cứng: $package"
      done
    else
      dependency_warning "Không cài được usbutils; tiếp tục mà không tự nhận diện Coral USB."
    fi
  fi
  postcheck_host_dependencies
}

preflight() {
  [[ "$(uname -m)" == "x86_64" ]] || fail "Bản đầu chỉ hỗ trợ amd64/x86_64."
  local available_kb required_kb
  available_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
  required_kb=$((15 * 1024 * 1024))
  if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    # Lần sửa hoặc nâng cấp có thể tái sử dụng image hiện hữu nên cần ít dung lượng tạm hơn.
    required_kb=$((5 * 1024 * 1024))
  fi
  (( available_kb >= required_kb )) || fail "Không đủ dung lượng trống: cần tối thiểu $((required_kb / 1024 / 1024)) GB."
  if [[ "$EXISTING_INSTALL" != "true" ]] && ! has_interactive_tty &&
    [[ -z "${QL_CAMERA_OWNER_NAME:-}" || -z "${QL_CAMERA_OWNER_EMAIL:-}" ]]; then
    fail "Cài đặt không có terminal cần đặt đủ QL_CAMERA_OWNER_NAME và QL_CAMERA_OWNER_EMAIL."
  fi
  if [[ -n "${QL_CAMERA_OWNER_NAME:-}" && -z "${QL_CAMERA_OWNER_EMAIL:-}" ]] ||
    [[ -z "${QL_CAMERA_OWNER_NAME:-}" && -n "${QL_CAMERA_OWNER_EMAIL:-}" ]]; then
    fail "Phải đặt đồng thời QL_CAMERA_OWNER_NAME và QL_CAMERA_OWNER_EMAIL."
  fi
}

docker_command_available() {
  required_command_available docker
}

docker_footprints_exist() {
  local package
  docker_command_available && return 0
  for package in docker-ce docker-ce-cli docker.io docker-compose docker-compose-v2 docker-compose-plugin containerd containerd.io podman-docker; do
    package_is_installed "$package" && return 0
  done
  [[ -e /var/lib/docker || -e /etc/docker || -e /etc/systemd/system/docker.service ||
    -e /lib/systemd/system/docker.service || -e /usr/lib/systemd/system/docker.service ]]
}

ensure_docker_service() {
  systemctl is-enabled --quiet docker.service || systemctl enable docker.service
  systemctl is-active --quiet docker.service || systemctl start docker.service
}

docker_runtime_healthy() {
  docker info --format '{{.ServerVersion}}' >/dev/null 2>&1
}

docker_compose_healthy() {
  docker compose version >/dev/null 2>&1
}

docker_compose_can_parse() {
  docker compose -f - config --quiet >/dev/null 2>&1 <<'YAML'
services:
  ql_camera_dependency_check:
    image: busybox:1.36
YAML
}

validate_docker_runtime() {
  docker_command_available || fail "Không tìm thấy lệnh docker sau khi cài. Hãy sửa Docker rồi chạy lại installer."
  if ! docker_runtime_healthy; then
    ensure_docker_service || fail "Docker daemon đang dừng và không bật được docker.service. Installer không tự thay thế Docker hiện hữu."
    docker_runtime_healthy || fail "Docker daemon vẫn không hoạt động. Chạy 'systemctl status docker' và 'docker info' để chẩn đoán."
  fi
  docker_compose_healthy || fail "Thiếu hoặc lỗi Docker Compose plugin. Installer không tự thay đổi bộ Docker hiện hữu."
  docker_compose_can_parse || fail "Docker Compose không đọc được cấu hình chuẩn. Hãy sửa hoặc nâng cấp Docker/Compose rồi chạy lại."
}

install_docker_engine() {
  local docker_key docker_source
  note "Cài Docker Engine và Compose từ repository chính thức"
  docker_key="$(mktemp)"
  docker_source="$(mktemp)"
  cleanup_items+=("$docker_key" "$docker_source")
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$docker_key" || fail "Không tải được khóa repository Docker chính thức."
  # shellcheck disable=SC1091
  source /etc/os-release
  cat >"$docker_source" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  install -m 0755 -d /etc/apt/keyrings
  install -m 0644 "$docker_key" /etc/apt/keyrings/docker.asc
  install -m 0644 "$docker_source" /etc/apt/sources.list.d/docker.sources
  APT_INDEX_UPDATED="false"
  ensure_apt_index || fail "Không cập nhật được repository Docker chính thức."
  run_apt_get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ||
    fail "Không cài được Docker Engine. Installer không gỡ hoặc thay thế gói xung đột tự động."
  ensure_docker_service || fail "Đã cài Docker nhưng không bật được docker.service cho lần khởi động hiện tại và các lần reboot sau."
}

ensure_docker() {
  note "Kiểm tra Docker Engine và Docker Compose"
  if docker_footprints_exist; then
    if ! docker_command_available; then
      fail "Phát hiện Docker/containerd hiện hữu nhưng không có lệnh docker. Installer không tự gỡ hoặc thay thế; hãy sửa bộ Docker hiện tại rồi chạy lại."
    fi
    validate_docker_runtime
    dependency_status "Sẵn sàng" "Giữ nguyên Docker Engine và Docker Compose hiện hữu"
    return
  fi
  dependency_status "Thiếu" "Docker Engine và Docker Compose"
  install_docker_engine
  validate_docker_runtime
  dependency_status "Đã cài" "Docker Engine, containerd, Buildx và Docker Compose plugin"
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

release_asset_download_url() {
  local version="$1" asset_name="$2"
  printf 'https://github.com/%s/releases/download/%s/%s\n' "$RELEASE_REPOSITORY" "$version" "$asset_name"
}

latest_release_version_from_page() {
  local release_page_url version
  release_page_url="$(curl -fsSL --connect-timeout 20 --retry 5 --retry-delay 2 --retry-all-errors -o /dev/null -w '%{url_effective}' "https://github.com/${RELEASE_REPOSITORY}/releases/latest")" || return 1
  version="${release_page_url##*/}"
  [[ "$release_page_url" == "https://github.com/${RELEASE_REPOSITORY}/releases/tag/${version}" ]] || return 1
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || return 1
  printf '%s\n' "$version"
}

download_release_asset() {
  local url="$1" output_path="$2"
  curl -fsSL --connect-timeout 20 --retry 5 --retry-delay 2 --retry-all-errors "$url" -o "$output_path"
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
  if [[ "$INSTALL_MODE" == "source" ]]; then
    source_checkout_is_valid "$SOURCE_DIR" || fail "Source checkout đã thay đổi hoặc không còn hợp lệ."
    copy_source_checkout "$SOURCE_DIR" "$INSTALL_DIR"
    return
  fi
  [[ "$INSTALL_MODE" == "release" ]] || fail "Chế độ cài đặt chưa được xác định."
  local temp_dir release_json version bundle_name bundle_checksum_name agent_name agent_checksum_name manifest_name
  local bundle_url bundle_checksum_url agent_url agent_checksum_url manifest_url staging_dir
  temp_dir="$(mktemp -d)"
  cleanup_items+=("$temp_dir")
  release_json=""
  if release_json="$(curl -fsSL "https://api.github.com/repos/${RELEASE_REPOSITORY}/releases/latest")" &&
    version="$(jq -er '.tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+([-.][0-9A-Za-z.-]+)?$"))' <<<"$release_json")"; then
    :
  else
    release_json=""
    note "GitHub API không khả dụng; chuyển sang trang release public"
    version="$(latest_release_version_from_page)" || fail "Không xác định được release public mới nhất."
  fi
  bundle_name="ql-camera-deploy-bundle-${version}.tar.gz"
  bundle_checksum_name="${bundle_name}.sha256"
  agent_name="ql-camera-agent-linux-amd64"
  agent_checksum_name="${agent_name}.sha256"
  manifest_name="release-manifest.json"
  if [[ -n "$release_json" ]]; then
    bundle_url="$(release_asset_url "$release_json" "$bundle_name")" || fail "Release thiếu deploy bundle."
    bundle_checksum_url="$(release_asset_url "$release_json" "$bundle_checksum_name")" || fail "Release thiếu checksum deploy bundle."
    agent_url="$(release_asset_url "$release_json" "$agent_name")" || fail "Release thiếu host-agent."
    agent_checksum_url="$(release_asset_url "$release_json" "$agent_checksum_name")" || fail "Release thiếu checksum host-agent."
    manifest_url="$(release_asset_url "$release_json" "$manifest_name")" || fail "Release thiếu manifest."
  else
    bundle_url="$(release_asset_download_url "$version" "$bundle_name")"
    bundle_checksum_url="$(release_asset_download_url "$version" "$bundle_checksum_name")"
    agent_url="$(release_asset_download_url "$version" "$agent_name")"
    agent_checksum_url="$(release_asset_download_url "$version" "$agent_checksum_name")"
    manifest_url="$(release_asset_download_url "$version" "$manifest_name")"
  fi
  note "Tải QL Camera ${version}"
  download_release_asset "$bundle_url" "$temp_dir/$bundle_name" || fail "Không tải được deploy bundle."
  download_release_asset "$bundle_checksum_url" "$temp_dir/$bundle_checksum_name" || fail "Không tải được checksum deploy bundle."
  download_release_asset "$agent_url" "$temp_dir/$agent_name" || fail "Không tải được host-agent."
  download_release_asset "$agent_checksum_url" "$temp_dir/$agent_checksum_name" || fail "Không tải được checksum host-agent."
  download_release_asset "$manifest_url" "$temp_dir/$manifest_name" || fail "Không tải được manifest."
  verify_checksum "$temp_dir/$bundle_checksum_name" "$temp_dir/$bundle_name"
  verify_checksum "$temp_dir/$agent_checksum_name" "$temp_dir/$agent_name"
  [[ "$(jq -er '.version' "$temp_dir/$manifest_name")" == "$version" ]] || fail "Phiên bản manifest không khớp release."
  [[ "$(jq -er '.commit | select(test("^[a-f0-9]{40}$"))' "$temp_dir/$manifest_name")" ]] || fail "Commit trong manifest không hợp lệ."
  RELEASE_API_IMAGE="$(jq -er '.images.api' "$temp_dir/$manifest_name")" || fail "Manifest thiếu image API."
  RELEASE_WEB_IMAGE="$(jq -er '.images.web' "$temp_dir/$manifest_name")" || fail "Manifest thiếu image web."
  RELEASE_VERSION="$(jq -er '.version' "$temp_dir/$manifest_name")" || fail "Manifest thiếu version."
  RELEASE_COMMIT="$(jq -er '.commit' "$temp_dir/$manifest_name")" || fail "Manifest thiếu commit."
  validate_image_digest "$RELEASE_API_IMAGE" || fail "Image API không được ghim bằng GHCR digest hợp lệ."
  validate_image_digest "$RELEASE_WEB_IMAGE" || fail "Image web không được ghim bằng GHCR digest hợp lệ."
  validate_release_archive "$temp_dir/$bundle_name"
  staging_dir="$temp_dir/bundle"
  mkdir -p "$staging_dir"
  tar --no-same-owner --no-same-permissions -xzf "$temp_dir/$bundle_name" -C "$staging_dir"
  [[ -f "$staging_dir/docker-compose.yml" &&
    -f "$staging_dir/apps/host-agent/ql-camera-agent.service" &&
    -f "$staging_dir/apps/host-agent/ql-camera-stack.service" ]] || fail "Deploy bundle thiếu cấu hình runtime bắt buộc."
  # Xóa source legacy trong thư mục ứng dụng nhưng giữ nguyên secret, dữ liệu và cấu hình runtime.
  rm -rf -- "$INSTALL_DIR/apps" "$INSTALL_DIR/packages" "$INSTALL_DIR/deploy"
  copy_source_checkout "$staging_dir" "$INSTALL_DIR"
  install -D -m 0755 "$temp_dir/$agent_name" "$INSTALL_DIR/apps/host-agent/ql-camera-agent"
  INSTALL_MODE="release"
}

random_secret() {
  dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d '\n'
}

trim_value() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$1"
}

valid_owner_name() {
  local value
  value="$(trim_value "$1")"
  (( ${#value} >= 2 && ${#value} <= 80 ))
}

valid_owner_email() {
  local value="$1"
  (( ${#value} <= 254 )) && [[ "$value" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

collect_owner_identity() {
  if [[ -n "${QL_CAMERA_OWNER_NAME:-}" && -n "${QL_CAMERA_OWNER_EMAIL:-}" ]]; then
    INSTALL_OWNER_NAME="$(trim_value "$QL_CAMERA_OWNER_NAME")"
    INSTALL_OWNER_EMAIL="$(trim_value "$QL_CAMERA_OWNER_EMAIL")"
    valid_owner_name "$INSTALL_OWNER_NAME" || fail "QL_CAMERA_OWNER_NAME phải có từ 2 đến 80 ký tự."
    valid_owner_email "$INSTALL_OWNER_EMAIL" || fail "QL_CAMERA_OWNER_EMAIL không hợp lệ."
    return
  fi

  has_interactive_tty || fail "Không có terminal để nhập Owner. Hãy đặt QL_CAMERA_OWNER_NAME và QL_CAMERA_OWNER_EMAIL."
  note "Thiết lập tài khoản Owner đầu tiên"
  while true; do
    read -r -p "Tên hiển thị Owner: " INSTALL_OWNER_NAME </dev/tty
    INSTALL_OWNER_NAME="$(trim_value "$INSTALL_OWNER_NAME")"
    valid_owner_name "$INSTALL_OWNER_NAME" && break
    printf 'Tên hiển thị phải có từ 2 đến 80 ký tự.\n' >/dev/tty
  done
  while true; do
    read -r -p "Email Owner: " INSTALL_OWNER_EMAIL </dev/tty
    INSTALL_OWNER_EMAIL="$(trim_value "$INSTALL_OWNER_EMAIL")"
    valid_owner_email "$INSTALL_OWNER_EMAIL" && break
    printf 'Email không hợp lệ. Hãy nhập lại.\n' >/dev/tty
  done
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
    # Công cụ mosquitto_passwd yêu cầu file do root sở hữu khi cập nhật.
    chown root:root "$INSTALL_DIR/secrets/mosquitto_passwords"
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
    QL_CAMERA_DOMAIN QL_CAMERA_AGENT_GID QL_CAMERA_API_IMAGE QL_CAMERA_WEB_IMAGE QL_CAMERA_VERSION QL_CAMERA_COMMIT WEB_PORT PUBLIC_ORIGIN TZ
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
    set_env_value "$env_path" QL_CAMERA_VERSION "${RELEASE_VERSION:-unknown}"
    set_env_value "$env_path" QL_CAMERA_COMMIT "${RELEASE_COMMIT:-unknown}"
  else
    ensure_env_value "$env_path" QL_CAMERA_API_IMAGE "$api_image"
    ensure_env_value "$env_path" QL_CAMERA_WEB_IMAGE "$web_image"
    ensure_env_value "$env_path" QL_CAMERA_VERSION "${QL_CAMERA_VERSION:-development}"
    ensure_env_value "$env_path" QL_CAMERA_COMMIT "${QL_CAMERA_COMMIT:-development}"
  fi
  ensure_env_value "$env_path" WEB_PORT 8080
  ensure_env_value "$env_path" PUBLIC_ORIGIN http://localhost:8080
  ensure_env_value "$env_path" TZ Asia/Ho_Chi_Minh
  chmod 0700 "$INSTALL_DIR/secrets" "$DATA_DIR/frigate"
  chmod 0750 "$DATA_DIR/runtime-secrets"
  chmod 0600 "$INSTALL_DIR/secrets/"* "$INSTALL_DIR/.env" "$DATA_DIR/frigate/config.yml" "$INSTALL_DIR/infra/coturn/turnserver.generated.conf"
  # API chạy non-root với GID 65532; chỉ group này được đọc các secret API cần dùng.
  chown root:65532 \
    "$INSTALL_DIR/secrets/master_key" \
    "$INSTALL_DIR/secrets/postgres_password" \
    "$INSTALL_DIR/secrets/bootstrap_token.json" \
    "$INSTALL_DIR/secrets/turn_shared_secret" \
    "$INSTALL_DIR/secrets/mqtt_password"
  chmod 0640 \
    "$INSTALL_DIR/secrets/master_key" \
    "$INSTALL_DIR/secrets/postgres_password" \
    "$INSTALL_DIR/secrets/bootstrap_token.json" \
    "$INSTALL_DIR/secrets/turn_shared_secret" \
    "$INSTALL_DIR/secrets/mqtt_password"
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
  install -m 0644 "$INSTALL_DIR/apps/host-agent/ql-camera-stack.service" /etc/systemd/system/ql-camera-stack.service
  printf 'QL_CAMERA_PROJECT_DIR=%q\nQL_CAMERA_MEDIA_DIR=%q\n' "$INSTALL_DIR" "$MEDIA_DIR" >/etc/default/ql-camera-agent
  chmod 0644 /etc/default/ql-camera-agent
  systemctl daemon-reload
  systemctl enable ql-camera-agent.service
  systemctl enable ql-camera-stack.service
  # Restart để bản nâng cấp áp dụng ngay đường dẫn socket và thứ tự khởi động mới.
  systemctl restart ql-camera-agent.service
}

refresh_bootstrap_credential() {
  local expires_at
  INSTALL_BOOTSTRAP_TOKEN="$(random_secret)"
  expires_at="$(date -u -d '+30 minutes' '+%Y-%m-%dT%H:%M:%SZ')"
  printf '{"token":"%s","expiresAt":"%s"}\n' "$INSTALL_BOOTSTRAP_TOKEN" "$expires_at" >"$INSTALL_DIR/secrets/bootstrap_token.json"
  chown root:65532 "$INSTALL_DIR/secrets/bootstrap_token.json"
  chmod 0640 "$INSTALL_DIR/secrets/bootstrap_token.json"
}

pull_compose_images() {
  local attempt=1 delay="$DOCKER_PULL_RETRY_DELAY_SECONDS"
  while (( attempt <= DOCKER_PULL_MAX_ATTEMPTS )); do
    if docker compose pull "$@"; then
      return 0
    fi
    if (( attempt == DOCKER_PULL_MAX_ATTEMPTS )); then
      return 1
    fi
    # Docker giữ lại các layer đã tải; lần thử sau chỉ tiếp tục phần còn thiếu hoặc lỗi tạm thời.
    printf 'Cảnh báo: tải image thất bại ở lượt %d/%d; thử lại sau %d giây.\n' \
      "$attempt" "$DOCKER_PULL_MAX_ATTEMPTS" "$delay" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
  return 1
}

start_stack_locked() {
  cd "$INSTALL_DIR"
  if [[ "$INSTALL_MODE" == "release" ]]; then
    note "Tải image đã phát hành và khởi động các service"
    pull_compose_images postgres mosquitto frigate api web caddy ||
      fail "Không tải đủ image sau ${DOCKER_PULL_MAX_ATTEMPTS} lượt. Hãy kiểm tra kết nối tới registry/CDN rồi chạy lại installer."
    docker compose up -d --no-build
  else
    note "Build source local và khởi động các service"
    pull_compose_images postgres mosquitto frigate caddy ||
      fail "Không tải đủ image sau ${DOCKER_PULL_MAX_ATTEMPTS} lượt. Hãy kiểm tra kết nối tới registry/CDN rồi chạy lại installer."
    docker compose up -d --build
  fi
  # API phải đọc credential bootstrap vừa làm mới kể cả khi container cũ vẫn đang chạy.
  docker compose up -d --no-deps --force-recreate api
  for _ in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:8080/api/v1/health >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done
  docker compose ps
  fail "API không khỏe sau 120 giây. Hãy kiểm tra docker compose logs api."
}

start_stack() {
  local lock_fd
  exec {lock_fd}>"$COMPOSE_LOCK_FILE"
  # Dùng chung khóa với unit boot để installer không chạy Compose chồng lên quá trình reconcile.
  flock --wait "$COMPOSE_LOCK_WAIT_SECONDS" "$lock_fd" ||
    fail "Không lấy được khóa Compose sau ${COMPOSE_LOCK_WAIT_SECONDS} giây. Hãy kiểm tra systemctl status ql-camera-stack."
  start_stack_locked
  flock --unlock "$lock_fd"
  exec {lock_fd}>&-
}

create_initial_owner() {
  local status needs_bootstrap response_file response_code payload
  status="$(curl -fsS http://127.0.0.1:8080/api/v1/auth/status)" || fail "Không đọc được trạng thái thiết lập Owner."
  needs_bootstrap="$(jq -er '.needsBootstrap | if . == true then "true" elif . == false then "false" else error("invalid") end' <<<"$status")" ||
    fail "API trả trạng thái thiết lập Owner không hợp lệ."
  if [[ "$needs_bootstrap" == "false" ]]; then
    OWNER_ALREADY_EXISTS="true"
    return
  fi

  collect_owner_identity
  INSTALL_OWNER_PASSWORD="$(random_secret)"
  payload="$(jq -cn \
    --arg email "$INSTALL_OWNER_EMAIL" \
    --arg displayName "$INSTALL_OWNER_NAME" \
    --arg password "$INSTALL_OWNER_PASSWORD" \
    '{email:$email,displayName:$displayName,password:$password,requirePasswordChange:true}')"
  response_file="$(mktemp)"
  cleanup_items+=("$response_file")
  response_code="$(curl -sS -o "$response_file" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -H "X-Bootstrap-Token: $INSTALL_BOOTSTRAP_TOKEN" \
    --data-binary @- \
    http://127.0.0.1:8080/api/v1/auth/bootstrap <<<"$payload")" || fail "Không kết nối được API để tạo Owner."
  if [[ "$response_code" != "201" ]]; then
    INSTALL_OWNER_PASSWORD=""
    fail "Không tạo được Owner: $(jq -r '.message // "API từ chối yêu cầu bootstrap."' "$response_file" 2>/dev/null || printf 'API từ chối yêu cầu bootstrap.')"
  fi
  OWNER_CREATED="true"
}

finish() {
  local lan_ip
  lan_ip="$(hostname -I | awk '{print $1}')"
  printf '\nQL Camera Home đã sẵn sàng.\n'
  printf 'Mở: http://%s:8080/\n' "$lan_ip"
  if [[ "$OWNER_CREATED" == "true" ]]; then
    printf '\nThông tin Owner (chỉ hiển thị lần này):\n'
    printf 'Tên: %s\nEmail: %s\nMật khẩu tạm: %s\n' "$INSTALL_OWNER_NAME" "$INSTALL_OWNER_EMAIL" "$INSTALL_OWNER_PASSWORD"
    printf 'Hãy lưu lại ngay. Hệ thống sẽ bắt buộc đổi mật khẩu ở lần đăng nhập đầu tiên.\n'
  elif [[ "$OWNER_ALREADY_EXISTS" == "true" ]]; then
    printf 'Owner đã tồn tại; tài khoản và mật khẩu hiện tại được giữ nguyên.\n'
  fi
  printf 'Dữ liệu: %s\nBản ghi: %s\n' "$DATA_DIR" "$MEDIA_DIR"
  INSTALL_OWNER_PASSWORD=""
}

main() {
  require_root
  resolve_install_mode
  bootstrap_environment
  install_host_dependencies
  preflight
  ensure_docker
  download_source
  generate_configuration
  install_host_agent
  # Làm mới token sát lúc API khởi động để quá trình build hoặc tải image lâu không làm token hết hạn.
  refresh_bootstrap_credential
  start_stack
  create_initial_owner
  finish
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
