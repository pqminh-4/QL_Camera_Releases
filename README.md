# QL Camera Home Releases

Repository này chỉ phân phối installer và artifact production của QL Camera Home. Mã nguồn ứng dụng được quản lý trong repository private.

## Cài đặt

QL Camera Home hỗ trợ Ubuntu Server 24.04/26.04 LTS amd64. Trên Ubuntu sạch, bootstrap `ca-certificates` và `curl` bằng APT trước khi tải installer:

```bash
sudo apt-get update && \
sudo apt-get install -y --no-install-recommends ca-certificates curl && \
curl -fsSL https://raw.githubusercontent.com/pqminh-4/QL_Camera_Releases/main/install.sh | sudo bash
```

Hai gói này phải có trước vì installer chưa thể tự kiểm tra dependency khi `install.sh` chưa được tải. Nếu máy đã có `curl` và CA certificate hoạt động, có thể bỏ qua hai lệnh APT.

Khi cần xác minh installer trước khi chạy:

```bash
curl -fsSL https://raw.githubusercontent.com/pqminh-4/QL_Camera_Releases/main/install.sh -o /tmp/ql-camera-install.sh
sha256sum /tmp/ql-camera-install.sh
grep '^DEFAULT_RELEASE_REPOSITORY=' /tmp/ql-camera-install.sh
grep -Fxq 'DEFAULT_RELEASE_REPOSITORY="pqminh-4/QL_Camera_Releases"' /tmp/ql-camera-install.sh
sudo bash /tmp/ql-camera-install.sh
```

Binding phải trỏ tới `pqminh-4/QL_Camera_Releases`. Nếu phép kiểm tra binding thất bại, không chạy tệp đó và tải lại từ URL public chính thức.

Máy phải chạy bằng `systemd`, có APT/DPKG và kết nối Internet. Trước khi tải QL Camera, installer tự kiểm tra và cài các gói Ubuntu bắt buộc còn thiếu (`ca-certificates`, `curl`, `gnupg`, `jq`, `tar`, `gzip`, `coreutils`, `grep`, `sed`, `mawk`, `passwd`, `hostname`, `libc-bin`), đồng thời thử cài `usbutils` để nhận diện Coral USB.

Nếu máy chưa có dấu vết Docker, installer cài Docker Engine, containerd, Buildx và Compose plugin từ repository Docker chính thức. Nếu Docker đã tồn tại nhưng daemon/Compose không hoạt động hoặc không tương thích, installer dừng và hướng dẫn khắc phục; không tự gỡ, thay thế hoặc nâng cấp Docker hiện hữu. Installer cũng không tự cài driver GPU/accelerator, sửa firewall hoặc reboot máy.

Sau khi dependency đạt, installer hỏi tên và email, xác minh checksum của deploy bundle/host-agent, khởi động API/web bằng image GHCR public đã ghim SHA-256 digest rồi tự tạo Owner. Mật khẩu tạm chỉ xuất hiện một lần trong terminal và phải được đổi ở lần đăng nhập đầu. Base chỉ mở LAN `8080`; TCP `80/443` và Coturn chỉ được kích hoạt khi Owner chọn Direct/Proxy và preflight cổng đạt.

Bản runtime hỗ trợ nhiều khung lịch theo timezone, camera group/privacy/PTZ, USB V4L2/Coral/VAAPI qua allowlist, durable webhook retry/dead-letter, passkey, incident package, backup mã hóa và update/rollback theo release manifest. Driver GPU/accelerator không được installer tự cài.

Với môi trường không có terminal tương tác trên Ubuntu sạch:

```bash
sudo apt-get update && \
sudo apt-get install -y --no-install-recommends ca-certificates curl && \
curl -fsSL https://raw.githubusercontent.com/pqminh-4/QL_Camera_Releases/main/install.sh \
  | sudo env QL_CAMERA_OWNER_NAME="Chủ nhà" \
      QL_CAMERA_OWNER_EMAIL="owner@example.com" \
      bash
```

Khi chạy lại installer, tài khoản Owner hiện hữu được giữ nguyên; installer không reset hoặc hiển thị lại mật khẩu.

## Artifact

Mỗi release cung cấp deploy bundle, checksum, host-agent Linux amd64, manifest image digest, SBOM và build provenance. Repository này không chứa TypeScript/Go source, credential, dữ liệu camera hoặc bản ghi.

Phần mềm là proprietary và chỉ dành cho người dùng được chủ sở hữu cho phép theo thỏa thuận riêng. Xem `LICENSE` trước khi sử dụng.
